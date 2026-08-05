# frozen_string_literal: true

# Firebird column names fold back only when Firebird folded them.
#
# Firebird's identifier folding is ASYMMETRIC:
#
#     SELECT 1 AS x        ->  stored X       (unquoted folds to UPPER)
#     SELECT 1 AS "MyCol"  ->  stored MyCol   (quoted keeps its case)
#
# Every other engine Tina4 supports gives "x" for the first form -- PostgreSQL
# folds to lower, MySQL/SQLite/MSSQL preserve -- so portable code reading
# row["x"] broke on Firebird alone. The driver now folds an all-uppercase name
# back to lowercase and leaves anything else alone.
#
# BOTH halves are asserted on purpose. A blanket downcase passes the first
# example and fails the second; a fix that only stopped folding passes the
# second and fails the first.
#
# Real Firebird only - no mocks.

require "spec_helper"

RSpec.describe "Firebird column-name case" do
  before(:all) do
    @url = ENV["TINA4_TEST_FIREBIRD_URL"]
  end

  let(:db) { Tina4::Database.new(@url, username: "SYSDBA", password: "masterkey") }

  around(:each) do |example|
    if @url.nil? || @url.empty?
      skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)"
    else
      example.run
    end
  end

  after(:each) { db.close rescue nil }

  it "reads an unquoted alias back lowercase, like every other engine" do
    row = db.fetch_one("SELECT 1 AS x FROM rdb$database")
    expect(row.keys).to eq(["x"])
    expect(row["x"]).to eq(1)
  end

  it "leaves a quoted mixed-case alias exactly as written" do
    row = db.fetch_one(%q{SELECT 1 AS "MyCol" FROM rdb$database})
    expect(row.keys).to eq(["MyCol"])
    expect(row["MyCol"]).to eq(1)
  end
end
