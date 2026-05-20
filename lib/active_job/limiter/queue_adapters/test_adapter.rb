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

        def self.acquire_lock_for_job_resource(_name, _expiration, _job, _resource_id)
          true
        end

        def self.release_lock_for_job_resource(_name, _job, _resource_id)
          true
        end

        def self.register_debounce_trigger(_job, _duration, _resource_id)
          true
        end

        def self.claim_debounce_execution(_job, _resource_id)
          ActiveJob::Limiter::QueueAdapters::SidekiqAdapter::DebounceClaim.new(true, 0.0)
        end
      end
    end
  end
end
