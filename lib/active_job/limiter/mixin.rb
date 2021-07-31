# frozen_string_literal: true

require 'active_support/concern'

module ActiveJob
  module Limiter
    # ActiveJob Limiter
    #
    # This extends ActiveJob::Base
    module Mixin
      extend ActiveSupport::Concern

      module ClassMethods
        def limit_queue(expiration:)
          # around_enqueue is preferred over before_enqueue so that we can
          # optionally enqueue the job. With before_enqueue, we would have
          # to raise an exception and handle it elsewhere to be able to stop
          # enqueuing.
          # https://groups.google.com/forum/#!topic/rubyonrails-core/mhD4T90g0G4
          around_enqueue do |job, block|
            if ActiveJob::Limiter.check_lock_before_enqueue(job, expiration)
              block.call
            else
              job.job_id = nil
            end
          end

          before_perform do |job|
            ActiveJob::Limiter.clear_lock_before_perform(job)
          end
        end

        def throttle_job(duration:, extract_resource_id:, metrics_hook: ->(_result, _job) {})
          active_job_limiter_add_throttle_job_around_enqueue(
            duration: duration,
            extract_resource_id: extract_resource_id,
            metrics_hook: metrics_hook
          )
          active_job_limiter_add_throttle_job_around_perform(
            duration: duration,
            extract_resource_id: extract_resource_id,
            metrics_hook: metrics_hook
          )
        end

        private

        # Prefixing private methods with active_job_limiter to avoid conflicts with user code

        def active_job_limiter_add_throttle_job_around_enqueue(duration:, extract_resource_id:, metrics_hook:)
          around_enqueue do |job, block|
            resource_id = extract_resource_id.call(job)

            if job.instance_variable_get(:@bypass_active_job_limiter_enqueue_locks)
              block.call
            elsif ActiveJob::Limiter.acquire_lock_for_job_resource('enqueue', duration, job, resource_id)
              block.call
              metrics_hook.call('enqueue.enqueued', job)
            else
              job.job_id = nil
              metrics_hook.call('enqueue.dropped', job)
            end
          end
        end

        def active_job_limiter_add_throttle_job_around_perform(duration:, extract_resource_id:, metrics_hook:)
          around_perform do |job, block|
            resource_id = extract_resource_id.call(job)

            if ActiveJob::Limiter.acquire_lock_for_job_resource('perform', duration, job, resource_id)
              # Before we start executing, allow new jobs to be enqueued
              ActiveJob::Limiter.release_lock_for_job_resource('enqueue', job, resource_id)
              block.call
              metrics_hook.call('perform.performed', job)
            elsif ActiveJob::Limiter.acquire_lock_for_job_resource('reschedule', duration, job, resource_id)
              self.class.send(:active_job_limiter_reschedule_job_for_later, job, duration)
              metrics_hook.call('perform.rescheduled', job)
            else
              job.job_id = nil
              metrics_hook.call('perform.dropped', job)
            end
          end
        end

        def active_job_limiter_reschedule_job_for_later(existing_job, lock_duration)
          new_job = existing_job.class.new(*existing_job.arguments)

          # Rescheduled jobs need to pass through around_enqueue without being dropped, so we
          # need to sneakily signal that this job should be let through regardless of the
          # current lock
          new_job.instance_variable_set(:@bypass_active_job_limiter_enqueue_locks, true)

          # Using a 1.25x multiplier to account for clock skew between server and redis. 1.25 was
          # chosen so that the absolute skew would be at least a few seconds even with relatively
          # small values of lock_duration (e.g. this gives a 2.5 second allowance with a 10 second
          # lock_duration), while still trying to minimize latency in case the retry actually will
          # catch information missed by the first execution of the job.
          new_job.enqueue(wait: lock_duration * 1.25)
        end
      end
    end
  end
end
