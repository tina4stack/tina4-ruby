# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"
require "fileutils"

# Unified cache backend set (parity with Python tests/test_cache_backends.py
# and tests/test_db_query_cache.py::TestPersistentBackend):
#   memory / file / database (always available)
#   redis / valkey / memcached / mongodb (skip when the service is unreachable)
#   + file-fallback for unreachable / wrong-credential backends
#   + credential parsing (URL userinfo and TINA4_CACHE_* env vars)
#   + persistent cross-instance DB cache through the shared backend
#
# Parallel isolation (the docker harness is shared with other agents NOW):
#   redis/valkey use DB index 2; mongo uses db/collection tina4_cache_rb;
#   memcached keys are SHA-hashed + prefixed and deleted individually (no
#   flush_all reliance). The suite is strict about restoring ENV in around
#   blocks because this repo has had spec ENV-contamination issues.
# Strictly snapshot + restore every cache/DB env var these suites touch. This
# repo has had spec ENV-contamination issues, so we are deliberately strict.
# A module-level helper (not a constant inside a describe block) keeps it
# reusable across both example groups without constant collisions.
module CacheBackendsSpecEnv
  KEYS = %w[
    TINA4_CACHE_BACKEND TINA4_CACHE_URL TINA4_CACHE_TTL TINA4_CACHE_MAX_ENTRIES
    TINA4_CACHE_DIR TINA4_CACHE_USERNAME TINA4_CACHE_PASSWORD
    TINA4_DB_CACHE TINA4_DB_CACHE_TTL TINA4_DB_CACHE_BACKEND TINA4_DB_CACHE_URL
    TINA4_AUTO_CACHING TINA4_AUTO_CACHING_TTL TINA4_DATABASE_URL
  ].freeze

  def self.around(example)
    saved = KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    begin
      example.run
    ensure
      KEYS.each do |k|
        if saved[k].nil?
          ENV.delete(k)
        else
          ENV[k] = saved[k]
        end
      end
    end
  end
end

