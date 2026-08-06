# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# DB query cache — BOTH layers opt-in, DEFAULT OFF. Mirrors Python's
# tests/test_db_query_cache.py and the contract in
# tina4_python/database/connection.py.
#
# A request-scoped cache that defaults ON is a footgun: a SELECT MAX(id) (or
# generator read) right before an INSERT in the same request returns a cached
# pre-write value → duplicate primary keys, and any read-after-write in one
# request shows stale state. So the DEFAULT is OFF; the request cache stays
# available opt-in for read-heavy endpoints via TINA4_AUTO_CACHING=true.
#
# Layers:
#   • request-scoped (OPT-IN, TINA4_AUTO_CACHING=true) — dedupes identical
#     SELECTs, cleared per request + on writes, short safety TTL (5s).
#   • persistent (opt-in TINA4_DB_CACHE=true) — cross-request TTL cache (30s),
#     NOT cleared per request.
#
# Cache mode is read at CONSTRUCTION, so each test sets ENV before building the
# Database. ENV is snapshotted and restored around every example so the
# default-off/on state never leaks into other specs.
RSpec.describe "DB query cache (opt-in, default-off)" do
  around(:each) do |example|
    saved = {
      "TINA4_DB_CACHE" => ENV["TINA4_DB_CACHE"],
      "TINA4_DB_CACHE_TTL" => ENV["TINA4_DB_CACHE_TTL"],
      "TINA4_AUTO_CACHING" => ENV["TINA4_AUTO_CACHING"],
      "TINA4_AUTO_CACHING_TTL" => ENV["TINA4_AUTO_CACHING_TTL"]
    }
    # Start each example from the framework default (all unset → request mode).
    saved.each_key { |k| ENV.delete(k) }
    begin
      example.run
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end

  def make_db
    path = File.join(SpecTmpdir.create, "qc.db")
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)")
    db.execute("INSERT INTO t (n) VALUES (?)", ["a"])
    db.execute("INSERT INTO t (n) VALUES (?)", ["b"])
    db
  end

  describe "request-scoped default" do
    it "is OFF by default (mode off) when TINA4_AUTO_CACHING is unset" do
      db = make_db
      stats = db.cache_stats
      expect(stats[:enabled]).to be false
      expect(stats[:mode]).to eq("off")
      # Nothing is cached by default — identical reads do not dedupe.
      db.fetch("SELECT * FROM t")
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(0)
      expect(db.cache_stats[:hits]).to eq(0)
    end

    it "opts in to request mode via TINA4_AUTO_CACHING=true" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      stats = db.cache_stats
      expect(stats[:enabled]).to be true
      expect(stats[:mode]).to eq("request")
    end

    it "dedupes identical fetches (opt-in)" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t") # miss -> populates
      db.fetch("SELECT * FROM t") # hit
      stats = db.cache_stats
      expect(stats[:hits]).to be >= 1
      expect(stats[:size]).to eq(1)
    end

    it "invalidates on execute write (opt-in)" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      db.execute("INSERT INTO t (n) VALUES (?)", ["c"])
      expect(db.cache_stats[:size]).to eq(0)
    end

    it "invalidates on insert helper (opt-in)" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      db.insert("t", { n: "d" })
      expect(db.cache_stats[:size]).to eq(0)
    end
  end

  describe "request boundary (opt-in)" do
    it "reset_request_caches clears the request cache" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      # Simulate the dispatcher firing at the start of the next request.
      Tina4::Database.reset_request_caches
      expect(db.cache_stats[:size]).to eq(0)
    end

    it "cache_new_request preserves cumulative counters" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t")
      db.fetch("SELECT * FROM t") # one hit
      hits_before = db.cache_stats[:hits]
      expect(hits_before).to be >= 1
      db.cache_new_request
      expect(db.cache_stats[:hits]).to eq(hits_before) # counters survive
      expect(db.cache_stats[:size]).to eq(0)
    end
  end

  describe "off-switch" do
    it "TINA4_AUTO_CACHING=false disables (mode off)" do
      ENV["TINA4_AUTO_CACHING"] = "false"
      db = make_db
      stats = db.cache_stats
      expect(stats[:enabled]).to be false
      expect(stats[:mode]).to eq("off")
      db.fetch("SELECT * FROM t")
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(0) # nothing cached
      expect(db.cache_stats[:hits]).to eq(0)
    end
  end

  describe "per-query no_cache bypass" do
    it "does not populate the cache on a no_cache read (request mode)" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t", no_cache: true)
      stats = db.cache_stats
      expect(stats[:size]).to eq(0) # nothing stored
      expect(stats[:hits]).to eq(0)
      expect(stats[:misses]).to eq(0)
    end

    it "does not return a previously-cached value (bypasses lookup)" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT n FROM t WHERE id = ?", [1]) # miss -> caches row n="a"
      expect(db.cache_stats[:size]).to eq(1)

      # Mutate the row through the raw driver so the query cache is NOT
      # invalidated (db.execute would clear it). The cached value is now stale.
      db.current_driver.execute("UPDATE t SET n = ? WHERE id = ?", ["zzz", 1])

      # Normal read still serves the stale cached row...
      cached = db.fetch("SELECT n FROM t WHERE id = ?", [1])
      expect(cached.records.first[:n]).to eq("a")

      # ...but a no_cache read bypasses the cache and sees the fresh value.
      fresh = db.fetch("SELECT n FROM t WHERE id = ?", [1], no_cache: true)
      expect(fresh.records.first[:n]).to eq("zzz")
    end

    it "fetch_one with no_cache bypasses lookup and does not store" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch_one("SELECT n FROM t WHERE id = ?", [1]) # caches n="a"
      size_after_cached = db.cache_stats[:size]
      expect(size_after_cached).to be >= 1

      db.current_driver.execute("UPDATE t SET n = ? WHERE id = ?", ["yyy", 1])

      fresh = db.fetch_one("SELECT n FROM t WHERE id = ?", [1], no_cache: true)
      expect(fresh[:n]).to eq("yyy")
      # The no_cache fetch_one must not add a new cache entry.
      expect(db.cache_stats[:size]).to eq(size_after_cached)
    end

    it "fetch_all with no_cache returns rows without caching" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      rows = db.fetch_all("SELECT * FROM t", no_cache: true)
      expect(rows.length).to eq(2)
      expect(db.cache_stats[:size]).to eq(0)
    end

    it "leaves the normal cached path working alongside no_cache calls" do
      ENV["TINA4_AUTO_CACHING"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t", no_cache: true) # bypass — no effect on cache
      db.fetch("SELECT * FROM t")                 # miss -> populates
      db.fetch("SELECT * FROM t")                 # hit
      stats = db.cache_stats
      expect(stats[:size]).to eq(1)
      expect(stats[:hits]).to be >= 1
    end

    it "does not store in persistent mode either" do
      ENV["TINA4_DB_CACHE"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t", no_cache: true)
      expect(db.cache_stats[:size]).to eq(0)
      # Normal fetch still caches persistently.
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
    end
  end

  describe "persistent mode" do
    it "TINA4_DB_CACHE=true is persistent with ttl 30" do
      ENV["TINA4_DB_CACHE"] = "true"
      db = make_db
      stats = db.cache_stats
      expect(stats[:enabled]).to be true
      expect(stats[:mode]).to eq("persistent")
      expect(stats[:ttl]).to eq(30)
    end

    it "survives a request reset" do
      ENV["TINA4_DB_CACHE"] = "true"
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      Tina4::Database.reset_request_caches # no-op in persistent mode
      expect(db.cache_stats[:size]).to eq(1)
    end
  end
end
