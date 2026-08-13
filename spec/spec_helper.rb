# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "json"

# Set test environment
# TINA4_DEBUG_LEVEL was the pre-3.14 spelling and is now a REMOVED setting
# (Decision 19) -- it hard-fails configuration rather than being silently
# ignored. TINA4_LOG_LEVEL=NONE is the current canonical way to keep the
# console silent for the whole suite (log-level cases override it per spec).
ENV["TINA4_LOG_LEVEL"] = "NONE"
ENV["ENVIRONMENT"] = "test"

# Add lib to load path
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")

require "tina4"
require "tina4/dev"

# Tracked temp directories, reaped when the process ends. Bare Dir.mktmpdir (no
# block) never cleans up, and nine spec files had no teardown for theirs -- the
# lab's /tmp held ~55-59 `d<date>-<pid>-` entries per rspec process, growing
# every run. See spec/support/spec_tmpdir.rb for the audit.
require_relative "support/spec_tmpdir"
SpecTmpdir.sandbox!            # BEFORE anything resolves a temp path
at_exit { SpecTmpdir.reap }

# ── Canonical repo paths, defined ONCE ────────────────────────────────────────
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL - it is not scoped to the block. Five spec files each declared their own
# REPO_ROOT / REPO_LIB / EXE / RUBY_BIN, so every run printed
# "warning: already initialized constant ..." and whichever file loaded last won.
#
# That is not cosmetic. The identical mistake with a DIFFERENT value took a whole
# afternoon: queue_delay_invariant_spec declared a bare PORT, overwrote
# dev_admin_run_chips_spec's `PORT = free_port` with MongoDB's 27017, and eight
# dev-admin examples died with EOFError because they were speaking HTTP to mongod.
#
# These four values were IDENTICAL in every file, so defining them once here and
# deleting the copies changes no behaviour and removes the collision class. The
# names are unchanged, so no usage site needed touching.
REPO_ROOT = File.expand_path("..", __dir__)
REPO_LIB  = File.join(REPO_ROOT, "lib")
EXE       = File.join(REPO_ROOT, "exe", "tina4ruby")
RUBY_BIN  = RbConfig.ruby

