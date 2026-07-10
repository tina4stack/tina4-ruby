# frozen_string_literal: true
#
# Real tests for the top-level `queue` CLI command (Phase 3, self-describing
# CLI epic — Ruby mirror of the Python master's `queue` command).
#
# NO mocks. Every example drives the ACTUAL CLI dispatch (Tina4::CLI#run)
# against a REAL Tina4::Queue on the real lite/file backend: jobs are written to
# a real .queue/ directory on disk (isolated per example via a temp cwd), real
# consumer files are loaded and their per-job handlers invoked for real, and the
# assertions read back real on-disk job counts and real side-effect files.
#
#   queue work  — real single-pass drain, real handler + real side effect, real
#                 nack/dead-letter on a raising handler, loud drain with no handler
#   queue stats — real pending / reserved / failed / dead / completed counts
#   queue retry — real dead-letter revived back to pending
#   queue clear — real jobs purged from a status

require "spec_helper"
require "tina4/cli"
require "tina4"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe "tina4ruby queue" do
  let(:cli) { Tina4::CLI.new }

  around(:each) do |example|
    Dir.mktmpdir("tina4_cli_queue") do |dir|
      @tmp = dir
      Dir.chdir(dir) { example.run }
    end
  end

  before(:each) do
    # The ServiceRunner registry is class-level and persists across examples;
    # start each queue-work example from a clean registry so a sibling's
    # consumer registration can never satisfy this example's topic resolution.
    Tina4::ServiceRunner.clear!
  end

  # Run the CLI in-process, capturing stdout and any SystemExit status.
  def run_cli(args)
    out = +""
    status = 0
    orig = $stdout
    $stdout = StringIO.new
    begin
      cli.run(args)
    rescue SystemExit => e
      status = e.status
    ensure
      out = $stdout.string
      $stdout = orig
    end
    [out, status]
  end

  # Push real jobs onto the real lite/file backend rooted at the temp cwd's
  # .queue/ — the SAME backend the CLI's `Tina4::Queue.new(topic:)` resolves,
  # because both run in this example's temp cwd.
  def push(topic, *payloads)
    q = Tina4::Queue.new(topic: topic)
    payloads.each { |p| q.push(p) }
    q
  end

  def write_consumer(filename, contents)
    FileUtils.mkdir_p(File.join(@tmp, "src", "services"))
    File.write(File.join(@tmp, "src", "services", filename), contents)
  end

  # ── work ──────────────────────────────────────────────────────────────

  describe "work" do
    it "drains every available job through a real consumer handler (--once)" do
      write_consumer("orders_ok_consumer.rb", <<~RUBY)
        def handle_orders_ok(payload)
          File.open(File.join(Dir.pwd, "processed.log"), "a") { |f| f.puts(payload["n"]) }
        end
        Tina4.service("orders-ok-consumer", daemon: true, topic: "orders_ok",
                      handle: method(:handle_orders_ok)) { |ctx| }
      RUBY

      q = push("orders_ok", { "n" => 1 }, { "n" => 2 }, { "n" => 3 })
      expect(q.size(status: "pending")).to eq(3)

      out, status = run_cli(["queue", "work", "orders_ok", "--once"])

      expect(status).to eq(0)
      expect(out).to include("single-pass drain")
      expect(out).to include("Processed 3 job(s), 0 failed on 'orders_ok'.")
      # Real side effect: the handler ran for every job.
      log = File.read(File.join(@tmp, "processed.log")).split("\n").sort
      expect(log).to eq(%w[1 2 3])
      # Real drain: nothing left pending.
      expect(q.size(status: "pending")).to eq(0)
    end

    it "nacks a raising handler (real fail -> dead-letter), worker survives" do
      # A handler that always raises. --once drains, and because the lite backend
      # re-enqueues a failed-but-retryable job immediately (retry_backoff 0), the
      # single pass re-attempts until max_retries, then dead-letters it — all real.
      write_consumer("boom_consumer.rb", <<~RUBY)
        def handle_boom(_payload)
          raise "kaboom"
        end
        Tina4.service("boom-consumer", daemon: true, topic: "boom",
                      handle: method(:handle_boom)) { |ctx| }
      RUBY

      q = push("boom", { "id" => "x" })

      out, status = run_cli(["queue", "work", "boom", "--once"])

      expect(status).to eq(0)
      expect(out).to match(/Processed 0 job\(s\), \d+ failed on 'boom'\./)
      # Real terminal state: the job exhausted its retries and dead-lettered.
      expect(q.size(status: "dead")).to eq(1)
      expect(q.size(status: "pending")).to eq(0)
    end

    it "warns loudly and still drains (consume + ack) when no handler targets the topic" do
      q = push("orphan", { "id" => 1 })

      out, status = run_cli(["queue", "work", "orphan", "--once"])

      expect(status).to eq(0)
      expect(out).to include("⚠ No consumer handler found for topic 'orphan'")
      expect(out).to include("Scaffold one with: tina4ruby generate queue orphan")
      expect(out).to include("Processed 1 job(s), 0 failed on 'orphan'.")
      expect(q.size(status: "pending")).to eq(0)
    end

    it "drives a real `generate queue` scaffold: its topic+handle resolve and run" do
      # Task-4 wiring end to end: the scaffold registers topic + per-job handle,
      # so `queue work <topic>` resolves and invokes it. The unfilled stub raises
      # NotImplementedError, which nacks the job (fail-loud) rather than crashing
      # the worker — proving the scaffold is genuinely wired to `queue work`.
      out_gen, _ = run_cli(["generate", "queue", "widgets"])
      expect(out_gen).to include("Created")
      scaffold = File.read(File.join(@tmp, "src", "services", "widgets_consumer.rb"))
      expect(scaffold).to include('topic: "widgets"')
      expect(scaffold).to include("handle: method(:handle_widgets)")

      q = push("widgets", { "id" => 1 })
      out, status = run_cli(["queue", "work", "widgets", "--once"])

      expect(status).to eq(0)
      expect(out).to match(/Processed 0 job\(s\), \d+ failed on 'widgets'\./)
      expect(q.size(status: "dead")).to eq(1) # nacked to death by the unfilled stub
    end
  end

  # ── stats ─────────────────────────────────────────────────────────────

  describe "stats" do
    it "reports real pending counts as JSON (--json)" do
      require "json"
      push("metrics", { "a" => 1 }, { "a" => 2 })

      out, status = run_cli(["queue", "stats", "metrics", "--json"])
      expect(status).to eq(0)

      stats = JSON.parse(out)
      expect(stats["topic"]).to eq("metrics")
      expect(stats["pending"]).to eq(2)
      expect(stats["reserved"]).to eq(0)
      expect(stats["failed"]).to eq(0)
      expect(stats["dead"]).to eq(0)
      # Terminal-completed is 0 on the lite/file backend (parity with Python) —
      # NEVER the pending count (the old Queue#size else-branch footgun).
      expect(stats["completed"]).to eq(0)
    end

    it "prints a human table with the real counts" do
      push("humans", { "a" => 1 })
      out, status = run_cli(["queue", "stats", "humans"])
      expect(status).to eq(0)
      expect(out).to include("Queue 'humans'")
      expect(out).to match(/pending\s+1/)
      expect(out).to match(/completed\s+0/)
    end
  end

  # ── retry ─────────────────────────────────────────────────────────────

  describe "retry" do
    it "revives a real dead-letter job back to pending" do
      # Build a genuine dead-letter: fail one job past max_retries on the real
      # backend, then let `queue retry` revive it.
      q = Tina4::Queue.new(topic: "revive")
      q.push({ "id" => "d1" })
      3.times { q.pop&.fail("boom") } # attempts 1..3 -> dead-letter
      expect(q.size(status: "dead")).to eq(1)
      expect(q.size(status: "pending")).to eq(0)

      out, status = run_cli(["queue", "retry", "revive"])
      expect(status).to eq(0)
      expect(out).to match(/Re-queued 1 job\(s\) on 'revive' \(1 dead-letter, \d+ failed\)\./)

      expect(q.size(status: "dead")).to eq(0)
      expect(q.size(status: "pending")).to eq(1)
    end

    it "reports 0 when there is nothing to retry" do
      out, status = run_cli(["queue", "retry", "empty"])
      expect(status).to eq(0)
      expect(out).to include("Re-queued 0 job(s) on 'empty'")
    end
  end

  # ── clear ─────────────────────────────────────────────────────────────

  describe "clear" do
    it "purges real pending jobs for a status + topic" do
      q = push("purge_me", { "a" => 1 }, { "a" => 2 })
      expect(q.size(status: "pending")).to eq(2)

      out, status = run_cli(["queue", "clear", "pending", "purge_me"])
      expect(status).to eq(0)
      expect(out).to include("Cleared 2 'pending' job(s) from 'purge_me'.")
      expect(q.size(status: "pending")).to eq(0)
    end

    it "defaults to status=completed, topic=default, leaving pending intact" do
      # `queue clear` with NO positional args -> status "completed", topic
      # "default" (a lone positional would be the STATUS, not the topic).
      q = push("default", { "a" => 1 }) # pending on the default topic
      out, status = run_cli(["queue", "clear"])
      expect(status).to eq(0)
      expect(out).to include("Cleared 0 'completed' job(s) from 'default'.")
      # The pending job is untouched — clear targeted completed, not pending.
      expect(q.size(status: "pending")).to eq(1)
    end
  end

  # ── dispatch guards ─────────────────────────────────────────────────────

  describe "dispatch" do
    it "prints usage and exits 1 with no subcommand" do
      out, status = run_cli(["queue"])
      expect(status).to eq(1)
      expect(out).to include("Usage: tina4ruby queue <work|stats|retry|clear>")
      expect(out).to include("Subcommands: work, stats, retry, clear")
    end

    it "rejects an unknown subcommand with exit 1" do
      out, status = run_cli(["queue", "bogus"])
      expect(status).to eq(1)
      expect(out).to include("Unknown queue subcommand: bogus")
      expect(out).to include("Available: work, stats, retry, clear")
    end
  end
end
