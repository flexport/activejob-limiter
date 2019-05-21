# frozen_string_literal: true

require 'active_job/limiter/version'
require 'active_support/dependencies/autoload'

module ActiveJob
  module Limiter
    extend ActiveSupport::Autoload
    class UnsupportedActiveJobLimiterQueueAdapter; end

    autoload :Mixin
    autoload :QueueAdapters

    class << self
      def check_lock_before_enqueue(job, expiration)
        queue_adapter(job).check_lock_before_enqueue(job, expiration)
      end

      def clear_lock_before_perform(job)
        queue_adapter(job).clear_lock_before_perform(job)
      end

      def queue_adapter(job)
        queue_adapter_by_class(job)
      end

      def queue_adapter_by_class(job)
        case job.class.queue_adapter.class.name
        when 'ActiveJob::QueueAdapters::TestAdapter'
          ActiveJob::Limiter::QueueAdapters::TestAdapter
        when 'ActiveJob::QueueAdapters::SidekiqAdapter'
          ActiveJob::Limiter::QueueAdapters::SidekiqAdapter
        else
          raise UnsupportedActiveJobLimiterQueueAdapter
        end
      end
    end
  end
end

require 'active_job/limiter/railtie' if defined?(Rails)
