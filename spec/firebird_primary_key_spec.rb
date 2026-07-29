# frozen_string_literal: true

# Firebird primary-key introspection (regression).
#
# columns(table) hardcoded `primary_key: false` for every column -- it never
# queried the constraint catalogue at all. So primary_key(table) always answered
# [] on Firebird, which silently breaks everything that introspects the key,
# most seriously the 3.13.94 filterless-write guard that lifts the PK out of the
# data hash when no filter is given.
#
# Found by running the Python master against a live Firebird 5.0.4 and then
# checking the other three: Python and Node carried the identical hardcoded
# false; PHP already computed it from its pkFields and was never affected.
#
# Needs a real Firebird, so it is gated -- there is no honest way to prove a
# catalogue query works without the catalogue.

require "spec_helper"

RSpec.describe "Firebird primary-key introspection", :firebird do
  before(:all) do
    @url = ENV["TINA4_TEST_FIREBIRD_URL"]
    skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)" if @url.nil? || @url.empty?
  end

  let(:db) { Tina4::Database.new(@url, username: "SYSDBA", password: "masterkey") }

  around do |example|
    begin
      db.execute("DROP TABLE pk_probe")
    rescue StandardError
      nil # first run has nothing to drop
    end
    db.execute(
      "CREATE TABLE pk_probe (" \
      "  id INTEGER NOT NULL, " \
      "  code VARCHAR(10) NOT NULL, " \
      "  label VARCHAR(50), " \
      "  PRIMARY KEY (id, code)" \
      ")"
    )
    example.run
  ensure
    begin
      db.execute("DROP TABLE pk_probe")
    rescue StandardError
      nil
    end
  end

  it "flags EVERY column of a composite primary key" do
    flagged = db.columns("pk_probe").select { |c| c[:primary_key] }
                .map { |c| c[:name].to_s.strip.upcase }
    # A composite key reporting only its first column builds a WHERE that matches
    # too many rows -- the same shape as the SQLite pk-position bug.
    expect(flagged.sort).to eq(%w[CODE ID])
  end

  it "does NOT flag a non-key column" do
    label = db.columns("pk_probe").find { |c| c[:name].to_s.strip.upcase == "LABEL" }
    expect(label[:primary_key]).to be false
  end

  it "surfaces the composite key through the public primary_key helper" do
    expect(db.primary_key("pk_probe").map { |c| c.to_s.upcase }.sort).to eq(%w[CODE ID])
  end
end
