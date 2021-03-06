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
      end
    end
  end
end
