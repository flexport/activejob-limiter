# frozen_string_literal: true

RSpec.describe ActiveJob::Limiter do
  let(:expiration_time) { 2.minutes }

  class LimitedJob < ActiveJob::Base
    include ActiveJob::Limiter::Mixin # Needed without Rails autoloading

     # Same as :expiration_time above, unable to access let()
    limit_queue expiration: 2.minutes

    def perform; end
  end

  class StandardJob < ActiveJob::Base
    include ActiveJob::Limiter::Mixin # Needed without Rails autoloading

    def perform; end
  end

  it 'has a version number' do
    expect(::ActiveJob::Limiter::VERSION).not_to be_nil
  end

  it 'checks a lock before enqueuing a job' do
    allow(ActiveJob::Limiter).to receive(:clear_lock_before_perform).and_return(true)
    expect(ActiveJob::Limiter).to receive(:check_lock_before_enqueue)
      .with(instance_of(LimitedJob), expiration_time).and_return(true)
    LimitedJob.perform_later
    expect(performed_jobs.size).to eq(1)
  end

  it 'does not enqueue the job if the lock check returns false' do
    expect(ActiveJob::Limiter).to receive(:check_lock_before_enqueue)
      .with(instance_of(LimitedJob), expiration_time).and_return(false)
    expect(ActiveJob::Limiter).to_not receive(:clear_lock_before_perform)
    LimitedJob.perform_later
    expect(performed_jobs.size).to eq(0)
  end

  it 'clears the lock before performing a job' do
    allow(ActiveJob::Limiter).to receive(:check_lock_before_enqueue).and_return(true)
    expect(ActiveJob::Limiter).to receive(:clear_lock_before_perform)
      .with(instance_of(LimitedJob))
    LimitedJob.perform_later
    expect(performed_jobs.size).to eq(1)
  end

  it 'does not check or clear a lock for jobs that do not have the limit_queue directive' do
    expect(ActiveJob::Limiter).to_not receive(:check_lock_before_enqueue)
    expect(ActiveJob::Limiter).to_not receive(:clear_lock_before_perform)
    StandardJob.perform_later
    expect(performed_jobs.size).to eq(1)
  end
end
