# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Tina4::ResponseCache do
  # ── Construction & Defaults ──────────────────────────────────────

  describe "initialization" do
    it "defaults ttl to 0 (disabled)" do
      cache = described_class.new
      expect(cache.ttl).to eq(0)
    end

    it "defaults max_entries to 1000" do
      cache = described_class.new
      expect(cache.max_entries).to eq(1000)
    end

    it "accepts custom ttl" do
      cache = described_class.new(ttl: 120)
      expect(cache.ttl).to eq(120)
    end

    it "accepts custom max_entries" do
      cache = described_class.new(max_entries: 50)
      expect(cache.max_entries).to eq(50)
    end

    it "reads TINA4_CACHE_TTL from env" do
      ENV["TINA4_CACHE_TTL"] = "300"
      begin
        cache = described_class.new
        expect(cache.ttl).to eq(300)
      ensure
        ENV.delete("TINA4_CACHE_TTL")
      end
    end

    it "reads TINA4_CACHE_MAX_ENTRIES from env" do
      ENV["TINA4_CACHE_MAX_ENTRIES"] = "500"
      begin
        cache = described_class.new
        expect(cache.max_entries).to eq(500)
      ensure
        ENV.delete("TINA4_CACHE_MAX_ENTRIES")
      end
    end

    it "explicit ttl overrides env" do
      ENV["TINA4_CACHE_TTL"] = "300"
      begin
        cache = described_class.new(ttl: 10)
        expect(cache.ttl).to eq(10)
      ensure
        ENV.delete("TINA4_CACHE_TTL")
      end
    end

    it "explicit max_entries overrides env" do
      ENV["TINA4_CACHE_MAX_ENTRIES"] = "500"
      begin
        cache = described_class.new(max_entries: 5)
        expect(cache.max_entries).to eq(5)
      ensure
        ENV.delete("TINA4_CACHE_MAX_ENTRIES")
      end
    end

    it "defaults backend to memory" do
      cache = described_class.new(ttl: 60)
      expect(cache.backend_name).to eq("memory")
    end

    it "reads TINA4_CACHE_BACKEND from env" do
      ENV["TINA4_CACHE_BACKEND"] = "memory"
      begin
        cache = described_class.new(ttl: 60)
        expect(cache.backend_name).to eq("memory")
      ensure
        ENV.delete("TINA4_CACHE_BACKEND")
      end
    end

    it "explicit backend overrides env" do
      ENV["TINA4_CACHE_BACKEND"] = "file"
      begin
        cache = described_class.new(ttl: 60, backend: "memory")
        expect(cache.backend_name).to eq("memory")
      ensure
        ENV.delete("TINA4_CACHE_BACKEND")
      end
    end
  end

  # ── enabled? ─────────────────────────────────────────────────────

  describe "#enabled?" do
    it "is false when ttl is 0" do
      cache = described_class.new(ttl: 0)
      expect(cache.enabled?).to be false
    end

    it "is true when ttl > 0" do
      cache = described_class.new(ttl: 60)
      expect(cache.enabled?).to be true
    end
  end

  # ── Cache Key ────────────────────────────────────────────────────

  describe "#cache_key" do
    it "builds key from method and url" do
      cache = described_class.new(ttl: 60)
      expect(cache.cache_key("GET", "/api/items")).to eq("GET:/api/items")
    end

    it "includes method in the key" do
      cache = described_class.new(ttl: 60)
      expect(cache.cache_key("POST", "/api/items")).to eq("POST:/api/items")
    end
  end

  # ── cache_response / get (hit & miss) ────────────────────────────

  describe "#cache_response and #get" do
    let(:cache) { described_class.new(ttl: 60) }

    it "stores and retrieves a response" do
      cache.cache_response("GET", "/api/data", 200, "application/json", '{"ok": true}')
      hit = cache.get("GET", "/api/data")
      expect(hit).not_to be_nil
      expect(hit.body).to eq('{"ok": true}')
      expect(hit.status_code).to eq(200)
      expect(hit.content_type).to eq("application/json")
    end

    it "returns nil on cache miss" do
      hit = cache.get("GET", "/api/missing")
      expect(hit).to be_nil
    end

    it "only caches GET requests" do
      cache.cache_response("POST", "/api/data", 200, "application/json", "{}")
      hit = cache.get("POST", "/api/data")
      expect(hit).to be_nil
    end

    it "only caches configured status codes" do
      cache.cache_response("GET", "/api/404", 404, "text/html", "Not Found")
      hit = cache.get("GET", "/api/404")
      expect(hit).to be_nil
    end

    it "caches custom status codes when configured" do
      custom_cache = described_class.new(ttl: 60, status_codes: [200, 404])
      custom_cache.cache_response("GET", "/api/404", 404, "text/html", "Not Found")
      hit = custom_cache.get("GET", "/api/404")
      expect(hit).not_to be_nil
      expect(hit.status_code).to eq(404)
    end

    it "does not cache when disabled (ttl=0)" do
      disabled = described_class.new(ttl: 0)
      disabled.cache_response("GET", "/api/data", 200, "application/json", "{}")
      hit = disabled.get("GET", "/api/data")
      expect(hit).to be_nil
    end
  end

  # ── TTL Expiry ───────────────────────────────────────────────────

  describe "TTL expiry" do
    it "entry expires after TTL" do
      cache = described_class.new(ttl: 1)
      cache.cache_response("GET", "/api/expire", 200, "text/plain", "temp")
      expect(cache.get("GET", "/api/expire")).not_to be_nil
      sleep(1.1)
      expect(cache.get("GET", "/api/expire")).to be_nil
    end

    it "supports per-entry TTL override" do
      cache = described_class.new(ttl: 300)
      cache.cache_response("GET", "/api/short", 200, "text/plain", "short", ttl: 1)
      expect(cache.get("GET", "/api/short")).not_to be_nil
      sleep(1.1)
      expect(cache.get("GET", "/api/short")).to be_nil
    end
  end

  # ── LRU Eviction ─────────────────────────────────────────────────

  describe "LRU eviction" do
    it "evicts oldest when full" do
      cache = described_class.new(ttl: 60, max_entries: 2)

      cache.cache_response("GET", "/api/item/0", 200, "text/plain", "item-0")
      cache.cache_response("GET", "/api/item/1", 200, "text/plain", "item-1")
      cache.cache_response("GET", "/api/item/2", 200, "text/plain", "item-2")

      stats = cache.cache_stats
      expect(stats[:size]).to eq(2)

      # First item should be evicted
      expect(cache.get("GET", "/api/item/0")).to be_nil
      # Third item should be cached
      hit = cache.get("GET", "/api/item/2")
      expect(hit).not_to be_nil
      expect(hit.body).to eq("item-2")
    end
  end

  # ── Stats ────────────────────────────────────────────────────────

  describe "#cache_stats" do
    it "returns initial stats with zero values" do
      cache = described_class.new(ttl: 60)
      stats = cache.cache_stats
      expect(stats[:hits]).to eq(0)
      expect(stats[:misses]).to eq(0)
      expect(stats[:size]).to eq(0)
      expect(stats[:backend]).to eq("memory")
    end

    it "tracks misses" do
      cache = described_class.new(ttl: 60)
      cache.get("GET", "/miss")
      stats = cache.cache_stats
      expect(stats[:misses]).to eq(1)
    end

    it "tracks hits" do
      cache = described_class.new(ttl: 60)
      cache.cache_response("GET", "/api/hit", 200, "text/plain", "data")
      cache.get("GET", "/api/hit")  # hit
      stats = cache.cache_stats
      expect(stats[:hits]).to eq(1)
    end

    it "tracks hits and misses together" do
      cache = described_class.new(ttl: 60)
      cache.cache_response("GET", "/api/stats", 200, "text/plain", "data")
      cache.get("GET", "/api/stats")  # hit
      cache.get("GET", "/api/missing")  # miss
      stats = cache.cache_stats
      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(1)
      expect(stats[:size]).to eq(1)
    end
  end

  # ── Clear Cache ──────────────────────────────────────────────────

  describe "#clear_cache" do
    it "resets store and stats" do
      cache = described_class.new(ttl: 60)
      cache.cache_response("GET", "/api/clear", 200, "text/plain", "data")
      cache.get("GET", "/api/clear")  # hit
      cache.get("GET", "/api/miss")   # miss

      cache.clear_cache
      stats = cache.cache_stats
      expect(stats[:hits]).to eq(0)
      expect(stats[:misses]).to eq(0)
      expect(stats[:size]).to eq(0)
    end
  end

  # ── Sweep ────────────────────────────────────────────────────────

  describe "#sweep" do
    it "removes expired entries" do
      cache = described_class.new(ttl: 1)
      cache.cache_response("GET", "/api/sweep", 200, "text/plain", "temp")
      expect(cache.cache_stats[:size]).to eq(1)
      sleep(1.1)
      removed = cache.sweep
      expect(removed).to eq(1)
      expect(cache.cache_stats[:size]).to eq(0)
    end

    it "keeps non-expired entries" do
      cache = described_class.new(ttl: 300)
      cache.cache_response("GET", "/api/keep", 200, "text/plain", "keep")
      removed = cache.sweep
      expect(removed).to eq(0)
      expect(cache.cache_stats[:size]).to eq(1)
    end
  end

  # ── Direct Cache API (cache_set / cache_get / cache_delete) ──────

  describe "direct cache API" do
    let(:cache) { described_class.new(ttl: 60) }

    it "sets and gets a value" do
      cache.cache_set("test_key", { "hello" => "world" }, ttl: 60)
      result = cache.cache_get("test_key")
      expect(result).to eq({ "hello" => "world" })
    end

    it "returns nil for missing key" do
      result = cache.cache_get("nonexistent_key_12345")
      expect(result).to be_nil
    end

    it "deletes a key" do
      cache.cache_set("del_key", "value", ttl: 60)
      expect(cache.cache_delete("del_key")).to be true
      expect(cache.cache_get("del_key")).to be_nil
    end

    it "returns false deleting missing key" do
      expect(cache.cache_delete("never_existed")).to be false
    end

    it "handles TTL expiry on direct API" do
      cache.cache_set("expiring", "data", ttl: 1)
      expect(cache.cache_get("expiring")).to eq("data")
      sleep(1.1)
      expect(cache.cache_get("expiring")).to be_nil
    end

    it "overwrites existing key" do
      cache.cache_set("overwrite", "first", ttl: 60)
      cache.cache_set("overwrite", "second", ttl: 60)
      expect(cache.cache_get("overwrite")).to eq("second")
    end

    it "stores complex values" do
      value = { "users" => [{ "name" => "Alice" }, { "name" => "Bob" }], "count" => 2 }
      cache.cache_set("complex", value, ttl: 60)
      expect(cache.cache_get("complex")).to eq(value)
    end

    it "tracks stats for direct API" do
      cache.cache_set("x", "val", ttl: 60)
      cache.cache_get("x")        # hit
      cache.cache_get("missing")  # miss
      stats = cache.cache_stats
      expect(stats[:hits]).to be >= 1
      expect(stats[:misses]).to be >= 1
    end
  end

  # ── File Backend ─────────────────────────────────────────────────

  describe "file backend" do
    let(:cache_dir) { Dir.mktmpdir("tina4_cache_test") }

    after(:each) do
      FileUtils.rm_rf(cache_dir)
    end

    it "stores and retrieves responses" do
      cache = described_class.new(ttl: 60, backend: "file", cache_dir: cache_dir)
      cache.cache_response("GET", "/api/file", 200, "text/plain", "file data")
      hit = cache.get("GET", "/api/file")
      expect(hit).not_to be_nil
      expect(hit.body).to eq("file data")
    end

    it "returns nil for missing key" do
      cache = described_class.new(ttl: 60, backend: "file", cache_dir: cache_dir)
      hit = cache.get("GET", "/api/nope")
      expect(hit).to be_nil
    end

    it "expires entries after TTL" do
      cache = described_class.new(ttl: 1, backend: "file", cache_dir: cache_dir)
      cache.cache_response("GET", "/api/expire", 200, "text/plain", "temp")
      expect(cache.get("GET", "/api/expire")).not_to be_nil
      sleep(1.1)
      expect(cache.get("GET", "/api/expire")).to be_nil
    end

    it "deletes entries" do
      cache = described_class.new(ttl: 60, backend: "file", cache_dir: cache_dir)
      cache.cache_set("del", "val", ttl: 60)
      expect(cache.cache_delete("del")).to be true
      expect(cache.cache_get("del")).to be_nil
      expect(cache.cache_delete("del")).to be false
    end

    it "clears all entries" do
      cache = described_class.new(ttl: 60, backend: "file", cache_dir: cache_dir)
      cache.cache_set("a", 1, ttl: 60)
      cache.cache_set("b", 2, ttl: 60)
      cache.clear_cache
      stats = cache.cache_stats
      expect(stats[:size]).to eq(0)
    end

    it "reports backend as file" do
      cache = described_class.new(ttl: 60, backend: "file", cache_dir: cache_dir)
      stats = cache.cache_stats
      expect(stats[:backend]).to eq("file")
    end

    it "sweeps expired file entries" do
      cache = described_class.new(ttl: 1, backend: "file", cache_dir: cache_dir)
      cache.cache_response("GET", "/api/sweep", 200, "text/plain", "temp")
      sleep(1.1)
      removed = cache.sweep
      expect(removed).to eq(1)
    end
  end

  # ── Module-Level Singleton ───────────────────────────────────────

  describe "module-level convenience" do
    before(:each) do
      Tina4.instance_variable_set(:@default_cache, nil)
    end

    after(:each) do
      Tina4.instance_variable_set(:@default_cache, nil)
    end

    it "cache_set and cache_get work via Tina4 singleton" do
      Tina4.cache_set("mod_key", { "test" => true }, ttl: 60)
      result = Tina4.cache_get("mod_key")
      expect(result).to eq({ "test" => true })
    end

    it "cache_delete works via singleton" do
      Tina4.cache_set("mod_del", "value", ttl: 60)
      expect(Tina4.cache_delete("mod_del")).to be true
      expect(Tina4.cache_get("mod_del")).to be_nil
    end

    it "cache_clear works via singleton" do
      Tina4.cache_set("mod_a", 1, ttl: 60)
      Tina4.cache_set("mod_b", 2, ttl: 60)
      Tina4.cache_clear
      stats = Tina4.cache_stats
      expect(stats[:size]).to eq(0)
    end

    it "cache_stats works via singleton" do
      stats = Tina4.cache_stats
      expect(stats).to include(:hits, :misses, :size, :backend)
      expect(stats[:backend]).to eq("memory")
    end

    it "singleton creates same instance each time" do
      c1 = Tina4.cache_instance
      c2 = Tina4.cache_instance
      expect(c1).to equal(c2)
    end
  end

  # ── Thread Safety ────────────────────────────────────────────────

  describe "thread safety" do
    it "handles concurrent reads and writes without errors" do
      cache = described_class.new(ttl: 60, max_entries: 100)
      errors = []
      threads = []

      20.times do |i|
        threads << Thread.new do
          begin
            cache.cache_response("GET", "/api/thread/#{i}", 200, "text/plain", "val-#{i}")
          rescue StandardError => e
            errors << e
          end
        end
        threads << Thread.new do
          begin
            cache.get("GET", "/api/thread/#{i}")
          rescue StandardError => e
            errors << e
          end
        end
      end

      threads.each { |t| t.join(5) }
      expect(errors).to be_empty
      expect(cache.cache_stats[:size]).to be <= 100
    end
  end

  # ── Non-GET Methods ──────────────────────────────────────────────

  describe "non-GET methods" do
    %w[POST PUT PATCH DELETE].each do |method|
      it "does not cache #{method} requests" do
        cache = described_class.new(ttl: 60)
        cache.cache_response(method, "/api/write", 200, "text/plain", "data")
        hit = cache.get(method, "/api/write")
        expect(hit).to be_nil
      end
    end
  end
end
