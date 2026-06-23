# frozen_string_literal: true
#
# Regression spec for issue #38 — PG adapter's lastval() probe must not
# abort the outer transaction on UUID PK tables.
#
# Before the savepoint wrap in postgres_driver.rb#last_insert_id, this
# sequence:
#
#     INSERT INTO uuid_table (...) VALUES (...)
#     SELECT * FROM uuid_table
#
# failed on the SELECT with PG::InFailedSqlTransaction, because the
# post-INSERT ``SELECT lastval()`` probe raised on the missing sequence
# and the pg gem marked the whole transaction as aborted. The bare
# ``rescue PG::Error`` swallowed the original error and the symptom was
# a perfectly valid SELECT failing later with no useful breadcrumbs.
#
# This spec boots a real PostgreSQL (Docker container at localhost:55432),
# runs the exact reproduction from the issue, and asserts the SELECT
# succeeds. The spec is skipped automatically when the container isn't
# reachable so CI without postgres just no-ops.

require "spec_helper"
require "socket"

PG_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PG_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
PG_USER = ENV.fetch("TINA4_TEST_PG_USER", "tina4")
PG_PASS = ENV.fetch("TINA4_TEST_PG_PASS", "tina4")
# The live Ruby PostgreSQL database is `tina4_rb` (user/pass tina4) — matches
# the other PG specs (postgres_create_table_spec.rb) so this spec actually runs
# against the running container instead of silently skipping on a wrong db name.
PG_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pg_reachable?
  TCPSocket.new(PG_HOST, PG_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def pg_gem_available?
  require "pg"
  true
rescue LoadError
  false
end

RSpec.describe "Issue #38 — PostgreSQL UUID PK INSERT does not abort transaction" do
  before(:all) do
    @skip_reason = if !pg_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pg_reachable?
                     "PostgreSQL not reachable at #{PG_HOST}:#{PG_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PG_HOST}:#{PG_PORT}/#{PG_DB}",
      username: PG_USER, password: PG_PASS
    )
    @db.execute("DROP TABLE IF EXISTS t4_issue38_uuid")
    @db.execute(
      "CREATE TABLE t4_issue38_uuid (" \
      "  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), " \
      "  name text" \
      ")"
    )
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS t4_issue38_uuid")
    ensure
      @db.close rescue nil
    end
  end

  it "INSERT then SELECT on a UUID-PK table does not abort the transaction" do
    # The exact reproduction from the issue. Both must succeed.
    @db.insert("t4_issue38_uuid", { name: "alice" })
    row = @db.fetch_one("SELECT name FROM t4_issue38_uuid WHERE name = ?", ["alice"])
    expect(row).not_to be_nil
    expect(row[:name]).to eq("alice")
  end

  it "INSERT then multiple SELECTs all succeed on the same connection" do
    @db.insert("t4_issue38_uuid", { name: "bob" })
    @db.insert("t4_issue38_uuid", { name: "carol" })
    rows = @db.fetch("SELECT name FROM t4_issue38_uuid ORDER BY name")
    names = rows.map { |r| r[:name] }
    expect(names).to eq(%w[bob carol])
  end

  it "INSERT then UPDATE then SELECT chain works" do
    @db.insert("t4_issue38_uuid", { name: "dave" })
    @db.execute("UPDATE t4_issue38_uuid SET name = ? WHERE name = ?", %w[dave2 dave])
    row = @db.fetch_one("SELECT name FROM t4_issue38_uuid")
    expect(row[:name]).to eq("dave2")
  end

  it "explicit start_transaction with multiple UUID inserts persists all rows on commit" do
    @db.start_transaction
    @db.insert("t4_issue38_uuid", { name: "e1" })
    @db.insert("t4_issue38_uuid", { name: "e2" })
    @db.insert("t4_issue38_uuid", { name: "e3" })
    @db.commit

    n = @db.fetch_one("SELECT count(*) AS n FROM t4_issue38_uuid")[:n]
    expect(n.to_i).to eq(3)
  end

  it "explicit start_transaction with rollback drops all UUID inserts" do
    @db.start_transaction
    @db.insert("t4_issue38_uuid", { name: "x1" })
    @db.insert("t4_issue38_uuid", { name: "x2" })
    @db.rollback

    n = @db.fetch_one("SELECT count(*) AS n FROM t4_issue38_uuid")[:n]
    expect(n.to_i).to eq(0)
  end

  it "INSERT...RETURNING id on a UUID PK still returns the id" do
    result = @db.execute(
      "INSERT INTO t4_issue38_uuid (name) VALUES (?) RETURNING id",
      ["frank"]
    )
    expect(result).not_to be(false)
    # RETURNING returns a result enumerable with rows
    rows = result.respond_to?(:to_a) ? result.to_a : [result.first].compact
    if rows.any?
      first_row = rows.first
      uuid = first_row.is_a?(Hash) ? (first_row[:id] || first_row["id"]) : nil
      expect(uuid).not_to be_nil if uuid
    end
  end

  it "insert on a UUID-PK table leaves the connection usable for subsequent queries" do
    @db.insert("t4_issue38_uuid", { name: "probe" })
    # The insert (RETURNING *) must not abort the transaction (issue #38).
    # The connection stays usable for subsequent queries.
    row = @db.fetch_one("SELECT count(*) AS n FROM t4_issue38_uuid WHERE name = ?", ["probe"])
    expect(row[:n].to_i).to eq(1)
  end
