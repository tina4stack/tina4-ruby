# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "fileutils"
require "tmpdir"
require "json"

# Set test environment
# TINA4_DEBUG_LEVEL was the pre-3.14 spelling and is now a REMOVED setting
# (Decision 19) -- it hard-fails configuration rather than being silently
# ignored. TINA4_LOG_LEVEL=NONE is the current canonical way to keep the
# console silent for the whole suite (log-level cases override it per spec).
ENV["TINA4_LOG_LEVEL"] = "NONE"
# No spec may open a real browser tab. Children spawned by specs inherit this;
# spec/run_no_browser_spec.rb unsets it on purpose, with a recording launcher.
ENV["TINA4_NO_BROWSER"] ||= "true"
ENV["ENVIRONMENT"] = "test"

# A test run must never open the developer's browser. The server opens a tab
# after boot unless TINA4_NO_BROWSER is set, and not every spec that spawns a
# server sets it. Set it ONCE here, before any child exists, so every spawn
# inherits it. ||= : a spec that checks the browser-opening path still
# overrides it for its own child. Guarded by spec/no_browser_default_spec.rb.
ENV["TINA4_NO_BROWSER"] ||= "true"

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
# Mirror of tests/conftest.py in tina4-python (the master); the rule is the same
# in all four frameworks (ADR-0069 addendum F). When TINA4_REQUIRE_SERVICES is
# truthy, a skipped or pending example PASSES only if its reason carries a
# machine-readable `[needs:X]` tag AND X is excusable in this run:
#
#   * X is an OPTIONAL engine (TINA4_GATE_OPTIONAL_ENGINES): excused ONLY while
#     its coordinate env var is unset. A CI job that never promised the engine
#     stays green; a run that sets the coordinate (the lab sets all of them)
#     fails when the engine is not really there.
#   * X is an ALWAYS-provisioned service (TINA4_GATE_ALWAYS_SERVICES): never
#     excused - an unreachable one fails.
#   * Any other X (absent-ext=..., no-dac-override, os=..., runtime=...) is a
#     platform exclusion: always excused.
#   * An untagged skip FAILS. Every tag in a reason must be excusable.
#
# This replaced a keyword + phrase matcher that missed wordings such as "no
# reachable postgres" and "mongo backend unavailable", so those skipped green
# under the gate - ghost tests. A positive tag cannot be dodged by a wording.
#
# RSpec marks `skip "msg"` as pending with that message in
# example.execution_result.pending_message. At suite end the gate WALKS EVERY
# EXAMPLE RSpec knows about (RSpec.world, recursing into nested groups), records
# any reason it may not excuse, and exits non-zero. (Raising in after(:each)
# does NOT fail a pending example - RSpec swallows it and the run stays green -
# so the failure is forced at suite end, the clean equivalent of pytest's
# makereport outcome-flip in the Python master.)
#
# The walk - rather than an after(:each) recorder - is what makes the gate
# WHOLE. RSpec does NOT run after(:each) hooks for an example skipped by a
# `before(:context)` / `before(:all)` hook: each example is finished via
# Example#skip_with_exception, which never enters the per-example hook chain,
# but it DOES write execution_result.pending_message, so the suite-end walk sees
# before(:context) skips and per-example skips alike. Locked in by
# spec/require_services_gate_spec.rb, which runs a REAL rspec subprocess.
TINA4_GATE_NEEDS_TAG = /\[needs:([^\]\s]+)\]/.freeze

# Optional engine tag => the coordinate env vars that promise it in this run.
TINA4_GATE_OPTIONAL_ENGINES = {
  "firebird" => %w[TINA4_TEST_FIREBIRD_URL],
  # Only the canonical spelling: ADR-0038 retired TINA4_TEST_POSTGRES_URL.
  "postgres" => %w[TINA4_TEST_PG_URL],
  "postgis" => %w[TINA4_TEST_POSTGIS_URL],
  "mysql" => %w[TINA4_TEST_MYSQL_URL],
  "mssql" => %w[TINA4_TEST_MSSQL_URL],
  "swoole" => %w[TINA4_TEST_SWOOLE],
  "oidc" => %w[TINA4_TEST_OIDC_ISSUER],
  "neo4j" => %w[TINA4_TEST_NEO4J_URL],
  "memgraph" => %w[TINA4_TEST_MEMGRAPH_URL],
  "arango" => %w[TINA4_TEST_ARANGO_URL],
  "ultipa" => %w[TINA4_TEST_ULTIPA_URL]
}.freeze

# Services every gated run provisions: a skip tagged with one is never excused.
TINA4_GATE_ALWAYS_SERVICES = %w[
  mongo redis valkey memcached rabbitmq kafka mqtt smtp imap s3
].freeze

TINA4_GATE_VIOLATIONS = []

def tina4_require_services?
  %w[1 true yes on].include?(ENV["TINA4_REQUIRE_SERVICES"].to_s.strip.downcase)
end

# Whether one [needs:X] tag excuses a skip in this run (see the rule above).
def tina4_gate_tag_excused?(tag, env = ENV)
  return false if TINA4_GATE_ALWAYS_SERVICES.include?(tag)

  coordinates = TINA4_GATE_OPTIONAL_ENGINES[tag]
  return true if coordinates.nil? # a platform exclusion

  coordinates.all? { |name| env[name].to_s.strip.empty? }
end

# True for a skip/pending reason the gate must fail: untagged, or carrying any
# tag this run cannot excuse. nil (the example was not skipped) never fails.
def tina4_gate_violation?(reason, env = ENV)
  return false if reason.nil?

  tags = reason.to_s.scan(TINA4_GATE_NEEDS_TAG).flatten
  tags.empty? || !tags.all? { |tag| tina4_gate_tag_excused?(tag, env) }
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
  # SSRF guard opt-out for local-listener specs (ADR-0084). The Api client and
  # Web Push refuse private/internal addresses by default, so every spec that
  # points them at a 127.0.0.1 test server would now be refused. The suite
  # legitimately talks to loopback (the internal-service case
  # TINA4_ALLOW_PRIVATE_REQUESTS exists for), so it opts in by default. The
  # dedicated guard spec (spec/ssrf_guard_contract_spec.rb) deletes this in its
  # own before(:each), which runs after this one, so it still proves the
  # default-blocked behaviour.
  config.before(:each) do
    ENV["TINA4_ALLOW_PRIVATE_REQUESTS"] = "true"
  end

  config.after(:suite) do
    # Record every skip/pending the gate may not excuse (see above).
    if tina4_require_services?
      tina4_gate_each_example(RSpec.world.example_groups) do |example|
        reason = example.execution_result.pending_message
        next unless tina4_gate_violation?(reason)

        TINA4_GATE_VIOLATIONS << "#{example.full_description} (#{example.location}): #{reason.strip}"
      end
    end

    unless TINA4_GATE_VIOLATIONS.empty?
      warn "\n#{'=' * 78}"
      warn "TINA4_REQUIRE_SERVICES is set, but #{TINA4_GATE_VIOLATIONS.length} " \
           "spec(s) SKIPPED without an excusable [needs:...] tag:"
      TINA4_GATE_VIOLATIONS.each { |v| warn "  - #{v}" }
      warn "Provision the service / install the client gem, tag a genuine platform exclusion " \
           "with [needs:<what>], or unset TINA4_REQUIRE_SERVICES (see spec/spec_helper.rb)."
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
