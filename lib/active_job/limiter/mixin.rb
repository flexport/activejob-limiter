# frozen_string_literal: true

require 'active_support/concern'

module ActiveJob
  module Limiter
    # ActiveJob Limiter
    #
    # This extends ActiveJob::Base
    module Mixin
      extend ActiveSupport::Concern

      module ClassMethods
        def limit_queue(expiration:)
          # around_enqueue is preferred over before_enqueue so that we can
          # optionally enqueue the job. With before_enqueue, we would have
          # to raise an exception and handle it elsewhere to be able to stop
          # enqueuing.
          # https://groups.google.com/forum/#!topic/rubyonrails-core/mhD4T90g0G4
          around_enqueue do |job, block|
            if ActiveJob::Limiter.check_lock_before_enqueue(job, expiration)
              block.call
            else
              job.job_id = nil
            end
          end

          before_perform do |job|
            ActiveJob::Limiter.clear_lock_before_perform(job)
          end
        end
      end
    end
  end
end
