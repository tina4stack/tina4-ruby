# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Background do
  before do
    # Ensure a clean registry between tests.
    Tina4::Background.stop_all
  end

  after do
    Tina4::Background.stop_all
  end

  describe ".register" do
    it "raises when no callback or block is given" do
      expect { described_class.register }.to raise_error(ArgumentError)
    end

    it "raises when the callback does not respond to :call" do
      expect { described_class.register("not callable") }.to raise_error(ArgumentError)
    end

    it "registers and runs the callback at the given interval" do
      count = 0
      mutex = Mutex.new

      task = described_class.register(interval: 0.05) { mutex.synchronize { count += 1 } }

      # Wait long enough for at least two ticks; cap so a slow CI box doesn't loop forever.
      deadline = Time.now + 2.0
      sleep 0.02 while mutex.synchronize { count < 2 } && Time.now < deadline

      described_class.stop_task(task)

      expect(count).to be >= 2
      expect(task[:running]).to be false
    end

    it "accepts a callable object instead of a block" do
      count = 0
      callable = -> { count += 1 }

      task = described_class.register(callable, interval: 0.05)

      deadline = Time.now + 2.0
      sleep 0.02 while count < 1 && Time.now < deadline

      described_class.stop_task(task)
      expect(count).to be >= 1
    end
  end

  describe "error handling" do
    it "keeps firing on subsequent intervals when the callback raises" do
      ticks = 0
      mutex = Mutex.new

      task = described_class.register(interval: 0.05) do
        mutex.synchronize { ticks += 1 }
        raise "boom"
      end

      deadline = Time.now + 2.0
      sleep 0.02 while mutex.synchronize { ticks < 2 } && Time.now < deadline

      described_class.stop_task(task)

      # Two ticks despite the first raising means the rescue worked.
      expect(ticks).to be >= 2
      expect(task[:thread]).to be_nil
    end
  end

  # ── The no-overlap invariant (regression lock-in) ────────────────────────
  #
  # Mirrors tina4-python/tests/test_background_tasks.py,
  # tina4-php/tests/BackgroundOverlapTest.php and
  # tina4-nodejs/test/backgroundOverlap.test.ts — the Ruby half of
  # tina4-python#94.
  #
  # The bug elsewhere (#94): `background(fn, interval=N)` ran a callback
  # CONCURRENTLY WITH ITSELF whenever a run outlasted its interval. Python
  # abandoned an un-cancellable ThreadPoolExecutor future and the next tick
  # started a SECOND copy alongside it; Node's `setInterval` never awaited an
  # async callback. In a real app that double-sent customer emails from an
  # outbox drainer, in ONE process.
  #
  # Ruby gives each task its own thread running `sleep interval; callback.call`
  # in sequence (Background.start_task), so control cannot reach the next sleep
  # until the callback returns — it should already pass. These specs prove that
  # empirically instead of by reading the code, and protect the invariant
  # against a future refactor (e.g. someone wrapping the call in a Thread.new).
  #
  # TIMING CONSTANTS IN THE RUBY PATH (checked before choosing the numbers):
  #   - There is NO floor, NO clamp and NO timeout on the interval. The loop is
  #     a bare `sleep task[:interval]` then `task[:callback].call`, so the raw
  #     interval is the ONLY threshold a slow callback has to cross. Python's
  #     `max(interval * 2, 5.0)` 5-SECOND FLOOR (core/server.py:66) has NO Ruby
  #     equivalent — a callback need not exceed 5s to cross the threshold here.
  #   - The one timing constant in the path is the JOIN timeout on
  #     `stop_task(task, timeout: 2.0)` / `stop_all(timeout: 2.0)`
  #     (background.rb:39,46), which `thread.kill`s a task that has not finished
  #     within 2.0s. SLOW_WORK_SECONDS is deliberately kept UNDER that: a
  #     callback killed mid-flight would never decrement the probe and would
  #     silently corrupt the measurement.
  #   A 0.6s callback against a 0.05s interval is 12x the interval (the same
  #   ratio the PHP suite uses), crosses the only threshold Ruby has, and stays
  #   clear of the 2.0s join timeout.
  #
  # NO MOCKS: real threads, real wall-clock sleeps, a real callback. Concurrency
  # is the genuinely measured quantity — the callback counts itself in and out
  # under a real Mutex and records the PEAK simultaneous occupancy.
  describe "no overlap" do
    # Slow-callback duration: 12x the interval, past Ruby's only threshold (the
    # raw interval), and under the 2.0s stop_task join timeout.
    SLOW_WORK_SECONDS = 0.6
    # Interval for the slow specs — the callback deliberately outlasts it.
    SLOW_INTERVAL = 0.05
    # Wall-clock ticking window for the slow specs.
    SLOW_WINDOW_SECONDS = 3.0

    # Run ONE real background task for a real wall-clock window and report what
    # actually happened: {in_flight:, peak:, runs:}.
    def drive(work_seconds:, interval:, window_seconds:)
      state = { in_flight: 0, peak: 0, runs: 0 }
      mutex = Mutex.new

      task = described_class.register(interval: interval) do
        mutex.synchronize do
          state[:in_flight] += 1
          state[:runs] += 1
          state[:peak] = state[:in_flight] if state[:in_flight] > state[:peak]
        end
        sleep work_seconds if work_seconds.positive? # REAL work, real wall clock
        mutex.synchronize { state[:in_flight] -= 1 }
      end

      sleep window_seconds
      described_class.stop_task(task)
      mutex.synchronize { state.dup }
    end

    # THE #94 lock-in: a run longer than its interval must never overlap itself.
    it "never runs a slow task concurrently with itself" do
      probe = drive(work_seconds: SLOW_WORK_SECONDS,
                    interval: SLOW_INTERVAL,
                    window_seconds: SLOW_WINDOW_SECONDS)

      expect(probe[:runs]).to be >= 2,
                              "the task must have ticked more than once; got #{probe[:runs]}"
      expect(probe[:peak]).to eq(1),
                              "background must never run a task concurrently with itself " \
                              "(peak concurrency was #{probe[:peak]} — a run outlasting its " \
                              "interval was not waited for and the next tick started alongside it)"
      # Every run completed: nothing was killed mid-flight, so the peak above is
      # a measurement of the real thing and not an artifact.
      expect(probe[:in_flight]).to eq(0)
    end

    # Runs are serialised, so the count is bounded by wall-clock / run-time.
    # ~3s of ticking with a 0.6s callback completes at most ~5 serialised runs;
    # overlapping execution (a tick every 0.05s) inflates this by an order of
    # magnitude.
    it "defers a slow task rather than piling runs up" do
      probe = drive(work_seconds: SLOW_WORK_SECONDS,
                    interval: SLOW_INTERVAL,
                    window_seconds: SLOW_WINDOW_SECONDS)

      expect(probe[:runs]).to be <= 8,
                              "serialised runs are bounded by wall-clock/run-time; got " \
                              "#{probe[:runs]} (overlap would inflate this)"
    end

    # Control: the no-overlap rule must not stall a well-behaved fast task.
    it "keeps ticking a fast task without overlapping it either" do
      probe = drive(work_seconds: 0.0, interval: 0.05, window_seconds: 0.6)

      expect(probe[:runs]).to be >= 3, "a fast task must keep ticking; got #{probe[:runs]}"
      expect(probe[:peak]).to eq(1), "a fast task must not overlap either"
    end
  end

  describe ".stop_all" do
    it "stops every registered task and clears the registry" do
      described_class.register(interval: 0.05) { :noop }
      described_class.register(interval: 0.05) { :noop }

      expect(described_class.tasks.size).to eq(2)

      described_class.stop_all

      expect(described_class.tasks).to be_empty
    end
  end

  describe "Tina4.background" do
    it "exposes the module-level helper that mirrors Python/PHP" do
      count = 0
      task = Tina4.background(interval: 0.05) { count += 1 }

      deadline = Time.now + 2.0
      sleep 0.02 while count < 1 && Time.now < deadline

      Tina4::Background.stop_task(task)
      expect(count).to be >= 1
    end
  end
end
