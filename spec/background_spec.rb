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
