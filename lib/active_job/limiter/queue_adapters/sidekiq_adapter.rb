# frozen_string_literal: true

module ActiveJob
  module Limiter
    module QueueAdapters
      module SidekiqAdapter
        DEBOUNCE_TTL_BUFFER = 5

        # Sets target time and atomically claims the scheduled slot (NX).
        # Returns "OK" if this caller wins the slot, nil otherwise.
        DEBOUNCE_TRIGGER_SCRIPT = <<~LUA.freeze
          redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2])
          return redis.call('SET', KEYS[2], '1', 'NX', 'EX', ARGV[2])
        LUA

        # Compares target to now. Clears keys and returns '' if ready to execute,
        # or extends the scheduled key TTL and returns the target epoch if not yet.
        DEBOUNCE_CLAIM_SCRIPT = <<~LUA.freeze
          local target = redis.call('GET', KEYS[1])
          if (not target) or (tonumber(target) <= tonumber(ARGV[1])) then
            redis.call('DEL', KEYS[1])
            redis.call('DEL', KEYS[2])
            return ''
          else
            redis.call('EXPIRE', KEYS[2], math.ceil(tonumber(target) - tonumber(ARGV[1]) + tonumber(ARGV[2])))
            return target
          end
        LUA

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

          # Sets the debounce target time and atomically claims the scheduled slot if not taken.
          # Returns true iff this caller is responsible for enqueuing the delayed job.
          def register_debounce_trigger(job, duration, resource_id)
            target_key = debounce_target_key_for(job, resource_id)
            scheduled_key = debounce_scheduled_key_for(job, resource_id)
            new_target = (Time.now.to_f + duration.to_f).to_s
            ttl = duration.to_i + DEBOUNCE_TTL_BUFFER

            result = Sidekiq.redis_pool.with do |conn|
              conn.eval(DEBOUNCE_TRIGGER_SCRIPT, keys: [target_key, scheduled_key], argv: [new_target, ttl])
            end
            result == 'OK'
          end

          # Atomically checks whether target time has passed. Returns :execute if it has,
          # or the remaining Float seconds to wait if a newer trigger extended the window.
          def claim_debounce_execution(job, resource_id)
            target_key = debounce_target_key_for(job, resource_id)
            scheduled_key = debounce_scheduled_key_for(job, resource_id)
            now = Time.now.to_f

            result = Sidekiq.redis_pool.with do |conn|
              conn.eval(DEBOUNCE_CLAIM_SCRIPT, keys: [target_key, scheduled_key], argv: [now.to_s, DEBOUNCE_TTL_BUFFER.to_s])
            end

            return :execute if result.nil? || result.empty?

            [result.to_f - Time.now.to_f, 0.0].max
          end

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

          def debounce_target_key_for(job, resource_id)
            "limiter:debounce:#{job.class.name}:#{resource_id}:target"
          end

          def debounce_scheduled_key_for(job, resource_id)
            "limiter:debounce:#{job.class.name}:#{resource_id}:scheduled"
          end
        end
      end
    end
  end
end
