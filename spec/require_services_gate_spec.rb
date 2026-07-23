# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

# Contract tests for the TINA4_REQUIRE_SERVICES gate in spec/spec_helper.rb.
#
# The gate exists to guarantee NO GREEN SKIPS in CI: when the workflow has
# provisioned PostgreSQL/MySQL/MSSQL/Redis/Valkey/Memcached/Mongo/RabbitMQ/Kafka/
# Mosquitto and set TINA4_REQUIRE_SERVICES=1, a spec that skips because one of
# those services (or its client gem) is missing must FAIL the run instead of
# passing quietly. It shipped with a hole: the violation was recorded from an
# after(:each) hook, and RSpec does NOT run after(:each) for an example skipped
# by a `before(:context)` / `before(:all)` hook — so `before(:all) { skip "Kafka
# not reachable" }` skipped GREEN and exited 0 even with the gate armed. The gate
# now walks RSpec.world at suite end instead, which sees both shapes.
#
# NO MOCKS: each example writes a real spec file and runs the REAL rspec binary
# against the REAL spec_helper in a subprocess, then asserts on the real exit
# status and real output. Nothing about the gate is simulated.
#
# The fixtures live at file scope, not inside the describe block: a constant
# assigned inside a block still lands on Object, so a bare REPO_ROOT here would
# become a global shared with every other spec in the suite.
TINA4_GATE_SPEC_REPO_ROOT = File.expand_path("..", __dir__)

# A skip declared in before(:all): the shape that used to slip through.
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

# A skip declared per example: the shape the original after(:each) gate caught.
TINA4_GATE_SPEC_PER_EXAMPLE = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (per-example skip)" do
      before { skip "Redis not reachable on localhost:6379" }

      it "is skipped by the per-example hook" do
        expect(true).to be(true)
      end
    end
  RUBY

# Firebird is NOT provisioned in CI, so its skip reason must stay green: it
# matches no gate keyword. Guards against the gate over-reaching into a hard
# failure for services the workflow never starts.
TINA4_GATE_SPEC_UNPROVISIONED = <<~RUBY
    require "spec_helper"

    RSpec.describe "gate fixture (unprovisioned service)" do
      before(:all) { skip "Firebird not reachable on localhost:3050" }

      it "is skipped for an unprovisioned service" do
        expect(true).to be(true)
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

      full_env = { "TINA4_REQUIRE_SERVICES" => nil, "TINA4_TEST_KAFKA_URL" => nil }.merge(env)
      cmd = ["bundle", "exec", "rspec", "-I", "spec", "--no-color", "--seed", "0", *paths]
      out, status = Open3.capture2e(full_env, *cmd, chdir: TINA4_GATE_SPEC_REPO_ROOT)
      [out, status.exitstatus]
    end
  end

  # ── The hole this spec exists for ───────────────────────────────────────────
  it "fails the run when a provisioned service is skipped from before(:all)" do
    out, code = run_gate(TINA4_GATE_SPEC_BEFORE_ALL, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0),
                        "a before(:all) skip of a provisioned service exited #{code} (green skip):\n#{out}"
    expect(out).to include("TINA4_REQUIRE_SERVICES is set, but")
    expect(out).to include("Kafka not reachable on localhost:9092")
  end

  it "records EVERY example skipped by the same before(:all) hook" do
    out, code = run_gate(TINA4_GATE_SPEC_BEFORE_ALL, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("2 real-service spec(s) SKIPPED")
    expect(out).to include("is skipped by the context hook")
    expect(out).to include("is skipped by the context hook too")
  end

  # ── The path that already worked, locked in against regression ──────────────
  it "fails the run when a provisioned service is skipped per example" do
    out, code = run_gate(TINA4_GATE_SPEC_PER_EXAMPLE, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("Redis not reachable on localhost:6379")
  end

  it "reports before(:all) and per-example violations together" do
    out, code = run_gate([TINA4_GATE_SPEC_BEFORE_ALL, TINA4_GATE_SPEC_PER_EXAMPLE],
                         "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).not_to eq(0), out
    expect(out).to include("3 real-service spec(s) SKIPPED")
    expect(out).to include("Kafka not reachable")
    expect(out).to include("Redis not reachable")
  end

  # ── Negative cases: the gate must not fire ──────────────────────────────────
  it "stays green for a before(:all) service skip when the gate is not armed" do
    out, code = run_gate(TINA4_GATE_SPEC_BEFORE_ALL, {})

    expect(code).to eq(0), out
    expect(out).not_to include("TINA4_REQUIRE_SERVICES is set")
  end

  it "stays green for a service CI does not provision, even with the gate armed" do
    out, code = run_gate(TINA4_GATE_SPEC_UNPROVISIONED, "TINA4_REQUIRE_SERVICES" => "1")

    expect(code).to eq(0), out
    expect(out).not_to include("TINA4_REQUIRE_SERVICES is set")
  end

  # ── The keyword matcher itself (pure predicate, no dependency) ──────────────
  describe "#tina4_provisioned_service_skip?" do
    it "matches a provisioned service plus an unavailable hint" do
      expect(tina4_provisioned_service_skip?("Kafka not reachable on localhost:9092")).to be(true)
      expect(tina4_provisioned_service_skip?("rdkafka gem not installed")).to be(true)
      expect(tina4_provisioned_service_skip?("TINA4_TEST_KAFKA_URL not set")).to be(true)
      expect(tina4_provisioned_service_skip?("MQTT broker not reachable")).to be(true)
    end

    it "does not match an unprovisioned service or a plain skip" do
      expect(tina4_provisioned_service_skip?("Firebird not reachable on localhost:3050")).to be(false)
      expect(tina4_provisioned_service_skip?("Kafka test is slow, run it manually")).to be(false)
      expect(tina4_provisioned_service_skip?(nil)).to be(false)
    end
  end
end
