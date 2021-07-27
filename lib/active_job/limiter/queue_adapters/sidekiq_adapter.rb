# frozen_string_literal: true

module ActiveJob
  module Limiter
    module QueueAdapters
      module SidekiqAdapter
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

          def acquire_throttle_lock(job, expiration, resource_id)
            Sidekiq.redis_pool.with do |conn|
              conn.set(
                throttle_key_for(job, resource_id),
                job_arguments_for(job),
                ex: expiration.to_i,
                nx: true
              )
            end
          end

          def acquire_throttle_retry_lock(job, expiration, resource_id)
            Sidekiq.redis_pool.with do |conn|
              conn.set(
                throttle_key_for(job, resource_id, is_retry: true),
                job_arguments_for(job),
                ex: expiration.to_i,
                nx: true
              )
            end
          end

          def reschedule_job_for_future(job, expiration)
            # todo: figure this out
          end

          private

          def key_for(job)
            "limiter:#{job.class.name}:#{Digest::SHA1.hexdigest(job_arguments_for(job))}"
          end

          def throttle_key_for(job, resource_id, is_retry: false)
            if is_retry
              "limiter:throttle:retry:#{job.class.name}:#{resource_id}"
            else
              "limiter:throttle:#{job.class.name}:#{resource_id}"
            end
          end

          def job_arguments_for(job)
            ActiveJob::Arguments.serialize(job.arguments).to_s
          end
        end
      end
    end
  end
end
