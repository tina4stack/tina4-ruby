# frozen_string_literal: true

require_relative "../lib/tina4/events"

RSpec.describe Tina4::Events do
  before(:each) { described_class.clear }

  # ── on / emit ──────────────────────────────────────

  describe ".on and .emit" do
    it "registers and fires a listener" do
      called = false
      described_class.on("test.event") { called = true }
      described_class.emit("test.event")
      expect(called).to be true
    end

    it "passes arguments to listener" do
      received = nil
      described_class.on("user.created") { |user| received = user }
      described_class.emit("user.created", { name: "Alice" })
      expect(received).to eq({ name: "Alice" })
    end

    it "passes multiple arguments" do
      a = nil
      b = nil
      described_class.on("multi") { |x, y| a = x; b = y }
      described_class.emit("multi", "hello", 42)
      expect(a).to eq("hello")
      expect(b).to eq(42)
    end

    it "returns results from all listeners" do
      described_class.on("calc") { |x| x * 2 }
      described_class.on("calc") { |x| x * 3 }
      results = described_class.emit("calc", 5)
      expect(results).to eq([10, 15])
    end

    it "returns empty array for unknown event" do
      expect(described_class.emit("nonexistent")).to eq([])
    end

    it "fires multiple listeners in registration order (same priority)" do
      order = []
      described_class.on("build") { order << "A" }
      described_class.on("build") { order << "B" }
      described_class.on("build") { order << "C" }
      described_class.emit("build")
      expect(order).to eq(%w[A B C])
    end

    it "requires a block" do
      expect { described_class.on("no_block") }.to raise_error(ArgumentError)
    end
  end

  # ── priority ───────────────────────────────────────

  describe "priority" do
    it "higher priority runs first" do
      order = []
      described_class.on("pipeline", priority: 1) { order << "low" }
      described_class.on("pipeline", priority: 10) { order << "high" }
      described_class.on("pipeline", priority: 5) { order << "mid" }
      described_class.emit("pipeline")
      expect(order).to eq(%w[high mid low])
    end

    it "default priority is 0" do
      order = []
      described_class.on("p") { order << "first" }
      described_class.on("p", priority: 1) { order << "second" }
      described_class.emit("p")
      expect(order).to eq(%w[second first])
    end
  end

  # ── once ───────────────────────────────────────────

  describe ".once" do
    it "fires only once then auto-removes" do
      count = 0
      described_class.once("startup") { count += 1 }
      3.times { described_class.emit("startup") }
      expect(count).to eq(1)
    end

    it "works with priority" do
      order = []
      described_class.on("mix", priority: 1) { order << "always" }
      described_class.once("mix", priority: 10) { order << "once" }

      described_class.emit("mix")
      expect(order).to eq(%w[once always])

      order.clear
      described_class.emit("mix")
      expect(order).to eq(%w[always])
    end

    it "returns value on first fire" do
      described_class.once("init") { "ready" }
      results = described_class.emit("init")
      expect(results).to eq(["ready"])
      expect(described_class.emit("init")).to eq([])
    end

    it "requires a block" do
      expect { described_class.once("no_block") }.to raise_error(ArgumentError)
    end
  end

  # ── off ────────────────────────────────────────────

  describe ".off" do
    it "removes a specific listener" do
      fn1 = described_class.on("test") { "A" }
      described_class.on("test") { "B" }
      described_class.off("test", fn1)
      expect(described_class.emit("test")).to eq(["B"])
    end

    it "removes all listeners for an event" do
      described_class.on("clean") { 1 }
      described_class.on("clean") { 2 }
      described_class.off("clean")
      expect(described_class.emit("clean")).to eq([])
    end

    it "handles non-existent event gracefully" do
      expect { described_class.off("ghost") }.not_to raise_error
      expect { described_class.off("ghost", proc {}) }.not_to raise_error
    end
  end

  # ── listeners ──────────────────────────────────────

  describe ".listeners" do
    it "returns callbacks in priority order" do
      fn_low = described_class.on("check", priority: 1) { "low" }
      fn_high = described_class.on("check", priority: 10) { "high" }
      list = described_class.listeners("check")
      expect(list.length).to eq(2)
      expect(list[0]).to eq(fn_high)
      expect(list[1]).to eq(fn_low)
    end

    it "returns empty for unknown event" do
      expect(described_class.listeners("unknown")).to eq([])
    end
  end

  # ── events ─────────────────────────────────────────

  describe ".events" do
    it "returns all registered event names" do
      described_class.on("alpha") { nil }
      described_class.on("beta") { nil }
      described_class.on("gamma") { nil }
      names = described_class.events
      expect(names).to contain_exactly("alpha", "beta", "gamma")
    end

    it "is empty after clear" do
      described_class.on("temp") { nil }
      described_class.clear
      expect(described_class.events).to be_empty
    end
  end

  # ── clear ──────────────────────────────────────────

  describe ".clear" do
    it "removes everything" do
      described_class.on("a") { 1 }
      described_class.on("b") { 2 }
      described_class.once("c") { 3 }
      described_class.clear
      expect(described_class.events).to be_empty
      expect(described_class.emit("a")).to eq([])
      expect(described_class.emit("b")).to eq([])
      expect(described_class.emit("c")).to eq([])
    end
  end

  # ── isolation ──────────────────────────────────────

  describe "event isolation" do
    it "different events are independent" do
      a = 0
      b = 0
      described_class.on("count.a") { a += 1 }
      described_class.on("count.b") { b += 1 }
      2.times { described_class.emit("count.a") }
      described_class.emit("count.b")
      expect(a).to eq(2)
      expect(b).to eq(1)
    end

    it "off one event does not affect others" do
      described_class.on("keep") { "kept" }
      described_class.on("remove") { "gone" }
      described_class.off("remove")
      expect(described_class.emit("keep")).to eq(["kept"])
      expect(described_class.emit("remove")).to eq([])
    end
  end
end
