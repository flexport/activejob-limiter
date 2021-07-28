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
          around_perform do |job, block|
            resource_id = extract_resource_id.call(job)

            if ActiveJob::Limiter.acquire_throttle_lock(job, duration, resource_id, is_retry: false)
              # If this is the first time the job-resource has been called during a particular
              # throttle period, then this lock will be acquired and we can perform the job
              # immediately.
              block.call

              metrics_hook.call(:performed, job)
            elsif ActiveJob::Limiter.acquire_throttle_lock(job, duration, resource_id, is_retry: true)
              # If we can't acquire the main lock, and we wind up here, that means the job-resource
              # has been enqueued at least one additional time during the same throttle period. We
              # don't want to drop updates accidentally just because they happen to be high
              # frequency, so re-schedule this for later. Wait 1.1x the throttle period. This is to
              # help ensure that the job isn't performed again during the current throttle period
              # (i.e. before redis expires the throttle key, which could happen if sidekiq has a
              # faster clock than redis). If that were to happen, the retry would just be dropped,
              # which is not what we want. Making a copy of the job since I'm not sure what happens
              # if you call enqueue on a job that is supposed to be performed and I don't feel like
              # finding out.
              job.class.new(*job.arguments).enqueue(wait: duration * 1.1)

              metrics_hook.call(:rescheduled, job)
            else
              # If neither lock can be acquired (main or retry) that means this job has ran once
              # during the throttle period, and also attempted to run again and was rescheduled for
              # the future. In that case, we can drop the job.
              job.job_id = nil

              metrics_hook.call(:dropped, job)
            end
          end
        end
      end
    end
  end
end
