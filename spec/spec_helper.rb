# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch
  # Phase 0 ships an empty skeleton; the 90% floor kicks in once real code
  # lands in Phase 1. Leaving the floor off here keeps the placeholder spec
  # from failing a coverage check against a file with no executable lines.
  # minimum_coverage 90
end

require "turbocable"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed
end
