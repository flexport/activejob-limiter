# frozen_string_literal: true

require 'sidekiq'

REDIS_TEST_URL = ENV.fetch('REDIS_URL', 'redis://localhost:6389/0')

Sidekiq.configure_client { |cfg| cfg.redis = { url: REDIS_TEST_URL } }
Sidekiq.configure_server { |cfg| cfg.redis = { url: REDIS_TEST_URL } }

RSpec.describe ActiveJob::Limiter::QueueAdapters::SidekiqAdapter do
  let(:adapter) { described_class }
  let(:resource_id) { '567' }
  let(:duration) { 30 }

  # A minimal job class whose name is stable across examples
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name
        'TestAdapterJob'
      end

      def perform(*)
        ;
      end
    end
  end

  let(:job) { job_class.new('arg1') }

  # Helpers to absorb wall-clock drift between Ruby and Redis in tests
  TIMING_TOLERANCE = 1 # seconds
  def be_approximately(expected)
    be_between(expected - TIMING_TOLERANCE, expected + TIMING_TOLERANCE)
  end

  def be_approximately_before(expected)
    be_between(expected - TIMING_TOLERANCE, expected)
  end

  before(:each) do
    Sidekiq.redis { |c| c.flushdb }
  end

  describe "debounce" do
    let(:quiet_until_key) { "limiter:debounce:#{job_class.name}:#{resource_id}:quiet_until" }
    let(:is_job_scheduled_key) { "limiter:debounce:#{job_class.name}:#{resource_id}:is_job_scheduled" }

    describe '#register_debounce_trigger' do
      it 'returns true on the first trigger and creates both keys' do
        result = adapter.register_debounce_trigger(job, duration, resource_id)
        expect(result).to be true

        Sidekiq.redis do |c|
          quiet_until = c.get(quiet_until_key)
          scheduled = c.get(is_job_scheduled_key)
          expect(quiet_until.to_f).to be_approximately(Time.now.to_f + duration)
          expect(scheduled).to eq('1')
        end
      end

      it 'returns false on subsequent triggers (slot already taken)' do
        adapter.register_debounce_trigger(job, duration, resource_id)
        expect(adapter.register_debounce_trigger(job, duration, resource_id)).to be false
      end

      it 'slides quiet_until forward on each trigger' do
        adapter.register_debounce_trigger(job, duration, resource_id)
        first_quiet_until = Sidekiq.redis { |c| c.get(quiet_until_key).to_f }

        sleep(0.01)
        adapter.register_debounce_trigger(job, duration, resource_id)
        second_quiet_until = Sidekiq.redis { |c| c.get(quiet_until_key).to_f }

        expect(second_quiet_until).to be > first_quiet_until
      end

      it 'sets TTL on both keys equal to duration' do
        expected_ttl = duration + described_class::DEBOUNCE_TTL_BUFFER
        adapter.register_debounce_trigger(job, duration, resource_id)

        Sidekiq.redis do |c|
          quiet_until_ttl = c.ttl(quiet_until_key)
          scheduled_ttl = c.ttl(is_job_scheduled_key)
          expect(quiet_until_ttl).to be_approximately_before(expected_ttl)
          expect(scheduled_ttl).to be_approximately_before(expected_ttl)
        end
      end

      it 'does not refresh the scheduled key TTL on subsequent triggers' do
        adapter.register_debounce_trigger(job, duration, resource_id)
        Sidekiq.redis { |c| c.expire(is_job_scheduled_key, 10) } # manually lower TTL

        adapter.register_debounce_trigger(job, duration, resource_id)

        Sidekiq.redis do |c|
          expect(c.ttl(is_job_scheduled_key)).to be_approximately_before(10)
        end
      end
    end

    describe '#claim_debounce_execution' do
      context 'when quiet_until key is absent' do
        it 'returns a claimed DebounceClaim and leaves no keys' do
          claim = adapter.claim_debounce_execution(job, resource_id)
          expect(claim.is_claimed).to be true
          expect(claim.wait_seconds).to eq(0.0)
        end
      end

      context 'when quiet_until is in the past' do
        before do
          Sidekiq.redis do |c|
            c.set(quiet_until_key, (Time.now.to_f - 1).to_s, ex: 60)
            c.set(is_job_scheduled_key, '1', ex: 60)
          end
        end

        it 'returns a claimed DebounceClaim' do
          claim = adapter.claim_debounce_execution(job, resource_id)
          expect(claim.is_claimed).to be true
          expect(claim.wait_seconds).to eq(0.0)
        end

        it 'deletes both keys' do
          adapter.claim_debounce_execution(job, resource_id)
          Sidekiq.redis do |c|
            expect(c.exists(quiet_until_key)).to eq(0)
            expect(c.exists(is_job_scheduled_key)).to eq(0)
          end
        end
      end

      context 'when quiet_until is in the future' do
        let(:future_epoch) { Time.now.to_f + 15 }

        before do
          Sidekiq.redis do |c|
            c.set(quiet_until_key, future_epoch.to_s, ex: 60)
            c.set(is_job_scheduled_key, '1', ex: 10)
          end
        end

        it 'returns an unclaimed DebounceClaim with wait_seconds approximating remaining time' do
          claim = adapter.claim_debounce_execution(job, resource_id)
          expect(claim.is_claimed).to be false
          expect(claim.wait_seconds).to be_approximately(future_epoch - Time.now.to_f)
        end

        it 'extends the is_job_scheduled TTL to approximately remaining time + DEBOUNCE_TTL_BUFFER' do
          adapter.claim_debounce_execution(job, resource_id)
          expected_ttl = (future_epoch - Time.now.to_f + described_class::DEBOUNCE_TTL_BUFFER).ceil
          Sidekiq.redis do |c|
            expect(c.ttl(is_job_scheduled_key)).to be_approximately_before(expected_ttl)
          end
        end

        it 'keeps both keys alive' do
          adapter.claim_debounce_execution(job, resource_id)
          Sidekiq.redis do |c|
            expect(c.exists(quiet_until_key)).to eq(1)
            expect(c.exists(is_job_scheduled_key)).to eq(1)
          end
        end
      end
    end
  end
end
