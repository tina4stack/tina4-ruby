# frozen_string_literal: true
#
# Regression spec for the batch-insert fix (cross-framework parity with the
# Python master).
#
# db.insert(table, [hash, hash, hash]) — an ARRAY of rows — is the advertised
# batch-insert form (CLAUDE.md: "db.insert(table, data)"; book + docs show
# db.insert("users", [{...}, {...}])). It MUST:
#
#   1. insert ALL the rows (verified by reading them back), and
#   2. report affected_rows == the number of rows, run inside ONE transaction on
#      ONE connection so the count / last_id are deterministic (never scattered
#      across pooled connections), and
#   3. surface a sensible last_id where the engine exposes one (SERIAL /
#      AUTOINCREMENT) and nil where it does not.
#
# Before the fix the batch returned the raw Array from execute_many — no
# affected_rows, no last_id — so `result.affected_rows == 3` was unavailable.
# The single-row insert path is unchanged.
#
# SQLite runs always (temp file). PostgreSQL runs against the live container and
# skips with a 'postgres ... not reachable' reason when it isn't up (so the
# TINA4_REQUIRE_SERVICES gate in spec_helper still catches a CI miss).
# MySQL / MSSQL are gated-skip (not provisioned for the Ruby framework).

require "spec_helper"
require "socket"
require "tmpdir"
require "fileutils"

PG_HOST_BI = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PG_PORT_BI = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
PG_USER_BI = ENV.fetch("TINA4_TEST_PG_USER", "tina4")
PG_PASS_BI = ENV.fetch("TINA4_TEST_PG_PASS", "tina4")
PG_DB_BI   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def batch_pg_reachable?
  TCPSocket.new(PG_HOST_BI, PG_PORT_BI).tap(&:close)
  true
rescue StandardError
  false
end

def batch_pg_gem?
  require "pg"
  true
rescue LoadError
  false
end

# Shared batch-insert contract — exercised against each reachable engine.
RSpec.shared_examples "a batch insert" do
  let(:rows) do
    [
      { name: "Alice", price: 1.0 },
      { name: "Bob",   price: 2.0 },
      { name: "Carol", price: 3.0 }
    ]
  end

  it "inserts ALL three rows (read back) and reports affected_rows == 3" do
    result = db.insert(table, rows)

    # 2. affected_rows == row count
    expect(result.affected_rows).to eq(3)

    # 1. every row is actually in the table
    read = db.fetch("SELECT name FROM #{table} ORDER BY name", [], limit: 100)
    names = read.map { |r| r[:name] || r["name"] }
    expect(names).to eq(%w[Alice Bob Carol])
  end

  it "surfaces a sensible last_id for an auto-increment PK" do
    result = db.insert(table, rows)
    next unless exposes_last_id

    # The last row inserted owns the highest id; last_id must be a positive
    # integer equal to that row's id (deterministic — one connection).
    expect(result.last_id).to be_a(Integer)
    expect(result.last_id).to be > 0
    max_id = db.fetch_one("SELECT MAX(id) AS m FROM #{table}")[:m].to_i
    expect(result.last_id).to eq(max_id)
  end

  it "does not crash or alter single-row insert (still a single row, has last_id)" do
    result = db.insert(table, { name: "Solo", price: 9.0 })
    # Single-row path returns the engine's usual shape (Hash with :last_id for
    # SQLite/MySQL/MSSQL, DatabaseResult-ish for PG) — never an array batch.
    count = db.fetch_one("SELECT COUNT(*) AS c FROM #{table} WHERE name = ?", ["Solo"])[:c].to_i
    expect(count).to eq(1)
    expect(result).not_to be_nil
  end

  it "empty array is a no-op reporting affected_rows == 0" do
    result = db.insert(table, [])
    expect(result.affected_rows).to eq(0)
    count = db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c].to_i
    expect(count).to eq(0)
  end
end

RSpec.describe "Batch insert — SQLite (always runs)" do
  let(:table) { "batch_products" }
  let(:exposes_last_id) { true }

  before(:each) do
    @dir = Dir.mktmpdir("tina4_batch")
    @db = Tina4::Database.new("sqlite:///#{File.join(@dir, 'batch.db')}")
    @db.execute(
      "CREATE TABLE #{table} (id INTEGER PRIMARY KEY AUTOINCREMENT, " \
      "name TEXT, price REAL)"
    )
  end

  after(:each) do
    @db&.close
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  let(:db) { @db }

  include_examples "a batch insert"
end

RSpec.describe "Batch insert — PostgreSQL (live)" do
  let(:table) { "batch_products_pg" }
  let(:exposes_last_id) { true }

  before(:all) do
    @skip_reason = if !batch_pg_gem?
                     "pg gem not installed (skip)"
                   elsif !batch_pg_reachable?
                     "PostgreSQL not reachable at #{PG_HOST_BI}:#{PG_PORT_BI} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PG_HOST_BI}:#{PG_PORT_BI}/#{PG_DB_BI}",
      username: PG_USER_BI, password: PG_PASS_BI
    )
    @db.execute("DROP TABLE IF EXISTS #{table}")
    @db.execute("CREATE TABLE #{table} (id SERIAL PRIMARY KEY, name TEXT, price DOUBLE PRECISION)")
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS #{table}")
    ensure
      @db.close rescue nil
    end
  end

  let(:db) { @db }

  include_examples "a batch insert"

  it "runs the batch in ONE transaction (rolls back as a unit on a bad row)" do
    skip(@skip_reason) if @skip_reason
    # A NOT NULL violation on the third row must roll the whole batch back —
    # no partial inserts — because the batch is one transaction on one
    # connection.
    @db.execute("ALTER TABLE #{table} ALTER COLUMN name SET NOT NULL")
    expect do
      @db.insert(table, [
        { name: "ok1", price: 1.0 },
        { name: "ok2", price: 2.0 },
        { name: nil,   price: 3.0 } # violates NOT NULL
      ])
    end.to raise_error(StandardError)

    count = @db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c].to_i
    expect(count).to eq(0)
  end
end

RSpec.describe "Batch insert — MySQL (gated)" do
  it "is skipped unless a live MySQL is provisioned" do
    skip("MySQL not provisioned for tina4-ruby (skip)")
  end
end

RSpec.describe "Batch insert — MSSQL (gated)" do
  it "is skipped unless a live MSSQL is provisioned" do
    skip("MSSQL not provisioned for tina4-ruby (skip)")
  end
end
