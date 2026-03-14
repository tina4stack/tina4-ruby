# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "json"

# Set test environment
ENV["TINA4_DEBUG_LEVEL"] = "[TINA4_LOG_NONE]"
ENV["ENVIRONMENT"] = "test"

# Add lib to load path
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")

require "tina4"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random

  # Clean up after each test
  config.after(:each) do
    Tina4::Router.clear! if defined?(Tina4::Router) && Tina4::Router.respond_to?(:clear!)
    Tina4::Middleware.clear! if defined?(Tina4::Middleware) && Tina4::Middleware.respond_to?(:clear!)
  end
end