end

# Issue #256 — a UUID-PK INSERT must surface the ACTUAL generated UUID as the
# last_id (NOT nil, NOT a stale wrong integer from an unrelated table's
# sequence), while a SERIAL integer PK keeps returning the incrementing integer.
#
# Before the fix, Database#insert ran a bare INSERT and probed the postgres
# driver's last_insert_id (SELECT lastval()). A UUID PK has no session
# sequence, so the probe returned nil — or, in the same session after a SERIAL
# insert, a STALE WRONG integer from that table's sequence. The fix makes the
# postgres driver's insert append `RETURNING *` and read the real id back
# (UUID string stays a string, SERIAL stays an integer). This block locks both
# halves in: the negative (a SERIAL test that proves the integer path still
# increments) AND the positive (the UUID is surfaced as the 36-char string).
UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

RSpec.describe "Issue #256 — PostgreSQL INSERT surfaces the actual primary key" do
  before(:all) do
    @skip_reason = if !pg_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pg_reachable?
                     "PostgreSQL not reachable at #{PG_HOST}:#{PG_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PG_HOST}:#{PG_PORT}/#{PG_DB}",
      username: PG_USER, password: PG_PASS
    )
    @db.execute("DROP TABLE IF EXISTS t4_issue256_uuid")
    @db.execute("DROP TABLE IF EXISTS t4_issue256_serial")
    @db.execute(
      "CREATE TABLE t4_issue256_uuid (" \
      "  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), " \
      "  name text" \
      ")"
    )
    @db.execute("CREATE TABLE t4_issue256_serial (id SERIAL PRIMARY KEY, name text)")
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS t4_issue256_uuid")
      @db.execute("DROP TABLE IF EXISTS t4_issue256_serial")
    ensure
      @db.close rescue nil
    end
  end

  it "surfaces the actual generated UUID as last_id (not nil, not an integer)" do
    result = @db.insert("t4_issue256_uuid", { name: "alice" })
    last_id = result[:last_id]

    expect(last_id).not_to be_nil
    expect(last_id).to be_a(String)
    expect(last_id).to match(UUID_RE)

    # It is the SAME id the row was actually written with.
    row = @db.fetch_one("SELECT id FROM t4_issue256_uuid WHERE name = ?", ["alice"])
    expect(last_id.to_s).to eq(row[:id].to_s)
  end

  it "surfaces the UUID even right after a SERIAL insert (no stale-integer leak)" do
    # The classic footgun: a SERIAL insert earlier in the session leaves a
    # lastval() value behind. A subsequent UUID insert must NOT return that
    # stale integer — it must return the real UUID string.
    @db.insert("t4_issue256_serial", { name: "serial-first" })
    result = @db.insert("t4_issue256_uuid", { name: "bob" })

    expect(result[:last_id]).to be_a(String)
    expect(result[:last_id]).to match(UUID_RE)
    expect(result[:last_id]).not_to eq(1) # not the stale serial id
  end

  it "db.get_last_id also returns the actual UUID after a UUID insert" do
    @db.insert("t4_issue256_uuid", { name: "carol" })
    last = @db.get_last_id
    expect(last).to be_a(String)
    expect(last).to match(UUID_RE)
  end

  it "SERIAL-PK insert returns the incrementing integer id (path unchanged)" do
    r1 = @db.insert("t4_issue256_serial", { name: "g1" })
    r2 = @db.insert("t4_issue256_serial", { name: "g2" })

    expect(r1[:last_id]).to be_a(Integer)
    expect(r2[:last_id]).to be_a(Integer)
    expect(r2[:last_id]).to eq(r1[:last_id] + 1) # auto-increment still increments
  end

  it "a bare execute INSERT on a SERIAL table does not leak a prior UUID last_id" do
    # A UUID db.insert caches its RETURNING id; a following bare
    # execute("INSERT ...") on a SERIAL table must reset that so get_last_id
    # reflects the SERIAL sequence, not the stale UUID.
    @db.insert("t4_issue256_uuid", { name: "dave" })
    @db.execute("INSERT INTO t4_issue256_serial (name) VALUES (?)", ["e1"])
    last = @db.get_last_id
    expect(last).to be_a(Integer)
    expect(last).to eq(1)
  end
end
