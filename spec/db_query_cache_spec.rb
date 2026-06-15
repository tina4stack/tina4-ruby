# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Request-scoped DB query cache (default-on) — protects the DB from rapid
# identical reads. Mirrors Python's tests/test_db_query_cache.py and the
# contract in tina4_python/database/connection.py.
#
# Layers:
#   • request-scoped (DEFAULT ON, off-switch TINA4_AUTO_CACHING=false) — dedupes
#     identical SELECTs, cleared per request + on writes, short safety TTL (5s).
#   • persistent (opt-in TINA4_DB_CACHE=true) — cross-request TTL cache (30s),
#     NOT cleared per request.
#
# Cache mode is read at CONSTRUCTION, so each test sets ENV before building the
# Database. ENV is snapshotted and restored around every example so the
# default-on/off state never leaks into other specs.
RSpec.describe "DB query cache (request-scoped, default-on)" do
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
    path = File.join(Dir.mktmpdir, "qc.db")
    db = Tina4::Database.new("sqlite://#{path}")
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)")
    db.execute("INSERT INTO t (n) VALUES (?)", ["a"])
    db.execute("INSERT INTO t (n) VALUES (?)", ["b"])
    db
  end

  describe "request-scoped default" do
    it "is on by default (mode request)" do
      db = make_db
      stats = db.cache_stats
      expect(stats[:enabled]).to be true
      expect(stats[:mode]).to eq("request")
    end

    it "dedupes identical fetches" do
      db = make_db
      db.fetch("SELECT * FROM t") # miss -> populates
      db.fetch("SELECT * FROM t") # hit
      stats = db.cache_stats
      expect(stats[:hits]).to be >= 1
      expect(stats[:size]).to eq(1)
    end

    it "invalidates on execute write" do
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      db.execute("INSERT INTO t (n) VALUES (?)", ["c"])
      expect(db.cache_stats[:size]).to eq(0)
    end

    it "invalidates on insert helper" do
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      db.insert("t", { n: "d" })
      expect(db.cache_stats[:size]).to eq(0)
    end
  end

  describe "request boundary" do
    it "reset_request_caches clears the request cache" do
      db = make_db
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      # Simulate the dispatcher firing at the start of the next request.
      Tina4::Database.reset_request_caches
      expect(db.cache_stats[:size]).to eq(0)
    end

    it "cache_new_request preserves cumulative counters" do
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