# ── Real-service test gate (TINA4_REQUIRE_SERVICES) ───────────────────────────
#
# Mirror of tests/conftest.py in tina4-python (the master). CI provisions
# PostgreSQL, MySQL, MSSQL, Redis, Valkey, Memcached, MongoDB, RabbitMQ and
# Kafka and sets every TINA4_TEST_* URL, so the real-service integration specs
# MUST run instead of skipping (the gap that let the migration/queue bugs ship
# green). When TINA4_REQUIRE_SERVICES is truthy, a spec that SKIPPED because one
# of those PROVISIONED services (or its client gem) is unavailable is turned
# into a hard FAILURE — the whole run exits non-zero. MySQL and MSSQL joined the
# provisioned set in #262 (mysql2 + tiny_tds in the OPTIONAL :databases bundle
# group, CI installs the native client libs), so their reachability / driver
# skips now fail the gate too. Firebird is NOT provisioned, so its skip reasons
# never match these keywords and stay green.
#
# RSpec marks `skip "msg"` as pending with that message in
# example.execution_result.pending_message. At suite end the gate WALKS EVERY
# EXAMPLE RSpec knows about (RSpec.world, recursing into nested groups), records
# any offending message, and exits non-zero. (Raising in after(:each) does NOT
# fail a pending example — RSpec swallows it and the run stays green — so the
# failure is forced at suite end, the clean equivalent of pytest's makereport
# outcome-flip in the Python master.)
#
# The walk — rather than an after(:each) recorder — is what makes the gate
# WHOLE. RSpec does NOT run after(:each) hooks for an example skipped by a
# `before(:context)` / `before(:all)` hook: the group's run aborts with
# Pending::SkipDeclaredInExample and each example is finished via
# Example#skip_with_exception, which never enters the per-example hook chain. A
# recorder living in after(:each) therefore never fires for those examples, so a
# spec gating a provisioned service with `before(:all) { skip "... not
# reachable" }` used to skip GREEN under TINA4_REQUIRE_SERVICES — exactly the
# no-green-skips guarantee this gate exists to provide. skip_with_exception DOES
# still write execution_result.pending_message on every affected example, so the
# suite-end walk sees before(:context) skips and per-example skips alike. Locked
# in by spec/require_services_gate_spec.rb, which runs a REAL rspec subprocess
# over both shapes.
TINA4_GATE_SERVICE_KEYWORDS = [
  "postgres", "postgresql", "psycopg2", # psycopg2 kept for cross-framework message parity
  "pg",                                  # Ruby's PostgreSQL client gem ("pg gem not installed")
  "mysql",                               # MySQL + its mysql2 client gem (#262)
  "mssql", "sqlserver",                  # MSSQL + its tiny_tds client gem (#262)
  "redis", "valkey", "memcached",
  "mongo",                               # also matches "mongodb"
  "rabbit", "amqp",
  "kafka",                               # also matches "rdkafka"
  "mqtt", "mosquitto",                   # Eclipse Mosquitto for the MQTT specs
  # GreenMail (real SMTP 3025 / IMAP 3143) for the Messenger IMAP specs. 16 of
  # those specs sat pending on "GreenMail mail server not reachable" with no
  # mail keyword here, so they passed green in CI indefinitely.
  "greenmail", "smtp", "imap"
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

# Yield every example in `groups` and, recursively, in their nested groups.
# Deliberately built from #examples/#children rather than a per-example hook —
# see the before(:context) hole documented above. Examples that never ran (e.g.
# filtered out) simply carry a nil pending_message and are ignored by the caller.
def tina4_gate_each_example(groups, &block)
  groups.each do |group|
    group.examples.each(&block)
    tina4_gate_each_example(group.children, &block)
  end
end

# ── Tina4::Log console-sink hygiene ───────────────────────────────────────────
#
# Tina4::Log memoises WHERE it writes in class ivars at configure time, and
# Log#log gates the console branch on `@output != "file"`. So a spec that
# configures Log for its own purposes leaves every LATER spec logging to the log
# FILE, and any spec that captures $stdout to assert on a warning captures ""
# instead - at some seeds only, depending on whether it happens to run inside
# the window before something reconfigures Log.
#
# This is NOT a spec forgetting to clean up. MEASURED on the lab: all eight
# sites that do this (six in env_vars_spec.rb, one in mqtt_auth_tls_spec.rb, and
# one in logger_contract_spec.rb which is inside a forked child and harmless)
# save and restore TINA4_LOG_OUTPUT correctly. What they cannot restore is a
# PRIVATE memo they have no supported way to reach - restoring the ENV VAR is
# not restoring the MEMO. Ten spec files assert on captured log text and every
# one of them is exposed, so the invariant is made true by construction here
# rather than asking ten files (and every future one) to defend themselves.
#
# Found by seed 55555 (cache_provider_selection_spec "an unreachable backend
# logs a warning", Captured: "") after seeds 777/31337/1111/2468/13579/4242 all
# passed. Two seeds is a floor, not a proof.
#
# 2026-08-13: Log's internal state shrank to two ivars (@snapshot, @pid) in
# the logger_contract.json conformance rewrite -- @snapshot is REPLACED
# atomically on every configure() rather than a handful of ivars memoised
# piecemeal, so restoring just @snapshot (and @pid, to avoid a spurious
# fork-detection reset firing on a restored snapshot) is the direct analog of
# the old per-ivar restoration below.
TINA4_LOG_STATE_IVARS = %i[@snapshot @pid].freeze

RSpec.configure do |config|
  config.after(:suite) do
    # Record any provisioned-service skip so the suite fails on it (see above).
    if tina4_require_services?
      tina4_gate_each_example(RSpec.world.example_groups) do |example|
        reason = example.execution_result.pending_message
        next unless reason && tina4_provisioned_service_skip?(reason)

        TINA4_GATE_VIOLATIONS << "#{example.full_description} (#{example.location}): #{reason.strip}"
      end
    end

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

  # ── Tina4::Log console-sink memo (see TINA4_LOG_CONSOLE_MEMO_IVARS above) ────
  #
  # Snapshot the sink once, then put it back before EVERY example, so no spec
  # can be poisoned by an earlier one regardless of what that one did.
  #
  # BEFORE each example, not after, and deliberately so. An after(:each) is the
  # pattern used below for Router/Frond/ServiceRunner, but it is the weaker
  # guarantee here: RSpec does NOT run after(:each) for an example skipped by a
  # before(:context) hook (this file's own gate documents that), so a leak from
  # a group-level hook would survive it. "Every example STARTS at the baseline"
  # cannot be defeated that way.
  #
  # prepend_before puts this first, so a spec's own before(:each) that
  # configures Log still wins for that example - this restores the baseline, it
  # does not fight legitimate per-example setup.
  tina4_log_console_baseline = nil

  config.before(:suite) do
    Tina4::Log.configure if Tina4::Log.instance_variable_get(:@snapshot).nil?
    tina4_log_console_baseline = TINA4_LOG_STATE_IVARS.to_h do |ivar|
      [ivar, Tina4::Log.instance_variable_get(ivar)]
    end
  end

  config.prepend_before(:each) do
    tina4_log_console_baseline&.each do |ivar, value|
      Tina4::Log.instance_variable_set(ivar, value)
    end
  end

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
    # Tina4::RackApp.current is process-wide too (last constructed wins) — it is
    # what Tina4::TestClient falls back to when no app is passed. Without this
    # reset, a RackApp built by one spec (rooted at that spec's temp dir) would
    # silently become the app a LATER spec's bare TestClient.new dispatches
    # through, under the randomized order. Same isolation as the resets above.
    Tina4::RackApp.current = nil if defined?(Tina4::RackApp) && Tina4::RackApp.respond_to?(:current=)
  end
end
