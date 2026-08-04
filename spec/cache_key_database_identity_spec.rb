# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "securerandom"

# CACHE CONTRACT - a query-cache key carries DATABASE IDENTITY.
#
# Pins `the-cache-key-carries-database-identity` from
# plan/v3/fixtures/cache_contract.json (ADR-0024):
#
#   A query-cache key identifies the DATABASE it came from. Two databases
#   sharing one cache backend can never serve each other's rows.
#
# This is a DATA ISOLATION failure wearing a caching costume. MEASURED IN RUBY
# AT HEAD, lib/tina4/database.rb#cache_key was
#
#   Digest::SHA256.hexdigest(sql + params.to_s)
#
# with nothing naming the connection, so on ANY shared backend two databases
# cross-served each other's rows: two apps pointed at one Redis, or one app with
# a primary and an analytics connection, silently read each other's data. The
# identical SQL text is exactly what a multi-tenant deployment runs, so the
# collision is the common case, not an edge case.
#
# Everything here runs against REAL databases (two real SQLite files and two
# real PostgreSQL databases) and a REAL shared cache backend. Nothing is
# simulated.
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheKeyIdentityContract
  REDIS_URL = ENV.fetch("TINA4_TEST_CACHE_REDIS_URL", "redis://127.0.0.1:6379")
  PG_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  PG_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432")
  PG_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  PG_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  # Databases this contract OWNS. Never touch one we did not create.
  PG_DB_A = "tina4_cache_contract_a"
  PG_DB_B = "tina4_cache_contract_b"

  SQL = "SELECT owner FROM widget WHERE id = ?"

  # Every env var these examples touch, snapshotted and restored. This repo has
  # had spec ENV-contamination issues, so the suite is deliberately strict.
  KEYS = %w[
    TINA4_DB_CACHE TINA4_DB_CACHE_TTL TINA4_DB_CACHE_BACKEND TINA4_DB_CACHE_URL
    TINA4_AUTO_CACHING TINA4_AUTO_CACHING_TTL TINA4_DATABASE_URL
    TINA4_DATABASE_USERNAME TINA4_DATABASE_PASSWORD
    TINA4_CACHE_BACKEND TINA4_CACHE_URL TINA4_CACHE_DIR
  ].freeze

  module_function

  def around(example)
    saved = KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    begin
      example.run
    ensure
      KEYS.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
    end
  end

  # Point the persistent DB query cache at ONE real shared Redis.
  def shared_redis_cache
    ENV["TINA4_DB_CACHE"] = "true"
    ENV["TINA4_DB_CACHE_TTL"] = "60"
    ENV["TINA4_DB_CACHE_BACKEND"] = "redis"
    ENV["TINA4_DB_CACHE_URL"] = REDIS_URL
  end

  def seed_sqlite(path, marker)
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE IF NOT EXISTS widget (id INTEGER PRIMARY KEY, owner TEXT)")
    db.execute("DELETE FROM widget")
    db.insert("widget", { "id" => 1, "owner" => marker })
    db
  end

  def owner_of(result)
    row = result.records.first
    row[:owner] || row["owner"]
  end

  def pg_url(database)
    "postgres://#{PG_HOST}:#{PG_PORT}/#{database}"
  end
end

