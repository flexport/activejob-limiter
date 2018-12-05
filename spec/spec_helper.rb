# frozen_string_literal: true

require 'bundler/setup'
require 'active_job'
require 'active_job/limiter'

RSpec.configure do |config|
  config.include(ActiveJob::TestHelper)

  before(:all) do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true
    ActiveJob::Base.queue_adapter.perform_enqueued_at_jobs = true
  end

  before(:each) do
    ActiveJob::Base.queue_adapter.performed_jobs = []
  end

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
