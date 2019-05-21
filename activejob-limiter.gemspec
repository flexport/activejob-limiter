# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'active_job/limiter/version'

Gem::Specification.new do |spec|
  spec.name          = 'activejob-limiter'
  spec.version       = ActiveJob::Limiter::VERSION
  spec.authors       = ['Nicholas Silva']
  spec.email         = ['nicholas.silva@flexport.com']

  spec.summary       = 'ActiveJob Limiter allows you to limit job enqueuing.'
  spec.description   = <<-DESC
    ActiveJob Limiter allows you to limit enqueing of ActiveJobs. Currently this
    is accomplished through hashing the arguments to the job and setting a lock
    while the job is in the queue. The only currently supported queue adapter
    is Sidekiq.
  DESC
  spec.homepage      = 'https://github.com/flexport/activejob-limiter'
  spec.license       = 'MIT'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir['{lib}/**/*', 'README.md']
  spec.test_files = Dir['spec/**/*']

  spec.require_paths = ['lib']

  spec.add_dependency 'activejob', '>= 5.1.6.1'
  spec.add_dependency 'activesupport', '>= 5.1.6.1'

  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.6'
  spec.add_development_dependency 'rubocop'
end
