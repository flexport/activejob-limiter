# frozen_string_literal: true

module ActiveJob
  module Limiter
    module QueueAdapters
      module SidekiqAdapter
        # seconds of buffer added to all debounce Redis key TTLs to absorb clock skew
        DEBOUNCE_TTL_BUFFER = 5

        class << self
          def check_lock_before_enqueue(job, expiration)
            Sidekiq.redis_pool.with do |conn|
              # This redis command sets the value of a key (as constructed below) to be the
              # serialized job arguments for introspection purposes. It sets the expiration
              # on the key (ex argument) and only sets if it does not exist (nx argument).
              # It will return true if the set is successful or false if it is not.
              conn.set(key_for(job), job_arguments_for(job), ex: expiration.to_i, nx: true)
            end
          end

          def clear_lock_before_perform(job)
            Sidekiq.redis_pool.with do |conn|
              conn.del(key_for(job))
            end
          end

          def acquire_lock_for_job_resource(name, expiration, job, resource_id)
            lock_key = key_for_job_resource(name, job, resource_id)
            Sidekiq.redis_pool.with do |conn|
              conn.set(
                lock_key,
                job_arguments_for(job),
                ex: expiration.to_i,
                nx: true
              )
            end
          end

          def release_lock_for_job_resource(name, job, resource_id)
            lock_key = key_for_job_resource(name, job, resource_id)
            Sidekiq.redis_pool.with do |conn|
              conn.del(lock_key)
            end
          end

          # Sets the debounce quiet-until time and atomically claims the scheduled slot if not taken.
          # Returns true iff this caller is responsible for enqueuing the delayed job.
          #
          # TTL dynamics: we set TTL = duration + buffer on every trigger.  Each call to this method
          # slides the quiet_until epoch forward and resets the TTL, so the keys stay alive as long
          # as triggers keep arriving.  The claim script (below) extends the is_job_scheduled key's
          # TTL whenever it defers execution; DEBOUNCE_TTL_BUFFER provides extra headroom against
          # clock skew between the app server and Redis.
          def register_debounce_trigger(job, duration, resource_id)
            quiet_until_key = debounce_quiet_until_key_for(job, resource_id)
            is_job_scheduled_key = debounce_is_job_scheduled_key_for(job, resource_id)
            new_quiet_until = (Time.now.to_f + duration.to_f).to_s
            ttl = duration.to_i + DEBOUNCE_TTL_BUFFER

            result = Sidekiq.redis_pool.with do |conn|
              conn.eval(DEBOUNCE_TRIGGER_SCRIPT, keys: [quiet_until_key, is_job_scheduled_key], argv: [new_quiet_until, ttl])
            end
            result == 'OK'
          end

          DEBOUNCE_TRIGGER_SCRIPT = <<~LUA.freeze
            local quiet_until_key      = KEYS[1]  -- stores the earliest epoch at which execution is allowed
            local is_job_scheduled_key = KEYS[2]  -- 1 iff a delayed job is already waiting in Sidekiq
            local new_quiet_until      = ARGV[1]  -- Time.now + duration (float seconds, as string)
            local ttl                  = ARGV[2]  -- integer seconds until both keys expire

            -- Always push quiet_until forward; EX = set expiration in seconds
            redis.call('SET', quiet_until_key, new_quiet_until, 'EX', ttl)
            -- NX = only set if key does not exist; returns 'OK' on success, means this caller won the scheduling slot
            return redis.call('SET', is_job_scheduled_key, '1', 'NX', 'EX', ttl)
          LUA

          # Atomically checks whether the quiet-until epoch has passed.
          # Returns a DebounceClaim with is_claimed: true if the job should execute now,
          # or is_claimed: false with the remaining wait seconds if a newer trigger extended the window.

          def claim_debounce_execution(job, resource_id)
            quiet_until_key = debounce_quiet_until_key_for(job, resource_id)
            is_job_scheduled_key = debounce_is_job_scheduled_key_for(job, resource_id)
            now = Time.now.to_f

            result = Sidekiq.redis_pool.with do |conn|
              conn.eval(DEBOUNCE_CLAIM_SCRIPT, keys: [quiet_until_key, is_job_scheduled_key], argv: [now.to_s, DEBOUNCE_TTL_BUFFER.to_s])
            end

            return DebounceClaim.new(true, 0.0) if result.nil? || result.empty?

            wait_seconds = [result.to_f - Time.now.to_f, 0.0].max
            DebounceClaim.new(false, wait_seconds)
          end

          DEBOUNCE_CLAIM_SCRIPT = <<~LUA.freeze
            local quiet_until_key      = KEYS[1]
            local is_job_scheduled_key = KEYS[2]
            local now                  = ARGV[1]  -- current epoch (float seconds as string)
            local ttl_buffer           = ARGV[2]  -- extra seconds added to the TTL extension

            local quiet_until = redis.call('GET', quiet_until_key)  -- GET returns nil if key absent
            if (not quiet_until) or (tonumber(quiet_until) <= tonumber(now)) then
              -- Quiet period has elapsed: clear both keys and signal execution
              redis.call('DEL', quiet_until_key)
              redis.call('DEL', is_job_scheduled_key)
              return ''
            else
              -- A newer trigger pushed quiet_until into the future; extend the scheduled-key TTL
              -- so it doesn't expire before we reschedule.  EXPIRE sets TTL in whole seconds.
              redis.call('EXPIRE', is_job_scheduled_key, math.ceil(tonumber(quiet_until) - tonumber(now) + tonumber(ttl_buffer)))
              return quiet_until
            end
          LUA

          private

          def key_for(job)
            "limiter:#{job.class.name}:#{Digest::SHA1.hexdigest(job_arguments_for(job))}"
          end

          def key_for_job_resource(name, job, resource_id)
            "limiter:#{job.class.name}:#{resource_id}:#{name}"
          end

          def job_arguments_for(job)
            ActiveJob::Arguments.serialize(job.arguments).to_s
          end

          def debounce_quiet_until_key_for(job, resource_id)
            "limiter:debounce:#{job.class.name}:#{resource_id}:quiet_until"
          end

          def debounce_is_job_scheduled_key_for(job, resource_id)
            "limiter:debounce:#{job.class.name}:#{resource_id}:is_job_scheduled"
          end
        end

        # Result of claim_debounce_execution.
        # is_claimed: true  -> caller should execute the job now (wait_seconds == 0.0)
        # is_claimed: false -> a newer trigger extended the window; caller should reschedule for wait_seconds later
        DebounceClaim = Struct.new(:is_claimed, :wait_seconds)
      end
    end
  end
end
