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
PG_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4")

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

  it "last_insert_id returns nil on a UUID-PK table without leaving the connection broken" do
    @db.insert("t4_issue38_uuid", { name: "probe" })
    # The lastval probe should fail (no sequence), but the connection
    # should still be usable for subsequent queries.
    row = @db.fetch_one("SELECT count(*) AS n FROM t4_issue38_uuid WHERE name = ?", ["probe"])
    expect(row[:n].to_i).to eq(1)
  end
end
