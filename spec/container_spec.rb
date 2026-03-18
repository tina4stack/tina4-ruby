# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Container do
  after(:each) { described_class.clear! }

  describe ".register and .resolve" do
    it "registers and resolves a concrete instance" do
      obj = { name: "test service" }
      described_class.register(:svc, obj)
      expect(described_class.resolve(:svc)).to equal(obj)
    end

    it "registers and resolves a lazy factory" do
      call_count = 0
      described_class.register(:lazy) { call_count += 1; "created" }
      expect(described_class.resolve(:lazy)).to eq("created")
      expect(call_count).to eq(1)
    end

    it "memoizes the factory result" do
      call_count = 0
      described_class.register(:memo) { call_count += 1; Object.new }

      first = described_class.resolve(:memo)
      second = described_class.resolve(:memo)

      expect(first).to equal(second)
      expect(call_count).to eq(1)
    end

    it "raises KeyError for unregistered services" do
      expect { described_class.resolve(:missing) }.to raise_error(KeyError, /missing/)
    end

    it "raises ArgumentError when given both instance and block" do
      expect {
        described_class.register(:bad, "value") { "also value" }
      }.to raise_error(ArgumentError, /not both/)
    end

    it "raises ArgumentError when given neither instance nor block" do
      expect {
        described_class.register(:empty)
      }.to raise_error(ArgumentError, /provide/)
    end

    it "allows overriding a registration" do
      described_class.register(:svc, "original")
      described_class.register(:svc, "replaced")
      expect(described_class.resolve(:svc)).to eq("replaced")
    end

    it "accepts string names and normalizes to symbols" do
      described_class.register("my_service", "value")
      expect(described_class.resolve(:my_service)).to eq("value")
      expect(described_class.resolve("my_service")).to eq("value")
    end
  end

  describe ".registered?" do
    it "returns true for registered services" do
      described_class.register(:present, "here")
      expect(described_class.registered?(:present)).to be true
    end

    it "returns false for unregistered services" do
      expect(described_class.registered?(:absent)).to be false
    end
  end

  describe ".clear!" do
    it "removes all registrations" do
      described_class.register(:a, 1)
      described_class.register(:b, 2)
      described_class.clear!
      expect(described_class.registered?(:a)).to be false
      expect(described_class.registered?(:b)).to be false
    end
  end

  describe "Tina4 DSL shortcuts" do
    it "delegates register and resolve to Container" do
      Tina4.register(:greeter, "hello")
      expect(Tina4.resolve(:greeter)).to eq("hello")
    end

    it "works with lazy factories via DSL" do
      Tina4.register(:counter) { rand(1000) }
      first = Tina4.resolve(:counter)
      second = Tina4.resolve(:counter)
      expect(first).to eq(second)
    end
  end

  describe "test isolation pattern" do
    it "allows swapping services for test doubles" do
      real_service = "production mailer"
      fake_service = "test mailer"

      Tina4.register(:mailer, real_service)
      expect(Tina4.resolve(:mailer)).to eq("production mailer")

      # Swap for testing
      Tina4.register(:mailer, fake_service)
      expect(Tina4.resolve(:mailer)).to eq("test mailer")
    end
  end
end