RSpec.describe Tina4::CacheBackends do
  around(:each) { |example| CacheBackendsSpecEnv.around(example) }

  def reachable?(host, port)
    s = Socket.tcp(host, port, connect_timeout: 1)
    s.close
    true
  rescue StandardError
    false
  end

  # Round-trip contract shared by every backend (mirrors Python _roundtrip).
  def roundtrip(backend, expect_name)
    backend.clear
    backend.set("k1", { "v" => 1, "name" => "Alice" }, 60)
    expect(backend.get("k1")).to eq({ "v" => 1, "name" => "Alice" })
    expect(backend.get("missing")).to be_nil
    st = backend.stats
    expect(st[:backend]).to eq(expect_name)
    expect(st).to include(:hits, :misses, :size)
    expect(backend.delete("k1")).to be(true)
    expect(backend.get("k1")).to be_nil
  end

  # ── Local backends (always available) ────────────────────────────

  describe "local backends" do
    it "memory round-trips" do
      roundtrip(described_class.create_backend(backend: "memory"), "memory")
    end

    it "file round-trips" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_CACHE_DIR"] = dir
        roundtrip(described_class.create_backend(backend: "file"), "file")
      end
    end

    it "database (sqlite) round-trips" do
      Dir.mktmpdir do |dir|
        b = described_class.create_backend(backend: "database", url: "sqlite://#{dir}/cache.db")
        roundtrip(b, "database")
      end
    end

    it "unknown backend falls back to memory" do
      expect(described_class.create_backend(backend: "bogus").name).to eq("memory")
    end

    it "memory backend evicts LRU at max_entries" do
      b = described_class.create_backend(backend: "memory", max_entries: 2)
      b.set("a", 1, 60)
      b.set("b", 2, 60)
      b.set("c", 3, 60) # evicts "a"
      expect(b.get("a")).to be_nil
      expect(b.get("c")).to eq(3)
    end

    it "respects TTL expiry (memory)" do
      b = described_class.create_backend(backend: "memory")
      b.set("ttl", "x", 1)
      sleep(1.1)
      expect(b.get("ttl")).to be_nil
    end
  end

  # ── Graceful file-fallback ───────────────────────────────────────

  describe "file fallback" do
    it "an unreachable network backend degrades to a working file cache" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_CACHE_DIR"] = dir
        b = described_class.create_backend(backend: "redis", url: "redis://localhost:6399") # dead port
        expect(b.name).to eq("file")
        b.set("k", { "v" => 1 }, 60)
        expect(b.get("k")).to eq({ "v" => 1 })
      end
    end
  end

  # ── Credential parsing (no live server required) ─────────────────

  describe "credentials" do
    it "parses user:pass from the URL" do
      b = Tina4::CacheBackends::RedisBackend.new(url: "redis://alice:s3cret@127.0.0.1:6399")
      expect(b.instance_variable_get(:@username)).to eq("alice")
      expect(b.instance_variable_get(:@password)).to eq("s3cret")
      expect(b.instance_variable_get(:@host)).to eq("127.0.0.1")
      expect(b.instance_variable_get(:@port)).to eq(6399)
    end

    it "parses a password-only URL (redis://:pass@host)" do
      b = Tina4::CacheBackends::RedisBackend.new(url: "redis://:justpass@127.0.0.1:6399")
      expect(b.instance_variable_get(:@username)).to be_nil
      expect(b.instance_variable_get(:@password)).to eq("justpass")
    end

    it "reads credentials from TINA4_CACHE_USERNAME / TINA4_CACHE_PASSWORD" do
      ENV["TINA4_CACHE_USERNAME"] = "bob"
      ENV["TINA4_CACHE_PASSWORD"] = "pw"
      b = Tina4::CacheBackends::RedisBackend.new(url: "redis://127.0.0.1:6399")
      expect(b.instance_variable_get(:@username)).to eq("bob")
      expect(b.instance_variable_get(:@password)).to eq("pw")
    end

    it "has no credentials when none supplied" do
      ENV.delete("TINA4_CACHE_USERNAME")
      ENV.delete("TINA4_CACHE_PASSWORD")
      b = Tina4::CacheBackends::RedisBackend.new(url: "redis://127.0.0.1:6399")
      expect(b.instance_variable_get(:@username)).to be_nil
      expect(b.instance_variable_get(:@password)).to be_nil
    end

    it "parses the mongo database name from the URL path" do
      b = Tina4::CacheBackends::MongoBackend.new(url: "mongodb://localhost:27017/tina4_cache_rb")
      expect(b.send(:database_from_url, "mongodb://localhost:27017/tina4_cache_rb")).to eq("tina4_cache_rb")
    end
  end

  # ── Network backends (skip when unreachable) ─────────────────────

  describe "redis backend" do
    it "round-trips against redis on 6379 (db index 2)" do
      skip "redis not running" unless reachable?("localhost", 6379)
      b = described_class.create_backend(backend: "redis", url: "redis://localhost:6379/2")
      roundtrip(b, "redis")
    end
  end

  describe "valkey backend" do
    it "round-trips against valkey on 6380 (db index 2)" do
      skip "valkey not running" unless reachable?("localhost", 6380)
      b = described_class.create_backend(backend: "valkey", url: "valkey://localhost:6380/2")
      roundtrip(b, "valkey")
    end
  end

  describe "memcached backend" do
    it "round-trips against memcached on 11211 (prefixed, targeted delete)" do
      skip "memcached not running" unless reachable?("localhost", 11211)
      b = described_class.create_backend(backend: "memcached", url: "memcached://localhost:11211")
      # roundtrip's clear() flush_all is harmless, but we also exercise a
      # uniquely-prefixed targeted key so we never depend on flush behaviour.
      b.set("isolated-#{Process.pid}", { "x" => 1 }, 60)
      expect(b.get("isolated-#{Process.pid}")).to eq({ "x" => 1 })
      expect(b.delete("isolated-#{Process.pid}")).to be(true)
      roundtrip(b, "memcached")
    end
  end

  describe "mongodb backend" do
    it "round-trips against mongo on 27017 (db/collection tina4_cache_rb)" do
      skip "mongodb not running" unless reachable?("localhost", 27017)
      begin
        require "mongo"
      rescue LoadError
        skip "mongo gem not installed"
      end
      b = described_class.create_backend(backend: "mongodb", url: "mongodb://localhost:27017/tina4_cache_rb")
      skip "mongo backend unavailable" unless b.available?
      roundtrip(b, "mongodb")
    end
  end

  # ── Authenticated redis (redis-auth on 6381, requirepass s3cret) ─

  describe "authenticated redis (6381)" do
    it "connects with the right password and round-trips (db index 2)" do
      skip "auth redis not running" unless reachable?("localhost", 6381)
      b = described_class.create_backend(backend: "redis", url: "redis://:s3cret@localhost:6381/2")
      expect(b.name).to eq("redis") # must connect, NOT fall back to file
      roundtrip(b, "redis")
    end

    it "falls back to file on a wrong password (graceful, not a no-op)" do
      skip "auth redis not running" unless reachable?("localhost", 6381)
      Dir.mktmpdir do |dir|
        ENV["TINA4_CACHE_DIR"] = dir
        b = described_class.create_backend(backend: "redis", url: "redis://:wrongpass@localhost:6381/2")
        expect(b.name).to eq("file")
        b.set("k", { "v" => 1 }, 60)
        expect(b.get("k")).to eq({ "v" => 1 })
      end
    end
  end
