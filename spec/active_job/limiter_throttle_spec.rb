# frozen_string_literal: true

RSpec.describe ActiveJob::Limiter do
  let(:throttle_duration) { 2.minutes }
  let(:resource_id) { '123' }

  class MetricsProxy
    def self.call(result, job); end
  end

  class ThrottledJob < ActiveJob::Base
    include ActiveJob::Limiter::Mixin # Needed without Rails autoloading

    # Same as :throttle_duration above, unable to access let()
    throttle_job(
      duration: 2.minutes,
      extract_resource_id: (lambda { |job|
        job.arguments.first
      }),
      metrics_hook: MetricsProxy
    )

    def perform(resource_id); end
  end

  class StandardJob < ActiveJob::Base
    include ActiveJob::Limiter::Mixin # Needed without Rails autoloading

    def perform; end
  end

  # Preconditions

  def enqueue_lock_not_yet_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('enqueue', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(true)
  end

  def enqueue_lock_already_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('enqueue', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(false)
  end

  def perform_lock_already_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('perform', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(false)
  end

  def perform_lock_not_yet_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('perform', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(true)
  end

  def perform_lock_already_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('perform', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(false)
  end

  def reschedule_lock_not_yet_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('reschedule', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(true)
  end

  def reschedule_lock_already_acquired
    expect(ActiveJob::Limiter).to receive(:acquire_lock_for_job_resource)
      .with('reschedule', throttle_duration, instance_of(ThrottledJob), resource_id).and_return(false)
  end

  # Expectations

  def job_should_be_performed
    expect_any_instance_of(ThrottledJob).to receive(:perform).with(resource_id)
  end

  def job_should_not_be_performed
    expect_any_instance_of(ThrottledJob).to_not receive(:perform).with(resource_id)
  end

  def new_job_should_be_enqueued(&blk)
    expect(blk).to change { enqueued_jobs.size  }.by(1)
  end

  def new_job_should_be_not_enqueued(&blk)
    expect(blk).to change { enqueued_jobs.size  }.by(0)
  end

  def enqueue_lock_should_be_released
    expect(ActiveJob::Limiter).to receive(:release_lock_for_job_resource)
      .with('enqueue', instance_of(ThrottledJob), resource_id)
  end

  def expect_metric(result)
    expect(MetricsProxy).to receive(:call).with(
      result,
      instance_of(ThrottledJob)
    )
  end

  context 'the job has not yet run during the throttle period' do
    before :each do
      enqueue_lock_not_yet_acquired
      perform_lock_not_yet_acquired
    end

    it 'performs the job' do
      enqueue_lock_should_be_released
      job_should_be_performed
      expect_metric('enqueue.enqueued')
      expect_metric('perform.performed')

      ThrottledJob.perform_later(resource_id)
    end
  end

  context 'the job has been enqueued but not yet run' do
    before :each do
      enqueue_lock_already_acquired
    end

    it 'drops the job' do
      job_should_not_be_performed
      expect_metric('enqueue.dropped')

      ThrottledJob.perform_later(resource_id)
    end
  end

  context 'the job has run one time already' do
    before :each do
      perform_lock_already_acquired
    end

    context 'a retry has not been scheduled' do
      before :each do
        reschedule_lock_not_yet_acquired
      end

      it 'enqueues a job for the future' do
        job_should_not_be_performed
        expect_metric('perform.rescheduled')

        new_job_should_be_enqueued do
          ThrottledJob.perform_now(resource_id)
        end
      end
    end

    context 'a retry has been scheduled' do
      before :each do
        reschedule_lock_already_acquired
      end

      it 'drops the job' do
        job_should_not_be_performed
        expect_metric('perform.dropped')

        new_job_should_be_not_enqueued do
          ThrottledJob.perform_now(resource_id)
        end
      end
    end
  end
end
