# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# CACHE CONTRACT - cache_clear clears the PERSISTENT layer.
#
# Pins `cache-clear-clears-the-persistent-layer` from
# plan/v3/fixtures/cache_contract.json (ADR-0024):
#
#   The database-level cache_clear() clears the PERSISTENT shared backend, not
#   only the in-process layer.
#
# The measured defect for this invariant was PYTHON's: its Database.cache_clear()
# cleared the in-process dict and the counters and never touched the shared
# backend, so with TINA4_DB_CACHE=true it was a no-op on every provider. Ruby
# already cleared @cache_backend, so these are PARITY LOCK-IN tests: they must
# stay real gates so Ruby can never regress into Python's bug.
#
# They are not decoration, and writing them surfaced a REAL Ruby defect of its
# own. RedisBackend#stats hardcoded `size = 0` unless the `redis` GEM was
# loaded, so on the ZERO-DEPENDENCY raw-RESP transport - the default install -
# db.cache_stats[:size] always reported 0 no matter how many entries were
# cached. Every assertion below about the size of the shared cache was
# unexpressable until that was fixed, and any dashboard reading that number was
# reading a constant.
#
# Every assertion runs against a REAL shared Redis. Nothing is simulated.
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheClearPersistentContract
  REDIS_URL = ENV.fetch("TINA4_TEST_CACHE_REDIS_URL", "redis://127.0.0.1:6379")
  SQL = "SELECT owner FROM widget WHERE id = ?"

  KEYS = %w[
    TINA4_DB_CACHE TINA4_DB_CACHE_TTL TINA4_DB_CACHE_BACKEND TINA4_DB_CACHE_URL
    TINA4_AUTO_CACHING TINA4_AUTO_CACHING_TTL TINA4_DATABASE_URL
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

  def persistent_redis
    ENV["TINA4_DB_CACHE"] = "true"
    ENV["TINA4_DB_CACHE_TTL"] = "300"
    ENV["TINA4_DB_CACHE_BACKEND"] = "redis"
    ENV["TINA4_DB_CACHE_URL"] = REDIS_URL
  end

  def seed(path)
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE IF NOT EXISTS widget (id INTEGER PRIMARY KEY, owner TEXT)")
    db.execute("DELETE FROM widget")
    db.insert("widget", { "id" => 1, "owner" => "original" })
    db
  end
end

RSpec.describe "cache clear persistent layer" do
  around(:each) { |example| CacheClearPersistentContract.around(example) }
  around(:each) do |example|
    Dir.mktmpdir("tina4-clearpersist") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  it "cache clear clears the persistent backend" do
    CacheClearPersistentContract.persistent_redis
    db = CacheClearPersistentContract.seed(File.join(@tmp, "app.db"))
    expect(db.cache_stats[:backend]).to eq("redis"), "precondition: a persistent redis backend is configured"
    db.cache_clear

    db.fetch(CacheClearPersistentContract::SQL, [1])
    # Count entries in the REAL backend rather than reconstructing the key, so
    # this cannot go quietly green if the key format changes.
    expect(db.cache_stats[:size]).to be > 0, "precondition: the read was cached in redis"

    db.cache_clear

    expect(db.cache_stats[:size]).to eq(0),
                                     "cache_clear left the entry in the SHARED backend - it cleared only the " \
                                     "in-process layer, so clearing the cache after a bulk import works in " \
                                     "development and does nothing in production"
  end

  it "cache clear is visible to another instance" do
    CacheClearPersistentContract.persistent_redis
    path = File.join(@tmp, "shared.db")
    db_one = CacheClearPersistentContract.seed(path)
    db_two = Tina4::Database.new("sqlite:///#{path}")
    db_one.cache_clear

    db_one.fetch(CacheClearPersistentContract::SQL, [1])
    expect(db_two.cache_stats[:size]).to be > 0, "precondition: the two instances share one backend"

    db_one.cache_clear

    expect(db_two.cache_stats[:size]).to eq(0),
                                         "instance two still sees the entry instance one cleared - the clear never " \
                                         "reached the shared backend, so an operator cannot clear the cache from " \
                                         "one process after a bulk import"
  end

  it "cache clear leaves the backend usable" do
    CacheClearPersistentContract.persistent_redis
    db = CacheClearPersistentContract.seed(File.join(@tmp, "reusable.db"))
    db.cache_clear

    db.fetch(CacheClearPersistentContract::SQL, [1])

    expect(db.cache_stats[:size]).to be > 0,
                                     "nothing was cached after cache_clear - the clear left the backend unusable, " \
                                     "which passes a cleared-everything assertion and is still wrong"
    stats = db.cache_stats
    expect(stats[:mode]).to eq("persistent")
    expect(stats[:backend]).to eq("redis")
  end

  it "cache clear without a persistent backend is safe" do
    ENV["TINA4_DB_CACHE"] = "false"
    ENV["TINA4_AUTO_CACHING"] = "true"
    ENV.delete("TINA4_DB_CACHE_URL")

    db = CacheClearPersistentContract.seed(File.join(@tmp, "local.db"))
    expect(db.cache_stats[:backend]).to eq("memory"),
                                        "precondition: no shared backend in request-scoped mode"
    db.fetch(CacheClearPersistentContract::SQL, [1])
    db.cache_clear

    stats = db.cache_stats
    expect(stats[:mode]).to eq("request")
    expect(stats[:size]).to eq(0)
    expect(stats[:hits]).to eq(0)
    expect(stats[:misses]).to eq(0),
                              "cache_clear raised or skipped the in-process layer when no shared backend is " \
                              "configured - the request-scoped and off modes must not break"
  end
end
