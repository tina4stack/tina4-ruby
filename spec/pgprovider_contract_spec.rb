# frozen_string_literal: true

# PostgreSQL provider as the write-path ORACLE - feature 9 (pgprovider_contract.json),
# parity with tina4-python/tests/test_pgprovider_contract.py.
#
# PG-DEC-01 (OWNER-DECISIONS.md Batch 5, feature 009-postgresql-provider.md): make the
# adapter-contract test assert real write-path BEHAVIOUR - not just method presence -
# with PostgreSQL as the reference model. PostgreSQL is the oracle for the write
# contract: native RETURNING gives the true generated last-id, the transaction is real,
# and the affected count is exact.
#
# Every case drives the lab's REAL PostgreSQL :55432 (tina4/tina4 -> tina4_rb) through
# the public Tina4::Database facade -> PostgresDriver. No mocks. Durability is read back
# on a SECOND, FRESH connection where that is the property under test. The oracle table
# has a SERIAL key and is dropped + recreated per example, so the RETURNING-generated id
# is deterministic (first insert -> 1, second -> 2).
#
# Real skips (never a `describe ..., if:` that DROPS examples), so TINA4_REQUIRE_SERVICES
# catches a postgres that should be up but is not.
#
# Mutation-proof: make Database#execute_many skip its transaction (execute each row
# standalone) and "execute many mid batch failure rolls back on a fresh connection" goes
# RED (the first row survives); drop the filterless-write guard and the guard cases go RED.

require "spec_helper"
require "socket"

