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
        end
      end
    end
  end
end
