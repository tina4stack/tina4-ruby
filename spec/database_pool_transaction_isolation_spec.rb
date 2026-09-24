# frozen_string_literal: true

require "spec_helper"
require "tina4"
require "securerandom"
require "timeout"
require_relative "support/live_postgres"

RSpec.describe "Pooled transaction isolation" do
  it "does not expose or commit another thread's transaction through a pooled connection" do
    skip "[needs:postgres] PostgreSQL not reachable" unless LivePostgres.reachable?
    url = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
    db = Tina4::Database.new(url, pool: 2)
    witness = Tina4::Database.new(url)
    table = "pool_isolation_#{SecureRandom.hex(6)}"
    witness.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY)")
    db.start_transaction
    db.execute("INSERT INTO #{table} VALUES (1)")
    reads = []
    worker = Thread.new do
      4.times { reads << db.fetch_all("SELECT id FROM #{table}", no_cache: true).map { |r| r[:id] || r["id"] } }
      db.execute("INSERT INTO #{table} VALUES (2)")
    end
    Timeout.timeout(10) { worker.value }
    db.rollback
    expect(reads.flatten).not_to include(1), "another thread observed an uncommitted row"
    expect(witness.fetch_all("SELECT id FROM #{table} ORDER BY id").map { |r| r[:id] || r["id"] }).to eq([2])
  ensure
    worker&.join(1)
    db&.rollback rescue nil
    witness&.execute("DROP TABLE IF EXISTS #{table}") if table
    db&.close
    witness&.close
  end
  it "fails fast when every connection is leased and permits reuse after rollback" do
    skip "[needs:postgres] PostgreSQL not reachable" unless LivePostgres.reachable?
    db = Tina4::Database.new(ENV["TINA4_TEST_PG_URL"] || LivePostgres.url, pool: 1)
    db.start_transaction
    result = Thread.new do
      expect { db.fetch_one("SELECT 1") }.to raise_error(RuntimeError, /pool exhausted/)
      expect { db.get_adapter }.to raise_error(RuntimeError, /pool exhausted/)
    end
    Timeout.timeout(5) { result.value }
    db.rollback
    expect(db.fetch_one("SELECT 7 AS value")[:value]).to eq(7)
    borrowed = db.checkout
    Thread.new do
      expect { db.checkin(borrowed) }.to raise_error(ArgumentError, /not leased by this thread/)
    end.value
    expect { db.checkout }.to raise_error(RuntimeError, /pool exhausted/)
    db.checkin(borrowed)
    expect(db.fetch_one("SELECT 8 AS value")[:value]).to eq(8)
  ensure
    db&.close
  end

  it "retains a failed commit lease until rollback and releases failed standalone queries" do
    skip "[needs:postgres] PostgreSQL not reachable" unless LivePostgres.reachable?
    db = Tina4::Database.new(ENV["TINA4_TEST_PG_URL"] || LivePostgres.url, pool: 1)
    table = "pool_commit_#{SecureRandom.hex(6)}"
    db.execute("CREATE TABLE #{table} (id INTEGER UNIQUE DEFERRABLE INITIALLY DEFERRED)")
    db.start_transaction
    db.execute("INSERT INTO #{table} VALUES (1), (1)")
    expect { db.commit }.to raise_error(StandardError)
    Thread.new do
      expect { db.checkout }.to raise_error(RuntimeError, /pool exhausted/)
    end.value
    db.rollback
    expect(db.fetch_all("SELECT id FROM #{table}")).to eq([])
    expect { db.execute("INSERT INTO #{table} (missing_column) VALUES (2)") }.to raise_error(StandardError)
    expect(db.fetch_one("SELECT 9 AS value")[:value]).to eq(9)
  ensure
    db&.rollback rescue nil
    db&.execute("DROP TABLE IF EXISTS #{table}") if table
    db&.close
  end

  it "discards a broken transaction connection when rollback fails" do
    skip "[needs:postgres] PostgreSQL not reachable" unless LivePostgres.reachable?
    url = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
    db = Tina4::Database.new(url, pool: 1)
    witness = Tina4::Database.new(url)
    db.start_transaction
    pid = db.fetch_one("SELECT pg_backend_pid() AS pid")[:pid]
    expect(witness.fetch_one("SELECT pg_terminate_backend(?) AS terminated", [pid])[:terminated]).to be true
    expect { db.rollback }.to raise_error(StandardError)
    expect(db.fetch_one("SELECT 10 AS value")[:value]).to eq(10)
  ensure
    db&.close
    witness&.close
  end

  it "releases a connection whose transaction begin fails" do
    skip "[needs:postgres] PostgreSQL not reachable" unless LivePostgres.reachable?
    url = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
    db = Tina4::Database.new(url, pool: 1)
    witness = Tina4::Database.new(url)
    pid = db.fetch_one("SELECT pg_backend_pid() AS pid")[:pid]
    expect(witness.fetch_one("SELECT pg_terminate_backend(?) AS terminated", [pid])[:terminated]).to be true
    expect { db.start_transaction }.to raise_error(StandardError)
    expect(db.fetch_one("SELECT 11 AS value")[:value]).to eq(11)
  ensure
    db&.close
    witness&.close
  end

end