RSpec.describe "PostgreSQL provider write-path oracle (feature 9)" do
  # Unique-suffixed constants: a bare constant inside an RSpec.describe leaks onto
  # Object, so name them so they cannot collide with another spec's.
  PGO_TABLE = "pgprovider_oracle"
  PGO_HOST  = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  PGO_PORT  = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  PGO_USER  = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  PGO_PASS  = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  PGO_DB    = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  def self.tcp_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  PGO_REACHABLE = tcp_reachable?(PGO_HOST, PGO_PORT)

  def pg_url
    "postgres://#{PGO_HOST}:#{PGO_PORT}/#{PGO_DB}"
  end

  def connect
    Tina4::Database.new(pg_url, username: PGO_USER, password: PGO_PASS)
  end

  # Every row on a SECOND connection - the durability witness. A write visible
  # only on the connection that made it is not durable.
  def fresh_rows
    other = connect
    begin
      other.fetch("SELECT * FROM #{PGO_TABLE} ORDER BY id", [], limit: 1000).records
    ensure
      other.close rescue nil
    end
  end

  before do
    skip "no reachable postgres at #{PGO_HOST}:#{PGO_PORT} (set TINA4_TEST_PG_*)" unless PGO_REACHABLE
    @db = connect
    # A fresh, empty oracle table per example so SERIAL restarts at 1 - that is
    # what makes the RETURNING-generated id deterministic to assert.
    @db.execute("DROP TABLE IF EXISTS #{PGO_TABLE}")
    @db.execute(
      "CREATE TABLE #{PGO_TABLE} (id SERIAL PRIMARY KEY, code VARCHAR(40) NOT NULL UNIQUE, qty INTEGER)"
    )
  end

  after do
    next unless @db
    @db.execute("DROP TABLE IF EXISTS #{PGO_TABLE}") rescue nil
    @db.close rescue nil
  end

  # ── pg-insert-returning-last-id ─────────────────────────────────────────────

  it "insert returns the returning generated last id" do
    result = @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    expect(result.last_id).to eq(1)
    rows = fresh_rows
    expect(rows.length).to eq(1)
    expect(rows[0][:id]).to eq(1)
    expect(rows[0][:code]).to eq("a")
  end

  it "insert reports affected rows of one" do
    result = @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    expect(result.affected_rows).to eq(1)
  end

  it "a second insert returns the next generated id not a stale one" do
    first = @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    second = @db.insert(PGO_TABLE, { "code" => "b", "qty" => 20 })
    expect(first.last_id).to eq(1)
    expect(second.last_id).to eq(2)
    expect(second.last_id).not_to eq(first.last_id)
  end

  # ── pg-write-affected-count ─────────────────────────────────────────────────

  it "update reports the exact number of rows changed" do
    @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    @db.insert(PGO_TABLE, { "code" => "b", "qty" => 20 })
    @db.insert(PGO_TABLE, { "code" => "c", "qty" => 40 })
    result = @db.update(PGO_TABLE, { "qty" => 99 }, "qty < ?", [30])
    expect(result.affected_rows).to eq(2)
  end

  it "update reports a null last id" do
    @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    result = @db.update(PGO_TABLE, { "qty" => 99 }, "code = ?", ["a"])
    expect(result.last_id).to be_nil
  end

  it "delete reports the exact number of rows removed" do
    @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    @db.insert(PGO_TABLE, { "code" => "b", "qty" => 20 })
    result = @db.delete(PGO_TABLE, { "code" => "a" })
    expect(result.affected_rows).to eq(1)
    expect(fresh_rows.map { |r| r[:code] }).to eq(["b"])
  end

  # ── pg-filterless-write-guard ───────────────────────────────────────────────

  it "update without a filter or primary key raises and changes nothing" do
    @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    @db.insert(PGO_TABLE, { "code" => "b", "qty" => 20 })
    # No filter and no primary key in the data -> a full-table rewrite that must
    # be refused, not performed.
    expect { @db.update(PGO_TABLE, { "qty" => 1 }) }.to raise_error(StandardError)
    by_code = fresh_rows.each_with_object({}) { |r, h| h[r[:code]] = r[:qty].to_i }
    expect(by_code).to eq({ "a" => 10, "b" => 20 })
  end

  it "delete without a filter raises and removes nothing" do
    @db.insert(PGO_TABLE, { "code" => "a", "qty" => 10 })
    @db.insert(PGO_TABLE, { "code" => "b", "qty" => 20 })
    # truncate(table) is the explicit whole-table empty, not this.
    expect { @db.delete(PGO_TABLE) }.to raise_error(StandardError)
    expect(fresh_rows.length).to eq(2)
  end

  # ── pg-executemany-atomicity ────────────────────────────────────────────────

  it "execute many mid batch failure rolls back on a fresh connection" do
    # RETURNING forces the row-at-a-time loop (the batch collapser rejects it), so
    # the first set really executes inside the owned transaction before the second
    # set violates UNIQUE(code). One owned transaction -> the failure rolls the
    # whole batch back and a fresh connection sees ZERO rows.
    expect do
      @db.execute_many(
        "INSERT INTO #{PGO_TABLE} (code, qty) VALUES (?, ?) RETURNING *",
        [["dup", 1], ["dup", 2]]
      )
    end.to raise_error(StandardError)
    expect(fresh_rows).to eq([])
  end

  it "execute many empty input is a zero row no op" do
    result = @db.execute_many("INSERT INTO #{PGO_TABLE} (code, qty) VALUES (?, ?)", [])
    expect(result.affected_rows).to eq(0)
    expect(fresh_rows).to eq([])
  end

  # ── pg-fetch-shape ──────────────────────────────────────────────────────────

  it "fetch returns a native list of rows with native types" do
    @db.insert(PGO_TABLE, { "code" => "x", "qty" => 42 })
    result = @db.fetch("SELECT id, code, qty FROM #{PGO_TABLE} ORDER BY id")
    expect(result.records).to be_an(Array)
    expect(result.records.length).to eq(1)
    row = result.records[0]
    # Ruby's pg BasicTypeMapForResults decodes an INTEGER column to a native
    # Integer - that is PostgreSQL's native type surfaced to Ruby.
    expect(row[:qty]).to be_a(Integer)
    expect(row[:qty]).to eq(42)
    expect(row[:code]).to eq("x")
  end

  it "fetch one returns a single native record" do
    @db.insert(PGO_TABLE, { "code" => "y", "qty" => 7 })
    row = @db.fetch_one("SELECT code, qty FROM #{PGO_TABLE} WHERE code = ?", ["y"])
    expect(row).to be_a(Hash)
    expect(row[:code]).to eq("y")
    expect(row[:qty]).to eq(7)
  end

  it "fetch one with no match returns null" do
    row = @db.fetch_one("SELECT * FROM #{PGO_TABLE} WHERE code = ?", ["nope"])
    expect(row).to be_nil
  end
end
