[![Open in DevZero](https://assets.devzero.io/open-in-devzero.svg)](https://www.devzero.io/dashboard/recipes/new?repo-url=https://github.com/flexport/activejob-limiter)

# Activejob Limiter

ActiveJob Limiter allows you to limit enqueing of ActiveJobs. Currently this is accomplished through hashing the arguments to the job and setting a lock while the job is in the queue, then dropping all following requests until a configurable expiration time. The only currently supported queue adapter is Sidekiq. The locking mechanism is naïve, however it directly uses the Sidekiq API and does not require any external libraries.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'activejob-limiter'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install activejob-limiter

## Usage

### Limiting Enqueing

Presently, you can only limit a queue to a single instance of a job/argument combination over a specified expiration time. ActiveJob Limiter will hash the arguments and create a lock in the Sidekiq redis instance.

You can activate it in an ActiveJob by adding a `limit_queue` line like:

```ruby
class LimitedJob < ActiveJob::Base
  limit_queue expiration: 5.minutes

  def perform(model_id, updates)
  	[...]
  end
end
```

The expiration time is how long additional enqueue attempts will be dropped. With an expiration time of 5 minutes, if a job sits in the queue for 8 minutes before being processed, one an additional job can be enqueued (after 5 minutes has passed). The expiration time will be converted to seconds and set via the adapter logic. For Sidekiq, this is the expiration on the Redis key.

Calls to `perform_later` will succeed even though the job was not enqueued, however the job_id on the returned object will be set to nil to indicate that the enqueuing did not happen.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/flexport/activejob-limiter. Contributions are welcomed for other queue adapters.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
