# frozen_string_literal: true

require 'active_support/dependencies/autoload'

module ActiveJob
  module Limiter
    module QueueAdapters
      extend ActiveSupport::Autoload

      autoload :SidekiqAdapter
      autoload :TestAdapter
    end
  end
end
