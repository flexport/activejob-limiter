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
        if job.class.respond_to? :queue_adapter_name
          # Rails >= 5.2
          queue_adapter_by_name(job)
        else
          # Rails < 5.2
          queue_adapter_by_class(job)
        end
      end

      def queue_adapter_by_name(job)
        case job.class.queue_adapter_name
        when 'test'
          ActiveJob::Limiter::QueueAdapters::TestAdapter
        when 'sidekiq'
          ActiveJob::Limiter::QueueAdapters::SidekiqAdapter
        else
          raise UnsupportedActiveJobLimiterQueueAdapter
        end
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
