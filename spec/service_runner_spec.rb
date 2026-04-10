# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::ServiceRunner do
  after(:each) { described_class.clear! }

  # ── Registration ────────────────────────────────────────────────────

  describe ".register" do
    it "registers a service with a block" do
      described_class.register("test_svc") { |ctx| }
      expect(described_class.list.length).to eq(1)
      expect(described_class.list.first[:name]).to eq("test_svc")
    end

    it "registers a service with a callable handler" do
      handler = ->(ctx) { }
      described_class.register("lambda_svc", handler)
      expect(described_class.list.length).to eq(1)
    end

    it "raises ArgumentError when no handler or block given" do
      expect {
        described_class.register("empty")
      }.to raise_error(ArgumentError, /provide a handler/)
    end

    it "converts name to string" do
      described_class.register(:symbol_svc) { |ctx| }
      expect(described_class.list.first[:name]).to eq("symbol_svc")
    end

    it "stores options alongside the handler" do
      described_class.register("timed", nil, { timing: "*/5 * * * *" }) { |ctx| }
      entry = described_class.list.first
      expect(entry[:options][:timing]).to eq("*/5 * * * *")
    end
  end

  # ── Tina4.service DSL ──────────────────────────────────────────────

  describe "Tina4.service DSL" do
    it "registers via the module-level helper" do
      Tina4.service("dsl_svc", interval: 10) { |ctx| }
      expect(described_class.list.first[:name]).to eq("dsl_svc")
      expect(described_class.list.first[:options][:interval]).to eq(10)
    end
  end

  # ── Listing ─────────────────────────────────────────────────────────

  describe ".list" do
    it "returns an empty array when nothing is registered" do
      expect(described_class.list).to eq([])
    end

    it "includes name, options, running, last_run, error_count" do
      described_class.register("svc_a") { |ctx| }
      entry = described_class.list.first
      expect(entry).to include(:name, :options, :running, :last_run, :error_count)
    end

    it "reports running as false before start" do
      described_class.register("idle") { |ctx| }
      expect(described_class.list.first[:running]).to be false
    end
  end

  # ── Cron matching ──────────────────────────────────────────────────

  describe ".match_cron?" do
    # Use a fixed time for deterministic tests: 2026-03-20 14:30:00 (Friday = wday 5)
    let(:fixed_time) { Time.new(2026, 3, 20, 14, 30, 0) }

    it "matches wildcard * in all fields" do
      expect(described_class.match_cron?("* * * * *", fixed_time)).to be true
    end

    it "matches exact minute" do
      expect(described_class.match_cron?("30 * * * *", fixed_time)).to be true
      expect(described_class.match_cron?("15 * * * *", fixed_time)).to be false
    end

    it "matches exact hour" do
      expect(described_class.match_cron?("* 14 * * *", fixed_time)).to be true
      expect(described_class.match_cron?("* 10 * * *", fixed_time)).to be false
    end

    it "matches exact day of month" do
      expect(described_class.match_cron?("* * 20 * *", fixed_time)).to be true
      expect(described_class.match_cron?("* * 1 * *", fixed_time)).to be false
    end

    it "matches exact month" do
      expect(described_class.match_cron?("* * * 3 *", fixed_time)).to be true
      expect(described_class.match_cron?("* * * 12 *", fixed_time)).to be false
    end

    it "matches exact day of week (Friday = 5)" do
      expect(described_class.match_cron?("* * * * 5", fixed_time)).to be true
      expect(described_class.match_cron?("* * * * 1", fixed_time)).to be false
    end

    it "matches step */N for minute" do
      # 30 % 5 == 0
      expect(described_class.match_cron?("*/5 * * * *", fixed_time)).to be true
      # 30 % 7 != 0
      expect(described_class.match_cron?("*/7 * * * *", fixed_time)).to be false
    end

    it "matches step */N for hour" do
      # 14 % 2 == 0
      expect(described_class.match_cron?("* */2 * * *", fixed_time)).to be true
      # 14 % 3 != 0
      expect(described_class.match_cron?("* */3 * * *", fixed_time)).to be false
    end

    it "matches comma-separated list" do
      expect(described_class.match_cron?("15,30,45 * * * *", fixed_time)).to be true
      expect(described_class.match_cron?("0,15,45 * * * *", fixed_time)).to be false
    end

    it "matches range with dash" do
      expect(described_class.match_cron?("25-35 * * * *", fixed_time)).to be true
      expect(described_class.match_cron?("0-10 * * * *", fixed_time)).to be false
    end

    it "matches complex multi-field pattern" do
      # minute=30, hour=14, day=20, month=3, dow=5
      expect(described_class.match_cron?("30 14 20 3 5", fixed_time)).to be true
      expect(described_class.match_cron?("30 14 20 3 1", fixed_time)).to be false
    end

    it "rejects patterns with wrong number of fields" do
      expect(described_class.match_cron?("* * *", fixed_time)).to be false
      expect(described_class.match_cron?("* * * * * *", fixed_time)).to be false
    end

    it "handles step with zero gracefully" do
      expect(described_class.match_cron?("*/0 * * * *", fixed_time)).to be false
    end

    it "matches minute 0 with */5" do
      midnight = Time.new(2026, 1, 1, 0, 0, 0)
      expect(described_class.match_cron?("*/5 * * * *", midnight)).to be true
    end
  end

  # ── ServiceContext ─────────────────────────────────────────────────

  describe "ServiceContext" do
    it "initializes with running=true and nil last_run" do
      ctx = Tina4::ServiceContext.new("my_svc")
      expect(ctx.running).to be true
      expect(ctx.last_run).to be_nil
      expect(ctx.name).to eq("my_svc")
      expect(ctx.error_count).to eq(0)
    end

    it "allows setting running to false" do
      ctx = Tina4::ServiceContext.new("s")
      ctx.running = false
      expect(ctx.running).to be false
    end

    it "tracks last_run time" do
      ctx = Tina4::ServiceContext.new("s")
      now = Time.now
      ctx.last_run = now
      expect(ctx.last_run).to eq(now)
    end
  end

  # ── Start / Stop lifecycle ─────────────────────────────────────────

  describe ".start and .stop" do
    it "starts a service and reports it as running" do
      described_class.register("looper", nil, { interval: 60 }) { |ctx|
        sleep(0.01) while ctx.running
      }
      described_class.start("looper")
      sleep(0.05) # let thread spin up
      expect(described_class.is_running("looper")).to be true
      described_class.stop("looper")
    end

    it "stops a running service" do
      described_class.register("stopper", nil, { interval: 60 }) { |ctx|
        sleep(0.01) while ctx.running
      }
      described_class.start("stopper")
      sleep(0.05)
      described_class.stop("stopper")
      sleep(0.1)
      expect(described_class.is_running("stopper")).to be false
    end

    it "raises KeyError when starting an unregistered service" do
      expect {
        described_class.start("nope")
      }.to raise_error(KeyError, /nope/)
    end

    it "stop is safe to call when nothing is running" do
      expect { described_class.stop }.not_to raise_error
    end

    it "stop with a specific name is safe when service not running" do
      described_class.register("idle_svc") { |ctx| }
      expect { described_class.stop("idle_svc") }.not_to raise_error
    end
  end

  # ── is_running ───────────────────────────────────────────────────────

  describe ".is_running" do
    it "returns false for unregistered service" do
      expect(described_class.is_running("ghost")).to be false
    end

    it "returns false for registered but not started service" do
      described_class.register("registered_only") { |ctx| }
      expect(described_class.is_running("registered_only")).to be false
    end
  end

  # ── Interval execution ─────────────────────────────────────────────

  describe "interval execution" do
    it "executes handler multiple times at short interval" do
      counter = Concurrent::AtomicFixnum.new(0) rescue nil
      # Fall back to simple counter with mutex if concurrent-ruby not available
      if counter.nil?
        count = 0
        mu = Mutex.new
        described_class.register("fast", nil, { interval: 0.05 }) { |ctx|
          mu.synchronize { count += 1 }
        }
        described_class.start("fast")
        sleep(0.35)
        described_class.stop("fast")
        mu.synchronize { expect(count).to be >= 2 }
      else
        described_class.register("fast", nil, { interval: 0.05 }) { |ctx|
          counter.increment
        }
        described_class.start("fast")
        sleep(0.35)
        described_class.stop("fast")
        expect(counter.value).to be >= 2
      end
    end

    it "sets last_run after execution" do
      described_class.register("stamp", nil, { interval: 0.05 }) { |ctx| }
      described_class.start("stamp")
      sleep(0.15)
      entry = described_class.list.find { |e| e[:name] == "stamp" }
      expect(entry[:last_run]).not_to be_nil
      described_class.stop("stamp")
    end
  end

  # ── Daemon mode ────────────────────────────────────────────────────

  describe "daemon mode" do
    it "runs handler that manages its own loop" do
      iterations = 0
      mu = Mutex.new

      described_class.register("daemon_svc", nil, { daemon: true }) { |ctx|
        while ctx.running
          mu.synchronize { iterations += 1 }
          sleep(0.02)
        end
      }
      described_class.start("daemon_svc")
      sleep(0.15)
      described_class.stop("daemon_svc")
      mu.synchronize { expect(iterations).to be >= 2 }
    end
  end

  # ── Error handling / retries ───────────────────────────────────────

  describe "error handling" do
    it "increments error_count on failure" do
      call_count = 0
      mu = Mutex.new

      described_class.register("crasher", nil, { interval: 0.05, max_retries: 5 }) { |ctx|
        mu.synchronize { call_count += 1 }
        raise "boom" if call_count <= 2
      }
      described_class.start("crasher")
      sleep(0.5)
      entry = described_class.list.find { |e| e[:name] == "crasher" }
      expect(entry[:error_count]).to be >= 2
      described_class.stop("crasher")
    end

    it "stops after max_retries exceeded" do
      described_class.register("doomed", nil, { interval: 0.02, max_retries: 2 }) { |ctx|
        raise "always fails"
      }
      described_class.start("doomed")
      sleep(0.3)
      expect(described_class.is_running("doomed")).to be false
    end
  end

  # ── clear! ─────────────────────────────────────────────────────────

  describe ".clear!" do
    it "removes all registrations and stops services" do
      described_class.register("a") { |ctx| }
      described_class.register("b") { |ctx| }
      described_class.clear!
      expect(described_class.list).to eq([])
    end
  end

  # ── Discovery ──────────────────────────────────────────────────────

  describe ".discover" do
    it "loads service files from a directory" do
      dir = Dir.mktmpdir("tina4_services")
      File.write(File.join(dir, "heartbeat.rb"), <<~RUBY)
        Tina4::ServiceRunner.register("heartbeat", nil, { interval: 60 }) { |ctx| }
      RUBY

      described_class.discover(dir)
      expect(described_class.list.any? { |s| s[:name] == "heartbeat" }).to be true
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    it "handles missing directory gracefully" do
      expect { described_class.discover("/nonexistent/path") }.not_to raise_error
    end
  end
end
