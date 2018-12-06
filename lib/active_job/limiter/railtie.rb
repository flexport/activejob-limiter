# frozen_string_literal: true

require 'global_id/railtie'
require 'active_job'

module ActiveJob
  module Limiter
    class Railtie < Rails::Railtie
      ActiveSupport.on_load(:active_job) do
        include ActiveJob::Limiter::Mixin
      end
    end
  end
end
