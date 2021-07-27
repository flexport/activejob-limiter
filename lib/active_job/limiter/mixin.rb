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

        def throttle_job(expiration:, resource_key:)
          resource_id = job.arguments[resource_key]
          around_enqueue do |job, block|
            if ActiveJob::Limiter.acquire_throttle_lock(job, expiration, resource_id)
              # If we acquire the main throttle lock, we can immediate proceed
              block.call
            elsif ActiveJob::Limiter.acquire_throttle_retry_lock(job, expiration, resource_id)
              # We can't acquire the main lock, but we could acquire the retry lock. That means this
              # job-resource has been scheduled at least twice. To ensure we don't drop high-
              # frequency updates, schedule this job to run a bit later, so that it can capture any
              # high-frequency changes that are occuring.
              ActiveJob::Limiter.reschedule_job_for_future(job, expiration)
            else
              # If neither lock can be acquired (main or retry) that means this job has ran once
              # during the throttle period, and also attempted to run again and was rescheduled for
              # the future. In that case, we can drop the job.
              job.job_id = nil
            end
          end
        end
      end
    end
  end
end
