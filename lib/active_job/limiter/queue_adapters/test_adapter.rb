# frozen_string_literal: true

module ActiveJob
  module Limiter
    module QueueAdapters
      module TestAdapter
        def self.check_lock_before_enqueue(_job, _expiration)
          true
        end

        def self.clear_lock_before_perform(_job)
          true
        end

        def acquire_throttle_lock(_job, _expiration, _resource_id)
          true
        end

        def acquire_throttle_retry_lock(_job, _expiration, _resource_id)
          true
        end

        def reschedule_job_for_future(_job, _expiration)
          true
        end
      end
    end
  end
end
