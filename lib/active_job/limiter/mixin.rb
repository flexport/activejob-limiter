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

        # The general philosophy behind the implementation of throttle_job is that it is safe to
        # drop duplicate jobs if and only if we know that an equivalent job will execute in the near
        # future. There are two cases where this is true. 1) from the time a job is enqueued up
        # until immediately before it is performed, we can safely drop subsequent enqueues knowing
        # that an equivalent job is in the queue about to execute. 2) on the second perform of a job
        # we delay performing until 1.25*duration time later. By doing this, we can continue to drop
        # jobs until the end of the currently held perform lock, which we know will expire sooner
        # than 1.25*duration. This allows us to throttle jobs without inducing artificial latency
        # on the initial invocation, with the tradeoff being that, in order to ensure we don't
        # unsafely drop jobs, we might still execute them once more than necessary.
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
            # For enqueue-related locks, additionally namespace by queue_name. We only need to do
            # this for enqueue, and not perform.
            enqueue_resource_id = "#{resource_id}:#{job.queue_name}"

            if job.instance_variable_get(:@bypass_active_job_limiter_enqueue_locks)
              block.call
            elsif ActiveJob::Limiter.acquire_lock_for_job_resource('enqueue', duration, job, enqueue_resource_id)
              block.call
              metrics_hook.call('enqueue.enqueued', job)
            else
              # If we get here, that means that an equivalent job has been enqueued, but has not yet
              # been performed (because it always releases the enqueue lock before performing). That
              # means that it is safe to drop jobs here because we know an equivalent job will start
              # executing at some point in the near future.
              job.job_id = nil
              metrics_hook.call('enqueue.dropped', job)
            end
          end
        end

        def active_job_limiter_add_throttle_job_around_perform(duration:, extract_resource_id:, metrics_hook:)
          around_perform do |job, block|
            resource_id = extract_resource_id.call(job)

            # Before we start executing, allow new jobs to be enqueued
            # see around_enqueue above -- for enqueue related locks we must namespace by queue_name
            enqueue_resource_id = "#{resource_id}:#{job.queue_name}"
            ActiveJob::Limiter.release_lock_for_job_resource('enqueue', job, enqueue_resource_id)

            if ActiveJob::Limiter.acquire_lock_for_job_resource('perform', duration, job, resource_id)
              block.call
              metrics_hook.call('perform.performed', job)
            elsif ActiveJob::Limiter.acquire_lock_for_job_resource('reschedule', duration, job, resource_id)
              # If we get here, then that means an equivalent job either is still performing or
              # recently performed. In order to respect the throttle without losing data, we create
              # our own destiny by rescheduling a job in the near future. By doing do, it becomes
              # safe to start dropping jobs until the current perform lock expires. The retry is
              # scheduled for a point in time after the perform lock expires, so it will not be
              # dropped (unless it is contending with even more future duplicates... which is fine.
              # Either way, one will win and execute).
              self.class.send(:active_job_limiter_reschedule_job_for_later, job, duration)
              metrics_hook.call('perform.rescheduled', job)
            else
              # See above -- if we get here, we know a job has been scheduled in the future, so it
              # is safe to drop jobs until the current perform lock has expired.
              job.job_id = nil
              metrics_hook.call('perform.dropped', job)
            end
          end
        end

        def active_job_limiter_reschedule_job_for_later(existing_job, lock_duration)
          new_job = existing_job.class.new(*existing_job.arguments)

          # Rescheduled jobs need to pass through around_enqueue without being dropped, so we need
          # to sneakily signal that this job should be let through regardless of the current lock.
          # One might think that it if a job is already in the queue, then it should be fine to drop
          # the reschedule, but that is not the case. At this point, both the perform lock and the
          # retry lock have been acquired, so if there is a job already enqueued, it will probably
          # be dropped as soon as it is performed. For that reason, in order to stick to the policy
          # of only dropping jobs if we have guaranteed that an equivalent job will execute in the
          # near future, special care must be taken to ensure that our reschedule here passes safely
          # through the around_enqueue hook.
          new_job.instance_variable_set(:@bypass_active_job_limiter_enqueue_locks, true)

          # Using a 1.25x multiplier to account for clock skew between server and redis. 1.25 was
          # chosen so that the absolute skew would be at least a few seconds even with relatively
          # small values of lock_duration (e.g. this gives a 2.5 second allowance with a 10 second
          # lock_duration), while still trying to minimize latency in case the retry actually will
          # catch information missed by the first execution of the job.
          new_job.enqueue(wait: lock_duration * 1.25, queue: existing_job.queue_name)
        end
      end
    end
  end
end
