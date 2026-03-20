# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Shutdown do
  before do
    # Reset state before each test
    Tina4::Shutdown.instance_variable_set(:@shutting_down, false)
    Tina4::Shutdown.instance_variable_set(:@in_flight_count, 0)
  end

  describe ".setup" do
    it "initializes without error" do
      expect { Tina4::Shutdown.setup }.not_to raise_error
    end

    it "starts in non-shutting-down state" do
      Tina4::Shutdown.setup
      expect(Tina4::Shutdown.shutting_down?).to be false
    end
  end

  describe ".track_request" do
    before { Tina4::Shutdown.setup }

    it "tracks in-flight requests" do
      Tina4::Shutdown.track_request do
        expect(Tina4::Shutdown.in_flight_count).to eq(1)
      end
      expect(Tina4::Shutdown.in_flight_count).to eq(0)
    end

    it "decrements count even if block raises" do
      begin
        Tina4::Shutdown.track_request { raise "test error" }
      rescue RuntimeError
        # expected
      end
      expect(Tina4::Shutdown.in_flight_count).to eq(0)
    end
  end

  describe ".shutting_down?" do
    it "returns false by default" do
      Tina4::Shutdown.setup
      expect(Tina4::Shutdown.shutting_down?).to be false
    end
  end
end
