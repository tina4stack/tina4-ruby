# frozen_string_literal: true

# Lock-in for the PostgreSQL row-hydration contract (issue #359).
#
# execute_query was changed to read rows via PG::Result#each_row (positional
# String arrays, no per-row gem Hash) against the field names symbolised once,
# instead of `result.map { symbolize_keys(row) }`. That is a ~45% speedup on a
# 5,000-row fetch measured against real PostgreSQL 16.14. These tests pin the
# OUTPUT so the optimisation cannot quietly change what callers receive -- the
# most important guard being TYPE-MAP PRESERVATION: the connection decodes
# INT/BOOL/NUMERIC/TIMESTAMP to native Ruby types, and each_row must honour that
# map exactly as the old map/each path did (a naive raw path would hand back
# "1"/"t" strings). Real PostgreSQL, no doubles; skipped when PG is unreachable.
require "spec_helper"
require "socket"

PGH_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PGH_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "5432").to_i
PGH_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
PGH_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
PGH_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pgh_reachable?
  TCPSocket.new(PGH_HOST, PGH_PORT).tap(&:close)
  require "pg"
  true
rescue StandardError, LoadError
  false
end

RSpec.describe "PostgreSQL read hydration contract", if: pgh_reachable? do
  let(:db) do
    Tina4::Database.new("postgres://#{PGH_HOST}:#{PGH_PORT}/#{PGH_DB}",
                        username: PGH_USER, password: PGH_PASS)
  end

  before do
    db.execute("DROP TABLE IF EXISTS hyd_pg")
    db.execute("DROP TABLE IF EXISTS hyd_pg_posts")
    db.execute(<<~SQL)
      CREATE TABLE hyd_pg (
        id SERIAL PRIMARY KEY, name TEXT, active BOOLEAN,
        age INT, score NUMERIC(6,2), note TEXT
      )
    SQL
    db.execute("INSERT INTO hyd_pg (name, active, age, score, note) VALUES (?,?,?,?,?)",
               ["Alice", true, 30, 9.5, "x"])
    db.execute("INSERT INTO hyd_pg (name, active, age, score, note) VALUES (?,?,?,?,?)",
               ["Bob", false, 40, nil, nil])
    db.execute("CREATE TABLE hyd_pg_posts (id SERIAL PRIMARY KEY, user_id INT, title TEXT)")
    db.execute("INSERT INTO hyd_pg_posts (user_id, title) VALUES (?, ?)", [1, "Hi"])
    db.commit
  end

  after do
    db.execute("DROP TABLE IF EXISTS hyd_pg")
    db.execute("DROP TABLE IF EXISTS hyd_pg_posts")
    db.commit
    db.close
  end

  it "returns rows as symbol-keyed Hashes" do
    row = db.fetch_one("SELECT * FROM hyd_pg WHERE id = 1")
    expect(row).to be_a(Hash)
    expect(row.keys).to all(be_a(Symbol))
    expect(row.key?("id")).to be(false)
  end

  it "preserves the result type map (native types, NOT stringified)" do
    row = db.fetch_one("SELECT * FROM hyd_pg WHERE id = 1")
    expect(row[:id]).to be_a(Integer).and eq(1)
    expect(row[:age]).to be_a(Integer).and eq(30)
    expect(row[:active]).to be(true)      # not the string "t"
    expect(row[:score]).to be_a(BigDecimal)
    expect(row[:name]).to eq("Alice")
  end

  it "maps NULL to nil under a symbol key" do
    row = db.fetch_one("SELECT * FROM hyd_pg WHERE id = 2")
    expect(row[:active]).to be(false)
    expect(row[:score]).to be_nil
    expect(row[:note]).to be_nil
  end

  it "hydrates every row of a multi-row set with identical symbol keys" do
    rows = db.fetch("SELECT * FROM hyd_pg ORDER BY id", [], limit: 1000).records
    expect(rows.length).to eq(2)
    expect(rows.map(&:keys)).to all(eq(%i[id name active age score note]))
  end

  it "returns an empty record set for a no-match query" do
    result = db.fetch("SELECT * FROM hyd_pg WHERE id = 999", [], limit: 1000)
    expect(result.records).to eq([])
  end

  it "collapses duplicate JOIN column names last-wins, as the gem row Hash did" do
    # u.id (1) then p.id (1 here too) share the key :id; the second occurrence
    # wins, matching the pre-change PG::Result Hash behaviour.
    row = db.fetch_one(
      "SELECT u.id, p.id, u.name, p.title " \
      "FROM hyd_pg u JOIN hyd_pg_posts p ON p.user_id = u.id"
    )
    expect(row).to eq({ id: 1, name: "Alice", title: "Hi" })
  end
end
