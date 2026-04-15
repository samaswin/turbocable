# frozen_string_literal: true

require "bundler/gem_tasks"

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
rescue LoadError
  # rspec not available in this environment
end

begin
  require "standard/rake"
rescue LoadError
  # standard not available in this environment
end

task default: %i[spec standard]
