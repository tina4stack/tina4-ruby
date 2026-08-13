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
# row[:x] broke on Firebird alone. The driver now folds an all-uppercase name
# back to lowercase and leaves anything else alone.
#
# BOTH halves are asserted on purpose. A blanket downcase passes the first
# example and fails the second; a fix that only stopped folding passes the
# second and fails the first.
#
# Row keys are also asserted as SYMBOLS, not strings -- parity with the
# sqlite/postgres/mssql drivers (db.fetch(...).first[:name], never ["name"]).
# A quoted ALL-CAPS alias is the one spelling that cannot round-trip: it is
# genuinely indistinguishable from an unquoted, folded one, so it is folded
# (and lowercased) too -- that is Firebird's ambiguity, not a bug here.
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
    expect(row.keys).to eq([:x])
    expect(row[:x]).to eq(1)
  end

  it "leaves a quoted mixed-case alias exactly as written" do
    row = db.fetch_one(%q{SELECT 1 AS "MyCol" FROM rdb$database})
    expect(row.keys).to eq([:MyCol])
    expect(row[:MyCol]).to eq(1)
  end

  # ---- Key TYPE regression (owner-flagged 2026-08-12, ex feature-28) -------
  #
  # stringify_keys used to build STRING-keyed rows on Firebird alone -- every
  # other Ruby driver (sqlite/postgres/mssql) hands back SYMBOL keys, so
  # `db.fetch(...).first[:name]` was nil on Firebird only. Fixed by renaming
  # the method to symbolize_keys and adding `.to_sym`; column_name's casing
  # fold-back is unchanged.

  it "a plain lowercase table column comes back as a Symbol key" do
    db.execute("DROP TABLE fbcc_symbol_probe") rescue nil
    db.execute("CREATE TABLE fbcc_symbol_probe (name VARCHAR(20))")
    db.insert("fbcc_symbol_probe", { "name" => "alpha" })
    row = db.fetch_one("SELECT name FROM fbcc_symbol_probe")
    expect(row.keys).to eq([:name])
    expect(row[:name]).to eq("alpha")
    expect(row["name"]).to be_nil # the old (wrong) String-keyed contract
  ensure
    db.execute("DROP TABLE fbcc_symbol_probe") rescue nil
  end

  it "a quoted ALL-CAPS alias cannot round-trip -- it folds (and lowercases) like an unquoted one, now as a Symbol" do
    row = db.fetch_one(%q{SELECT 1 AS "ABC" FROM rdb$database})
    expect(row.keys).to eq([:abc])
    expect(row[:abc]).to eq(1)
  end

  # tables() reads RDB$RELATIONS through the SAME symbolize_keys path
  # (internal r[:"rdb$relation_name"] access) -- proves that internal
  # consumer of the key-type fix independently of columns()/last_insert_id
  # (already covered by firebird_primary_key_spec.rb / firebirdprovider_contract_spec.rb).
  it "db.tables sees a freshly created table (tables() internal key-type fix)" do
    db.execute("DROP TABLE fbcc_tables_probe") rescue nil
    db.execute("CREATE TABLE fbcc_tables_probe (id INTEGER)")
    expect(db.tables).to include("FBCC_TABLES_PROBE")
  ensure
    db.execute("DROP TABLE fbcc_tables_probe") rescue nil
  end
end
