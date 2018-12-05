# frozen_string_literal: true

module ActiveJob
  module Limiter
    module QueueAdapters
      module TestAdapter
        class MethodNotStubbedError < StandardError; end

        def self.check_lock_before_enqueue(_job, _expiration)
          raise MethodNotStubbedError, 'This method must be stubbed in tests'
        end

        def self.clear_lock_before_perform(_job)
          raise MethodNotStubbedError, 'This method must be stubbed in tests'
        end
      end
    end
  end
end
