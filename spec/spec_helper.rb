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
    # DevAdmin lazily memoizes process-wide singletons (message_log,
    # request_inspector, mailbox, error_tracker). The mailbox in particular
    # resolves its dir from TINA4_MAILBOX_DIR / data/mailbox AT CONSTRUCTION, so
    # a singleton built in one spec must not leak captured state (or a stale
    # dir) into a later spec. This made DevMailbox#seed flaky under the full
    # randomized suite (e.g. --seed 24846): a contaminating spec left the shared
    # singleton (or a TINA4_MAILBOX_DIR override) in place, so a later mailbox
    # read surfaced foreign messages instead of its own. Reset the singletons
    # AND scrub the env override after every example (parity with the Frond /
    # ServiceRunner resets above; Python uses an autouse fixture for the same
    # isolation).
    Tina4::DevAdmin.reset_singletons! if defined?(Tina4::DevAdmin) && Tina4::DevAdmin.respond_to?(:reset_singletons!)
    ENV.delete("TINA4_MAILBOX_DIR") if ENV.key?("TINA4_MAILBOX_DIR")
  end
end
