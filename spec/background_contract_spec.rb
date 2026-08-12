# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Shared contract suite for feature 47 — background tasks.
#
# Fixture: tina4-documentation/plan/v3/fixtures/backgroundtasks_contract.json
# Decisions: BG-DEC-01 (run under the production runtime, not just the dev loop)
# + BG-DEC-02 (ONE surface: a stop-handle + a count).
#
# NO MOCKS. Every case exercises the REAL runtime with a REAL side effect: a real
# dedicated OS thread (the Ruby background runtime) writing a REAL file / bumping
# a REAL counter under a real Mutex, and the real handle's `stop`. Ruby starts the
# thread at registration time regardless of which web server is in front, so a
# task is never a silent no-op — the thread IS the production runtime.
RSpec.describe "Background tasks contract (feature 47)" do
  before { Tina4::Background.stop_all }
  after  { Tina4::Background.stop_all }

  # Wait until `block` is truthy or the deadline passes (a slow CI box must not loop forever).
  def wait_until(seconds: 2.0)
    deadline = Time.now + seconds
    sleep 0.01 while !yield && Time.now < deadline
  end

  describe "runs under the production runtime" do
    it "a scheduled task runs under the production runtime" do
      Dir.mktmpdir("tina4_bgtask_") do |dir|
        counter = File.join(dir, "ticks.txt")
        mutex = Mutex.new

        task = Tina4.background(interval: 0.05) do
          mutex.synchronize { File.write(counter, "x", mode: "a") }
        end

        wait_until(seconds: 3.0) { File.exist?(counter) && File.size(counter) >= 2 }
        task.stop

        ticks = File.exist?(counter) ? File.size(counter) : 0
        expect(ticks).to be >= 2,
                         "the background task never ran in its real thread (ticks=#{ticks})"
      end
    end

    it "a non persistent runtime is guarded not a silent drop" do
      Dir.mktmpdir("tina4_bgtask_") do |dir|
        counter = File.join(dir, "guard.txt")
        mutex = Mutex.new

        task = Tina4::Background.register(interval: 0.05) do
          mutex.synchronize { File.write(counter, "x", mode: "a") }
        end

        # Ruby starts the thread eagerly at register time, so the runtime is
        # live immediately — this is precisely why Ruby has no silent-no-op bug.
        expect(task.running?).to be(true)
        expect(task[:thread]).to be_a(Thread)
        expect(task[:thread].alive?).to be(true)

        wait_until(seconds: 3.0) { File.exist?(counter) && File.size(counter) >= 1 }
        task.stop

        expect(File.exist?(counter) ? File.size(counter) : 0).to be >= 1,
                                                                 "the real thread never ticked — a silent no-op"
      end
    end
  end

  describe "count surface" do
    it "count reflects pending and running tasks" do
      expect(Tina4::Background.count).to eq(0)
      first = Tina4.background(interval: 5.0) { :noop }
      expect(Tina4::Background.count).to eq(1)
      second = Tina4.background(interval: 5.0) { :noop }
      expect(Tina4::Background.count).to eq(2)
      first.stop
      second.stop
    end

    it "count returns to zero when a task is stopped" do
      handle = Tina4.background(interval: 5.0) { :noop }
      expect(Tina4::Background.count).to eq(1)
      handle.stop
      expect(Tina4::Background.count).to eq(0)
    end
  end

  describe "stop handle" do
    it "the stop handle cancels a running task" do
      mutex = Mutex.new
      runs = 0
      handle = Tina4.background(interval: 0.05) { mutex.synchronize { runs += 1 } }

      wait_until(seconds: 3.0) { mutex.synchronize { runs } >= 2 }
      ran_before_stop = mutex.synchronize { runs }
      expect(ran_before_stop).to be >= 2

      expect(handle.stop).to be(true) # cancelled a live, running task
      expect(Tina4::Background.count).to eq(0)

      sleep 0.2
      # stop joins the thread, so no run may land after stop returns.
      expect(mutex.synchronize { runs }).to eq(ran_before_stop),
                                            "stop must cancel the running task, not let it keep ticking"
    end

    it "a second stop is a safe no op" do
      handle = Tina4.background(interval: 5.0) { :noop }
      expect(handle.stop).to be(true)
      expect(handle.stop).to be(false)
      expect(handle.stop).to be(false)
      expect(Tina4::Background.count).to eq(0)
    end
  end
end
