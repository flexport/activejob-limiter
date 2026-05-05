# frozen_string_literal: true

RSpec.describe ActiveJob::Limiter do
  let(:debounce_duration) { 30.seconds }
  let(:resource_id) { '456' }
  let(:queue_name) { :default_queue }

  # spec_helper only resets performed_jobs; enqueued_jobs must be cleared separately
  before :each do
    ActiveJob::Base.queue_adapter.enqueued_jobs = []
  end

  class DebounceMetricsProxy
    def self.call(result, job); end
  end

  class DebouncedJob < ActiveJob::Base
    include ActiveJob::Limiter::Mixin # Needed without Rails autoloading

    # Same as :queue_name above, unable to access let()
    queue_as :default_queue

    # Same as :debounce_duration above, unable to access let()
    debounce_job(
      duration: 30.seconds,
      extract_resource_id: ->(job) { job.arguments.first },
      metrics_hook: DebounceMetricsProxy
    )

    def perform(resource_id); end
  end

  class StandardJob < ActiveJob::Base
    include ActiveJob::Limiter::Mixin # Needed without Rails autoloading

    def perform; end
  end

  # Mocks (preconditions)

  def mock_trigger_claims_slot
    expect(ActiveJob::Limiter).to receive(:register_debounce_trigger)
      .with(instance_of(DebouncedJob), debounce_duration, resource_id).and_return(true)
  end

  def mock_trigger_slot_already_taken
    expect(ActiveJob::Limiter).to receive(:register_debounce_trigger)
      .with(instance_of(DebouncedJob), debounce_duration, resource_id).and_return(false)
  end

  def mock_execution_claim_succeeds
    expect(ActiveJob::Limiter).to receive(:claim_debounce_execution)
      .with(instance_of(DebouncedJob), resource_id)
      .and_return(ActiveJob::Limiter::QueueAdapters::SidekiqAdapter::DebounceClaim.new(true, 0.0))
  end

  def mock_execution_claim_needs_reschedule(remaining_wait)
    expect(ActiveJob::Limiter).to receive(:claim_debounce_execution)
      .with(instance_of(DebouncedJob), resource_id)
      .and_return(ActiveJob::Limiter::QueueAdapters::SidekiqAdapter::DebounceClaim.new(false, remaining_wait))
  end

  # Expectations

  def expect_job_performed
    expect_any_instance_of(DebouncedJob).to receive(:perform).with(resource_id)
  end

  def expect_job_not_performed
    expect_any_instance_of(DebouncedJob).to_not receive(:perform).with(resource_id)
  end

  def expect_metric(result)
    expect(DebounceMetricsProxy).to receive(:call).with(result, instance_of(DebouncedJob))
  end

  # Simulates the internal delayed job waking up: enqueued without wait: so perform_enqueued_jobs=true
  # causes it to execute immediately, triggering around_perform.
  def trigger_perform_phase(queue: :default_queue)
    job = DebouncedJob.new(resource_id)
    job.instance_variable_set(:@bypass_active_job_limiter_debounce, true)
    job.enqueue(queue: queue)
  end

  # around_enqueue: exercised via perform_later

  context 'first trigger in a burst (slot claimed)' do
    before :each do
      mock_trigger_claims_slot
    end

    it 'enqueues one internal delayed job and emits scheduled metric' do
      # Arrange
      expect_metric('enqueue.scheduled')

      # Act
      result = DebouncedJob.perform_later(resource_id)

      # Assert
      # perform_later returns false when around_enqueue suppresses block.call
      expect(result).to be false
      expect(enqueued_jobs.size).to eq(1)
    end
  end

  context 'subsequent trigger during burst (slot already taken)' do
    before :each do
      mock_trigger_slot_already_taken
    end

    it 'coalesces the trigger: no new job enqueued, emits coalesced metric' do
      # Arrange
      expect_metric('enqueue.coalesced')

      # Act
      result = DebouncedJob.perform_later(resource_id)

      # Assert
      expect(result).to be false
      expect(enqueued_jobs).to be_empty
    end
  end

  # around_perform: exercised by enqueueing a bypass job without wait so it runs immediately

  context 'scheduled job wakes up and target time has passed' do
    before :each do
      mock_execution_claim_succeeds
    end

    it 'performs the job and emits performed metric' do
      # Arrange
      expect_job_performed
      expect_metric('perform.performed')

      # Act + Assert
      trigger_perform_phase
    end
  end

  context 'scheduled job wakes up but a newer trigger has extended the target' do
    let(:remaining_wait) { 15.0 }

    before :each do
      mock_execution_claim_needs_reschedule(remaining_wait)
    end

    it 'reschedules a new delayed job, does not perform, emits rescheduled metric' do
      # Arrange
      expect_job_not_performed
      expect_metric('perform.rescheduled')

      # Act + Assert
      expect { trigger_perform_phase }.to change { enqueued_jobs.size }.by(1)
    end

    context 'when queue is explicitly set' do
      let(:queue_name) { :a_different_queue }

      it 'preserves the queue name on the rescheduled job' do
        # Arrange
        expect_job_not_performed
        allow(DebounceMetricsProxy).to receive(:call)

        # Act
        trigger_perform_phase(queue: queue_name)

        # Assert
        expect(enqueued_jobs.last['queue_name']).to eq(queue_name.to_s)
      end
    end
  end

  context 'bypass flag set (internal scheduled/rescheduled job passing through enqueue)' do
    before :each do
      mock_execution_claim_succeeds
    end

    it 'enqueues and performs normally without calling register_debounce_trigger' do
      # Arrange
      expect(ActiveJob::Limiter).to_not receive(:register_debounce_trigger)
      expect_job_performed
      allow(DebounceMetricsProxy).to receive(:call)

      # Act + Assert
      trigger_perform_phase
    end
  end

  context 'extract_resource_id lambda' do
    it 'receives the full job object with its arguments' do
      # Arrange
      received_job = nil
      job_class = Class.new(ActiveJob::Base) do
        include ActiveJob::Limiter::Mixin

        debounce_job(
          duration: 10.seconds,
          extract_resource_id: lambda { |j|
            received_job = j
            j.arguments.first
          }
        )

        def perform(resource_id); end
      end

      allow(ActiveJob::Limiter).to receive(:register_debounce_trigger).and_return(true)

      # Act
      job_class.perform_later('my-resource')

      # Assert
      expect(received_job).to be_a(job_class)
      expect(received_job.arguments).to eq(['my-resource'])
    end
  end

  context 'job without debounce_job directive' do
    it 'is unaffected — no debounce methods called' do
      # Arrange
      expect(ActiveJob::Limiter).to_not receive(:register_debounce_trigger)
      expect(ActiveJob::Limiter).to_not receive(:claim_debounce_execution)
      expect_any_instance_of(StandardJob).to receive(:perform)

      # Act + Assert
      StandardJob.perform_later
    end
  end
end
