# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "tmpdir"
require "open3"

# Contract tests for the TINA4_REQUIRE_SERVICES gate in spec/spec_helper.rb.
#
# The gate guarantees NO GREEN SKIPS (ADR-0069 addendum F, the same rule in all
# four frameworks): with TINA4_REQUIRE_SERVICES=1 a skipped or pending example
# passes only if its reason carries a `[needs:X]` tag that is excusable in this
# run - an optional engine only while its coordinate env var is unset, an
# always-provisioned service never, a platform exclusion always. An untagged
# skip fails. It replaced a keyword + phrase matcher that missed wordings such
# as "no reachable postgres" and "mongo backend unavailable", which therefore
# skipped green.
#
# Two shapes must both be caught: a skip declared in `before(:all)` (RSpec does
# NOT run after(:each) for those, which is why the gate walks RSpec.world at
# suite end) and a skip declared per example.
#
# NO MOCKS: each example writes a real spec file and runs the REAL rspec binary
# against the REAL spec_helper in a subprocess, then asserts on the real exit
# status and real output. Nothing about the gate is simulated.
#
# The fixtures live at file scope, not inside the describe block: a constant
# assigned inside a block still lands on Object, so a bare REPO_ROOT here would
# become a global shared with every other spec in the suite.
TINA4_GATE_SPEC_REPO_ROOT = File.expand_path("..", __dir__)

# A skip declared in before(:all).
TINA4_GATE_SPEC_BEFORE_ALL = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (before(:all) skip)" do
      before(:all) { skip "Kafka not reachable on localhost:9092" }

      it "is skipped by the context hook" do
        expect(true).to be(true)
      end

      it "is skipped by the context hook too" do
        expect(true).to be(true)
      end
    end
  RUBY

# A skip declared per example.
TINA4_GATE_SPEC_PER_EXAMPLE = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (per-example skip)" do
      before { skip "Redis not reachable on localhost:6379" }

      it "is skipped by the per-example hook" do
        expect(true).to be(true)
      end
    end
  RUBY

# The wordings the old phrase list missed - the ghost tests this gate closes.
TINA4_GATE_SPEC_UNMATCHED_WORDINGS = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (wordings the phrase list missed)" do
      it "skips with no reachable" do
        skip "no reachable postgres at 127.0.0.1:5432"
      end

      it "skips with unavailable" do
        skip "mongo backend unavailable"
      end

      it "skips for a service the old list never named" do
        skip "Firebird not reachable on localhost:3050"
      end

      it "is marked pending" do
        pending "not written yet"
        raise "unfinished"
      end
    end
  RUBY

# A genuine platform exclusion, tagged: always excused.
TINA4_GATE_SPEC_PLATFORM = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (platform exclusion)" do
      before(:all) { skip "no blackhole route on this host [needs:blackhole-route]" }

      it "is skipped by a tagged context hook" do
        expect(true).to be(true)
      end
    end

    RSpec.describe "gate fixture (platform per-example skip)" do
      it "is skipped with a tag" do
        skip "[needs:os=posix] fork is POSIX-only"
      end

      it "still runs its neighbour" do
        expect(1 + 1).to eq(2)
      end
    end
  RUBY

# An optional engine: excused only while its coordinate env var is unset.
TINA4_GATE_SPEC_OPTIONAL_ENGINE = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (optional engine)" do
      it "is skipped when the neo4j engine is absent" do
        skip "live neo4j not configured [needs:neo4j]"
      end
    end
  RUBY

# An always-provisioned service: a tag never excuses it.
TINA4_GATE_SPEC_ALWAYS_SERVICE = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (always-provisioned service)" do
      it "is skipped when mongo is down" do
        skip "[needs:mongo] MongoDB not reachable on localhost:27017"
      end
    end
  RUBY

