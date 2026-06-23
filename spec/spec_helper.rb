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

# ── Real-service test gate (TINA4_REQUIRE_SERVICES) ───────────────────────────
#
# Mirror of tests/conftest.py in tina4-python (the master). CI provisions
# PostgreSQL, Redis, Valkey, Memcached, MongoDB, RabbitMQ and Kafka and sets
# every TINA4_TEST_* URL, so the real-service integration specs MUST run instead
# of skipping (the gap that let the migration/queue bugs ship green). When
# TINA4_REQUIRE_SERVICES is truthy, a spec that SKIPPED because one of those
# PROVISIONED services (or its client gem) is unavailable is turned into a hard
# FAILURE — the whole run exits non-zero. MySQL / MSSQL / Firebird are NOT
# provisioned, so their skip reasons never match these keywords and stay green.
#
# RSpec marks `skip "msg"` as pending with that message in
# example.execution_result.pending_message. An after(:each) (which still runs
# for skipped examples) records any offending message; after(:suite) exits
# non-zero if any were recorded. (Raising in after(:each) does NOT fail a
# pending example — RSpec swallows it and the run stays green — so the failure
# is forced at suite end, the clean equivalent of pytest's makereport
# outcome-flip in the Python master.)
TINA4_GATE_SERVICE_KEYWORDS = [
  "postgres", "postgresql", "psycopg2", # psycopg2 kept for cross-framework message parity
  "pg",                                  # Ruby's PostgreSQL client gem ("pg gem not installed")
  "redis", "valkey", "memcached",
  "mongo",                               # also matches "mongodb"
  "rabbit", "amqp",
  "kafka"                                # also matches "rdkafka"
].freeze

TINA4_GATE_UNAVAILABLE_HINTS = [
  "not reachable", "unreachable", "not running", "not set",
  "not installed", "could not connect", "not available", "refused"
].freeze

TINA4_GATE_VIOLATIONS = []

def tina4_require_services?
  %w[1 true yes on].include?(ENV["TINA4_REQUIRE_SERVICES"].to_s.strip.downcase)
end

def tina4_provisioned_service_skip?(reason)
  low = reason.to_s.downcase
  TINA4_GATE_SERVICE_KEYWORDS.any? { |k| low.include?(k) } &&
    TINA4_GATE_UNAVAILABLE_HINTS.any? { |h| low.include?(h) }
end

RSpec.configure do |config|
  # Record any provisioned-service skip so the suite can fail on it (see above).
  config.after(:each) do |example|
    if tina4_require_services?
      reason = example.execution_result.pending_message
      if reason && tina4_provisioned_service_skip?(reason)
        TINA4_GATE_VIOLATIONS << "#{example.full_description} (#{example.location}): #{reason.strip}"
      end
    end
  end

  config.after(:suite) do
    unless TINA4_GATE_VIOLATIONS.empty?
      warn "\n#{'=' * 78}"
      warn "TINA4_REQUIRE_SERVICES is set, but #{TINA4_GATE_VIOLATIONS.length} real-service " \
           "spec(s) SKIPPED because a provisioned service or client gem is missing:"
      TINA4_GATE_VIOLATIONS.each { |v| warn "  - #{v}" }
      warn "Provision the service / install the client gem, or unset TINA4_REQUIRE_SERVICES."
      warn "=" * 78
      exit(1)
    end
  end

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
    # The global DB binding is process-wide state too. Many specs call
    # Tina4.bind_database(db) in before(:each) and never reset it, so under the
    # randomized order it leaks into specs that assume none is bound -- e.g.
    # query_builder's "no database connection" tests fail when an earlier orm /
    # crud / seeder / auto_crud spec left a connection bound (reproduces under
    # --seed 37099 with the real-service env, passes in isolation). Reset the
    # default + named registry after every example, exactly like the resets
    # above. All current binds are before(:each)/in-example; a future
    # before(:all) bind would need its own after(:all). The Python master never
    # hit this because pytest runs in deterministic order.
    if defined?(Tina4) && Tina4.respond_to?(:bind_database)
      Tina4.instance_variable_set(:@database, nil)
      Tina4.instance_variable_set(:@databases, {})
    end
  end
end