end

# ── Persistent DB query cache through the unified backend ──────────
#
# Mirrors Python tests/test_db_query_cache.py::TestPersistentBackend: persistent
# mode (TINA4_DB_CACHE=true) routes the query cache through the unified backend
# (TINA4_DB_CACHE_BACKEND); the DatabaseResult is serialized and reconstructed
# so a second Database instance reads the same cache (cross-instance hit).
RSpec.describe "Persistent DB query cache backend" do
  around(:each) { |example| CacheBackendsSpecEnv.around(example) }

  def reachable?(host, port)
    s = Socket.tcp(host, port, connect_timeout: 1)
    s.close
    true
  rescue StandardError
    false
  end

  def make_db(dir, name = "qc.db")
    db = Tina4::Database.new("sqlite://#{dir}/#{name}")
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)")
    db.execute("INSERT INTO t (n) VALUES ('a'), ('b')")
    db
  end

  it "memory backend reconstructs the DatabaseResult on a hit" do
    Dir.mktmpdir do |dir|
      ENV["TINA4_DB_CACHE"] = "true"
      ENV["TINA4_DB_CACHE_BACKEND"] = "memory"
      ENV.delete("TINA4_AUTO_CACHING")
      db = make_db(dir)
      db.fetch("SELECT * FROM t ORDER BY id")
      r = db.fetch("SELECT * FROM t ORDER BY id") # hit → reconstructed
      expect(r).to be_a(Tina4::DatabaseResult)
      expect(r.count).to eq(2)
      expect(r.map { |row| row[:n] }).to eq(%w[a b])
      expect(db.cache_stats[:mode]).to eq("persistent")
      expect(db.cache_stats[:hits]).to be >= 1
      expect(db.cache_stats[:backend]).to eq("memory")
    end
  end

  it "persistent cache survives a request-boundary reset" do
    Dir.mktmpdir do |dir|
      ENV["TINA4_DB_CACHE"] = "true"
      ENV["TINA4_DB_CACHE_BACKEND"] = "memory"
      ENV.delete("TINA4_AUTO_CACHING")
      db = make_db(dir)
      db.fetch("SELECT * FROM t")
      expect(db.cache_stats[:size]).to eq(1)
      Tina4::Database.reset_request_caches # no-op in persistent mode
      expect(db.cache_stats[:size]).to eq(1)
    end
  end

  it "shares a redis backend across separate Database instances" do
    skip "redis not running" unless reachable?("localhost", 6379)
    ENV["TINA4_DB_CACHE"] = "true"
    ENV["TINA4_DB_CACHE_BACKEND"] = "redis"
    ENV["TINA4_DB_CACHE_URL"] = "redis://localhost:6379/2" # isolation: db index 2
    ENV.delete("TINA4_AUTO_CACHING")
    Dir.mktmpdir do |dir|
      path = "sqlite://#{dir}/shared.db"
      db1 = Tina4::Database.new(path)
      db1.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)")
      db1.execute("INSERT INTO t (n) VALUES ('x'), ('y')")
      db1.cache_clear # clear shared redis
      db1.fetch("SELECT * FROM t ORDER BY id") # populate shared redis
      db2 = Tina4::Database.new(path) # separate instance, same redis
      r = db2.fetch("SELECT * FROM t ORDER BY id") # cross-instance hit (no query)
      stats = db2.cache_stats
      expect(stats[:hits]).to be >= 1
      expect(stats[:misses]).to eq(0)
      expect(r.map { |row| row[:n] }).to eq(%w[x y])
      expect(stats[:backend]).to eq("redis")
      db2.cache_clear
    end
  end
end
