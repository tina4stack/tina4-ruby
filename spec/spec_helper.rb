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
require "tina4/dev"

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
    Tina4::Container.reset if defined?(Tina4::Container) && Tina4::Container.respond_to?(:reset)
    # v3.13.5: Frond.add_filter/add_global/add_test persist in a class-level
    # registry so a single startup call survives all later Frond.new
    # instances. Without this clear, an earlier spec's add_global("name",
    # "Global") leaks into a later spec that expects the missing-variable
    # fallback. Same pattern Python uses via an autouse fixture and Node
    # uses via clearRegistry() in i18n-leaf-alias.test.ts.
    Tina4::Frond.clear_registry if defined?(Tina4::Frond) && Tina4::Frond.respond_to?(:clear_registry)
    # ServiceRunner registry is also class-level — parity_graphql_service_spec
    # registers "parity-test-svc" and never clears, so the next spec that calls
    # ServiceRunner.list.first sees a stale entry instead of its own. Reproduces
    # under seed 27302 with the full suite; passes in isolation.
    Tina4::ServiceRunner.clear! if defined?(Tina4::ServiceRunner) && Tina4::ServiceRunner.respond_to?(:clear!)
  end
end
