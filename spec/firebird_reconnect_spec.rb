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
# Skipped inside an explicit transaction -- atomicity wins there.
#
# FB-DEC-01 (the no-mock rule): the reconnect/retry examples here used to use
# RSpec doubles (`allow(driver).to receive(:open_connection)`) to fake a Firebird
# server, so the reconnect path was proven only against a mock -- a direct
# violation of the project's absolute no-mock rule. They are now REAL: a genuine
# server-side disconnect (DELETE FROM MON$ATTACHMENTS on the driver's own
# attachment id, from a second connection) drives the reconnect against a live
# Firebird. The shared four-way contract lives in firebirdprovider_contract_spec.

require "spec_helper"
require "tina4/drivers/firebird_driver"

RSpec.describe Tina4::Drivers::FirebirdDriver do
  # ---- Dead-connection matcher (pure logic, no dependency, no double) ----
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

  # ---- Reconnect + retry against a REAL Firebird (no mocks) ----
  describe "#with_reconnect (real Firebird)" do
    before(:all) { @url = ENV["TINA4_TEST_FIREBIRD_URL"] }

    around(:each) do |example|
      if @url.nil? || @url.empty?
        skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)"
      else
        example.run
      end
    end

    def connected_driver
      driver = described_class.new
      driver.connect(@url, username: "SYSDBA", password: "masterkey")
      (@drivers ||= []) << driver
      driver
    end

    after(:each) { (@drivers || []).each { |d| d.close rescue nil } }

    def attachment_id(driver)
      driver.execute_query("SELECT CURRENT_CONNECTION AS c FROM RDB\$DATABASE").first["c"]
    end

    it "retries once after a real dropped connection and the next query succeeds" do
      driver = connected_driver
      cid = attachment_id(driver)
      # Force a genuine server-side disconnect from a SECOND connection.
      connected_driver.execute("DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID = ?", [cid])
      # The next query on the dead attachment transparently reconnects + succeeds.
      rows = driver.execute_query("SELECT 1 AS x FROM RDB\$DATABASE")
      expect(rows.first["x"]).to eq(1)
    end

    it "does not retry inside an explicit transaction" do
      driver = connected_driver
      cid = attachment_id(driver)
      driver.begin_transaction
      connected_driver.execute("DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID = ?", [cid])
      # Inside a transaction, atomicity beats resilience: the dead-connection
      # error surfaces to the caller instead of a silent reconnect+retry.
      expect { driver.execute_query("SELECT 1 AS x FROM RDB\$DATABASE") }.to raise_error(StandardError)
    end
  end
end
