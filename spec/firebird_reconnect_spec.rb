# frozen_string_literal: true

# Regression tests for Tina4::Drivers::FirebirdDriver dead-connection recovery.
#
# Idle Firebird connections die silently behind NAT timeouts, server-side
# ConnectionIdleTimeout, or Docker network rotation. Without a transparent
# reconnect, the next connection.execute crashes with one of:
#
#     "Error writing data to the connection."
#     "Error reading data from the connection."
#     "connection shutdown"
#     "Connection is not active"
#
# Shipped in 3.11.35: FirebirdDriver caches connection opts and runs a
# one-shot reconnect+retry on the next execute when those markers appear.
# Skipped inside an explicit transaction — atomicity wins there.

require "spec_helper"
require "tina4/drivers/firebird_driver"

RSpec.describe Tina4::Drivers::FirebirdDriver do
  describe ".dead_connection?" do
    [
      "Error writing data to the connection.",
      "Error reading data from the connection.",
      "connection shutdown",
      "Connection lost",
      "network error",
      "Connection is not active",
      "Broken pipe",
      "isc_dsql_prepare: Error writing data to the connection. attached to db"
    ].each do |msg|
      it "matches real-world dead-socket marker: #{msg.inspect}" do
        expect(described_class.dead_connection?(msg)).to be true
      end
    end

    [
      "Dynamic SQL Error: syntax error at line 1, column 17",
      "Table USERS does not exist",
      "violation of FOREIGN KEY constraint",
      "lock conflict on no wait transaction",
      "no permission for SELECT access to TABLE USERS"
    ].each do |msg|
      it "does NOT match logical SQL error: #{msg.inspect}" do
        expect(described_class.dead_connection?(msg)).to be false
      end
    end

    it "is case-insensitive" do
      expect(described_class.dead_connection?("ERROR WRITING DATA TO THE CONNECTION")).to be true
      expect(described_class.dead_connection?("cOnNecTion ShUtDoWn")).to be true
    end

    it "handles nil and empty input" do
      expect(described_class.dead_connection?(nil)).to be false
      expect(described_class.dead_connection?("")).to be false
    end

    it "accepts an Exception object as well as a String" do
      err = StandardError.new("Error writing data to the connection.")
      expect(described_class.dead_connection?(err)).to be true
    end
  end

  describe "#with_reconnect" do
    let(:driver) { described_class.new }

    before do
      # Inject a fake @connect_opts so reconnect! has something to use,
      # and stub open_connection so we don't hit a real Firebird server.
      driver.instance_variable_set(:@connect_opts, { database: "stub" })
      stale_conn = double("conn", close: nil)
      driver.instance_variable_set(:@connection, stale_conn)
      allow(driver).to receive(:open_connection) do
        driver.instance_variable_set(:@connection, double("fresh_conn", close: nil))
      end
    end

    it "retries once after a dead-connection error and returns the retry result" do
      attempt = 0
      result = driver.send(:with_reconnect) do
        attempt += 1
        raise "Error writing data to the connection." if attempt == 1
        :ok
      end
      expect(attempt).to eq(2)
      expect(result).to eq(:ok)
      expect(driver).to have_received(:open_connection).once
    end

    it "does not retry on logical SQL errors" do
      expect {
        driver.send(:with_reconnect) { raise "syntax error at line 1, column 17" }
      }.to raise_error(/syntax error/)
      expect(driver).not_to have_received(:open_connection)
    end

    it "does not retry inside an explicit transaction" do
      driver.instance_variable_set(:@transaction, double("tx"))
      expect {
        driver.send(:with_reconnect) { raise "Error writing data to the connection." }
      }.to raise_error(/Error writing data/)
      expect(driver).not_to have_received(:open_connection)
    end

    it "swallows close errors during reconnect (stale handle already gone)" do
      bad_conn = double("dead_conn")
      allow(bad_conn).to receive(:close).and_raise("connection is not active")
      driver.instance_variable_set(:@connection, bad_conn)

      expect {
        driver.send(:with_reconnect) do
          raise "Error writing data to the connection." if driver.instance_variable_get(:@connection) == bad_conn
          :ok
        end
      }.not_to raise_error
    end
  end
end