RSpec.describe "TINA4_REQUIRE_SERVICES gate" do
  # Write `sources` into a scratch dir OUTSIDE spec/ (so the normal suite never
  # collects them) and run a real rspec over them. `-I spec` puts the real
  # spec_helper on the load path; --seed keeps the subprocess deterministic.
  def run_gate(sources, env)
    Dir.mktmpdir("tina4_gate") do |dir|
      paths = Array(sources).each_with_index.map do |src, i|
        path = File.join(dir, "fixture_#{i}_spec.rb")
        File.write(path, src)
        path
      end

      full_env = { "TINA4_REQUIRE_SERVICES" => nil, "TINA4_TEST_KAFKA_URL" => nil,
                   "TINA4_TEST_NEO4J_URL" => nil }.merge(env)
      cmd = ["bundle", "exec", "rspec", "-I", "spec", "--no-color", "--seed", "0", *paths]
      out, status = Open3.capture2e(full_env, *cmd, chdir: TINA4_GATE_SPEC_REPO_ROOT)
      [out, status.exitstatus]
    end
  end

  # ── An untagged skip fails, in both shapes ──────────────────────────────────
  # Shared case name (all four frameworks): an_untagged_skip_fails_under_the_gate.
  it "an_untagged_skip_fails_under_the_gate" do
    out, code = run_gate(TINA4_GATE_SPEC_BEFORE_ALL, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), "a before(:all) untagged skip exited #{code} (green skip):\n#{out}"
    expect(out).to include("TINA4_REQUIRE_SERVICES is set, but 2 spec(s) SKIPPED without an excusable [needs:...] tag")
    expect(out).to include("is skipped by the context hook")
    expect(out).to include("is skipped by the context hook too")
    expect(out).to include("Kafka not reachable on localhost:9092")
  end

  it "fails the run for an untagged per-example skip" do
    out, code = run_gate(TINA4_GATE_SPEC_PER_EXAMPLE, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("Redis not reachable on localhost:6379")
  end

  it "fails the run for any wording, including the ones the phrase list missed" do
    out, code = run_gate(TINA4_GATE_SPEC_UNMATCHED_WORDINGS, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("4 spec(s) SKIPPED without an excusable [needs:...] tag")
    expect(out).to include("no reachable postgres at 127.0.0.1:5432")
    expect(out).to include("mongo backend unavailable")
    expect(out).to include("Firebird not reachable on localhost:3050")
    expect(out).to include("not written yet")
  end

  # ── A platform tag is always excused ────────────────────────────────────────
  # Shared case name: a_platform_tag_is_always_excused.
  it "a_platform_tag_is_always_excused" do
    out, code = run_gate(TINA4_GATE_SPEC_PLATFORM, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).to eq(0), out
    expect(out).to include("3 examples, 0 failures, 2 pending")
    expect(out).not_to include("TINA4_REQUIRE_SERVICES is set")
  end

  it "reports only the unexcused skips when excused and untagged are mixed" do
    out, code = run_gate([TINA4_GATE_SPEC_PLATFORM, TINA4_GATE_SPEC_PER_EXAMPLE],
                         "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("1 spec(s) SKIPPED without an excusable [needs:...] tag")
    expect(out).to include("Redis not reachable on localhost:6379")
    expect(out).not_to include("  - gate fixture (platform")
  end

  # ── An optional engine is excused only while its coordinate is unset ────────
  # Shared case name: an_optional_engine_is_excused_only_while_its_coordinate_is_unset.
  it "an_optional_engine_is_excused_only_while_its_coordinate_is_unset" do
    # Coordinate unset: the run never promised neo4j, so the tagged skip passes.
    out, code = run_gate(TINA4_GATE_SPEC_OPTIONAL_ENGINE, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).to eq(0), out
    expect(out).to include("1 example, 0 failures, 1 pending")

    # Coordinate set: the run promised neo4j, so the same skip fails.
    out, code = run_gate(TINA4_GATE_SPEC_OPTIONAL_ENGINE,
                         "TINA4_REQUIRE_SERVICES" => "1", "TINA4_TEST_NEO4J_URL" => "neo4j://127.0.0.1:7687")

    expect(code).not_to eq(0), out
    expect(out).to include("1 spec(s) SKIPPED without an excusable [needs:...] tag")
    expect(out).to include("live neo4j not configured [needs:neo4j]")
  end

  # ── An always-provisioned service is never excused ──────────────────────────
  # Shared case name: an_always_provisioned_service_is_never_excused.
  it "an_always_provisioned_service_is_never_excused" do
    out, code = run_gate(TINA4_GATE_SPEC_ALWAYS_SERVICE, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("[needs:mongo] MongoDB not reachable on localhost:27017")
  end

  # ── Gate off: the old behaviour, skips stay skips ───────────────────────────
  it "stays green for every kind of skip when the gate is not armed" do
    out, code = run_gate([TINA4_GATE_SPEC_BEFORE_ALL, TINA4_GATE_SPEC_UNMATCHED_WORDINGS,
                          TINA4_GATE_SPEC_ALWAYS_SERVICE, TINA4_GATE_SPEC_OPTIONAL_ENGINE],
                         "TINA4_TEST_NEO4J_URL" => "neo4j://127.0.0.1:7687")

    expect(code).to eq(0), out
    expect(out).not_to include("TINA4_REQUIRE_SERVICES is set")
  end

  # ── The rule itself (pure functions over an explicit env, no dependency) ────
  describe "#tina4_gate_violation?" do
    it "fails any reason without a [needs:...] tag" do
      expect(tina4_gate_violation?("Kafka not reachable on localhost:9092", {})).to be(true)
      expect(tina4_gate_violation?("no reachable mysql at 127.0.0.1:3306", {})).to be(true)
      expect(tina4_gate_violation?("mongo backend unavailable", {})).to be(true)
      expect(tina4_gate_violation?("needs: blackhole-route", {})).to be(true)
      expect(tina4_gate_violation?("[needs:]", {})).to be(true)
      expect(tina4_gate_violation?("", {})).to be(true)
    end

    it "excuses an optional engine only while every coordinate env var is unset" do
      expect(tina4_gate_violation?("[needs:firebird] x", {})).to be(false)
      expect(tina4_gate_violation?("[needs:firebird] x", { "TINA4_TEST_FIREBIRD_URL" => "firebird://h/db" })).to be(true)
      expect(tina4_gate_violation?("[needs:postgres] x", { "TINA4_TEST_PG_URL" => "postgres://h/db" })).to be(true)
      expect(tina4_gate_violation?("[needs:oidc] x", { "TINA4_TEST_OIDC_ISSUER" => " " })).to be(false)
      expect(tina4_gate_violation?("[needs:ultipa] x", { "TINA4_TEST_ULTIPA_URL" => "ultipa://h" })).to be(true)
      expect(tina4_gate_violation?("[needs:postgis] x", {})).to be(false)
      expect(tina4_gate_violation?("[needs:postgis] x", { "TINA4_TEST_POSTGIS_URL" => "postgres://h/gis" })).to be(true)
    end

    it "never excuses an always-provisioned service" do
      %w[mongo redis valkey memcached rabbitmq kafka mqtt smtp imap s3].each do |service|
        expect(tina4_gate_violation?("[needs:#{service}] down", {})).to be(true), service
      end
    end

    it "always excuses a platform exclusion, and needs every tag to be excusable" do
      expect(tina4_gate_violation?("[needs:blackhole-route] no route", {})).to be(false)
      expect(tina4_gate_violation?("x [needs:absent-ext=pgsql]: y", {})).to be(false)
      expect(tina4_gate_violation?("[needs:os=posix] [needs:firebird] x", {})).to be(false)
      expect(tina4_gate_violation?("[needs:os=posix] [needs:redis] x", {})).to be(true)
      expect(tina4_gate_violation?(nil, {})).to be(false)
    end
  end
end