RSpec.describe "cache key database identity" do
  around(:each) { |example| CacheKeyIdentityContract.around(example) }
  around(:each) do |example|
    Dir.mktmpdir("tina4-cachekey") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  it "two databases sharing one cache backend do not cross serve" do
    CacheKeyIdentityContract.shared_redis_cache
    db_a = CacheKeyIdentityContract.seed_sqlite(File.join(@tmp, "primary.db"), "database-a")
    db_b = CacheKeyIdentityContract.seed_sqlite(File.join(@tmp, "analytics.db"), "database-b")
    db_a.cache_clear
    db_b.cache_clear

    rows_a = db_a.fetch(CacheKeyIdentityContract::SQL, [1])
    rows_b = db_b.fetch(CacheKeyIdentityContract::SQL, [1])

    expect(CacheKeyIdentityContract.owner_of(rows_a)).to eq("database-a")
    expect(CacheKeyIdentityContract.owner_of(rows_b)).to eq("database-b"),
                                                         "database B was served database A's cached row - the cache " \
                                                         "key carries no database identity, so a shared backend " \
                                                         "cross-serves between databases. This is a data-isolation " \
                                                         "failure, not a cache miss."
  end

  it "the cache key changes when the database changes" do
    db_a = Tina4::Database.new("sqlite:///#{File.join(@tmp, 'one.db')}")
    db_b = Tina4::Database.new("sqlite:///#{File.join(@tmp, 'two.db')}")

    key_a = db_a.send(:cache_key, CacheKeyIdentityContract::SQL, [1])
    key_b = db_b.send(:cache_key, CacheKeyIdentityContract::SQL, [1])

    expect(key_a).not_to eq(key_b),
                         "the same SQL against two different databases produces the SAME cache key, so either " \
                         "can serve the other's rows"
  end

  it "the cache key is stable for the same database" do
    path = File.join(@tmp, "same.db")
    first = Tina4::Database.new("sqlite:///#{path}")
    second = Tina4::Database.new("sqlite:///#{path}")

    expect(first.send(:cache_key, CacheKeyIdentityContract::SQL, [1]))
      .to eq(second.send(:cache_key, CacheKeyIdentityContract::SQL, [1])),
          "two connections to the SAME database produce different cache keys, so a shared cache can never hit " \
          "across instances. A key that folds in anything per-connection or per-process (an object_id, a pid, a " \
          "random salt) isolates the databases by accident and destroys the whole point of a shared cache."
  end

  it "the cache key excludes credentials" do
    # A pure function over its inputs, so it needs no live service and uses no
    # stand-in: cache_identity is called directly rather than through a
    # connection, because the constructor connects eagerly and a deliberately
    # wrong password would fail before the key is ever computed.
    plain = Tina4::Database.send(:cache_identity, "postgres://db.internal:5432/ledger")
    with_user = Tina4::Database.send(:cache_identity, "postgres://reader@db.internal:5432/ledger")
    with_secret = Tina4::Database.send(:cache_identity, "postgres://reader:hunter2@db.internal:5432/ledger")
    rotated = Tina4::Database.send(:cache_identity, "postgres://reader:rotated-p4ss@db.internal:5432/ledger")

    expect([with_user, with_secret, rotated].uniq).to eq([plain]),
                                                      "the identity changed with the credentials - a rotation " \
                                                      "cold-starts the cache, and a shared backend's key namespace " \
                                                      "is visible to every tenant of that backend"
    expect(with_secret).not_to include("hunter2")
    expect(rotated).not_to include("rotated-p4ss"),
                           "a password appears verbatim in the cache identity, which is readable by every tenant " \
                           "of a shared cache backend"
    # And the identity still SEPARATES databases on that same server.
    expect(plain).not_to eq(Tina4::Database.send(:cache_identity, "postgres://db.internal:5432/analytics"))
  end

  it "two postgres databases do not cross serve" do
    CacheKeyIdentityContract.shared_redis_cache
    table = "widget_#{SecureRandom.hex(4)}"
    handles = {}
    begin
      { "database-a" => CacheKeyIdentityContract::PG_DB_A,
        "database-b" => CacheKeyIdentityContract::PG_DB_B }.each do |marker, database|
        db = Tina4::Database.new(CacheKeyIdentityContract.pg_url(database),
                                 username: CacheKeyIdentityContract::PG_USER,
                                 password: CacheKeyIdentityContract::PG_PASS)
        db.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, owner VARCHAR(50))")
        db.insert(table, { "id" => 1, "owner" => marker })
        db.cache_clear
        handles[marker] = db
      end

      sql = "SELECT owner FROM #{table} WHERE id = ?"
      got_a = CacheKeyIdentityContract.owner_of(handles["database-a"].fetch(sql, [1]))
      got_b = CacheKeyIdentityContract.owner_of(handles["database-b"].fetch(sql, [1]))

      expect(got_a).to eq("database-a")
      expect(got_b).to eq("database-b"),
                       "the analytics database was served the primary database's cached row - one PostgreSQL " \
                       "server, two databases, one shared cache, and the key cannot tell them apart. Same host, " \
                       "same port, same user, same SQL: only the database name differs."
    ensure
      # Drop only the table WE created. Never drop a database we did not make.
      handles.each_value do |db|
        db.execute("DROP TABLE IF EXISTS #{table}")
      rescue StandardError
        nil
      end
    end
  end
end
