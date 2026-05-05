# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Public surface (parity with Python tina4_python.cache):
#   - Tina4::ResponseCache class — middleware-only public API
#   - Tina4.cache_stats / Tina4.clear_cache / Tina4.cache_get/set/delete
#
# Internal lookup/store of GET responses is performed by middleware hooks and
# is NOT public. These tests use the @internal `_internal_lookup` /
# `_internal_store` test seams that exercise the same code paths.

RSpec.describe Tina4::ResponseCache do
  describe "with caching enabled" do
    let(:cache) { Tina4::ResponseCache.new(ttl: 60, max_entries: 3) }

    it "caches GET responses" do
      cache._internal_store("GET", "/api/users", 200, "application/json", '{"users":[]}')
      stats = cache.cache_stats
      expect(stats[:size]).to eq(1)
    end

    it "returns cached response on hit" do
      cache._internal_store("GET", "/api/users", 200, "application/json", '{"users":[]}')
      entry = cache._internal_lookup("GET", "/api/users")
      expect(entry).not_to be_nil
      expect(entry.body).to eq('{"users":[]}')
      expect(entry.content_type).to eq("application/json")
      expect(entry.status_code).to eq(200)
    end

    it "returns nil on cache miss" do
      entry = cache._internal_lookup("GET", "/api/unknown")
      expect(entry).to be_nil
    end

    it "does not cache non-GET methods" do
      cache._internal_store("POST", "/api/users", 200, "application/json", '{}')
      entry = cache._internal_lookup("POST", "/api/users")
      expect(entry).to be_nil
      expect(cache.cache_stats[:size]).to eq(0)
    end

    it "does not return cached data for non-GET requests" do
      cache._internal_store("GET", "/api/users", 200, "application/json", '{}')
      entry = cache._internal_lookup("POST", "/api/users")
      expect(entry).to be_nil
    end

    it "expires entries after TTL" do
      ttl_cache = Tina4::ResponseCache.new(ttl: 1, max_entries: 10)
      ttl_cache._internal_store("GET", "/test", 200, "text/plain", "hello", ttl: 0)
      sleep(0.01)
      entry = ttl_cache._internal_lookup("GET", "/test")
      expect(entry).to be_nil
    end

    it "evicts oldest entry at max_entries via LRU" do
      cache._internal_store("GET", "/a", 200, "text/plain", "a")
      cache._internal_store("GET", "/b", 200, "text/plain", "b")
      cache._internal_store("GET", "/c", 200, "text/plain", "c")
      cache._internal_store("GET", "/d", 200, "text/plain", "d") # Should evict /a
      expect(cache._internal_lookup("GET", "/a")).to be_nil
      expect(cache._internal_lookup("GET", "/d")).not_to be_nil
      expect(cache.cache_stats[:size]).to eq(3)
    end

    it "only caches configured status codes" do
      cache._internal_store("GET", "/error", 404, "text/html", "Not Found")
      expect(cache.cache_stats[:size]).to eq(0)
    end

    it "caches custom status codes when configured" do
      custom_cache = Tina4::ResponseCache.new(ttl: 60, status_codes: [200, 301])
      custom_cache._internal_store("GET", "/redirect", 301, "text/html", "Moved")
      expect(custom_cache.cache_stats[:size]).to eq(1)
    end

    describe "#cache_stats" do
      it "returns correct size and keys" do
        cache._internal_store("GET", "/a", 200, "text/plain", "a")
        cache._internal_store("GET", "/b", 200, "text/plain", "b")
        stats = cache.cache_stats
        expect(stats[:size]).to eq(2)
        expect(stats[:keys]).to include("GET:/a")
        expect(stats[:keys]).to include("GET:/b")
      end

      it "includes backend field" do
        stats = cache.cache_stats
        expect(stats[:backend]).to eq("memory")
      end
    end

    describe "#clear_cache" do
      it "resets everything" do
        cache._internal_store("GET", "/a", 200, "text/plain", "a")
        cache._internal_store("GET", "/b", 200, "text/plain", "b")
        cache.clear_cache
        expect(cache.cache_stats[:size]).to eq(0)
        expect(cache._internal_lookup("GET", "/a")).to be_nil
      end
    end

    describe "#sweep" do
      it "removes expired entries" do
        ttl_cache = Tina4::ResponseCache.new(ttl: 60, max_entries: 10)
        ttl_cache._internal_store("GET", "/expired", 200, "text/plain", "old", ttl: 0)
        ttl_cache._internal_store("GET", "/fresh", 200, "text/plain", "new", ttl: 60)
        sleep(0.01)
        removed = ttl_cache.sweep
        expect(removed).to eq(1)
        expect(ttl_cache._internal_lookup("GET", "/fresh")).not_to be_nil
      end
    end
  end

  describe "with caching disabled (ttl: 0)" do
    let(:cache) { Tina4::ResponseCache.new(ttl: 0) }

    it "reports enabled? as false" do
      expect(cache.enabled?).to be false
    end

    it "does not cache anything" do
      cache._internal_store("GET", "/test", 200, "text/plain", "hello")
      expect(cache._internal_lookup("GET", "/test")).to be_nil
    end
  end

  describe "environment config" do
    it "reads TTL from TINA4_CACHE_TTL env var" do
      original = ENV["TINA4_CACHE_TTL"]
      begin
        ENV["TINA4_CACHE_TTL"] = "120"
        cache = Tina4::ResponseCache.new
        expect(cache.ttl).to eq(120)
        expect(cache.enabled?).to be true
      ensure
        if original
          ENV["TINA4_CACHE_TTL"] = original
        else
          ENV.delete("TINA4_CACHE_TTL")
        end
      end
    end

    it "defaults to 0 (disabled) when env var not set" do
      original = ENV["TINA4_CACHE_TTL"]
      begin
        ENV.delete("TINA4_CACHE_TTL")
        cache = Tina4::ResponseCache.new
        expect(cache.ttl).to eq(0)
        expect(cache.enabled?).to be false
      ensure
        ENV["TINA4_CACHE_TTL"] = original if original
      end
    end
  end

  # ── Backend selection ───────────────────────────────────────────

  describe "backend selection" do
    it "defaults to memory backend" do
      cache = Tina4::ResponseCache.new(ttl: 60)
      expect(cache.backend_name).to eq("memory")
    end

    it "selects memory via explicit param" do
      cache = Tina4::ResponseCache.new(ttl: 60, backend: "memory")
      expect(cache.backend_name).to eq("memory")
    end

    it "selects file via explicit param" do
      dir = Dir.mktmpdir("tina4_cache_test")
      begin
        cache = Tina4::ResponseCache.new(ttl: 60, backend: "file", cache_dir: dir)
        expect(cache.backend_name).to eq("file")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "selects backend from TINA4_CACHE_BACKEND env var" do
      original = ENV["TINA4_CACHE_BACKEND"]
      begin
        ENV["TINA4_CACHE_BACKEND"] = "memory"
        cache = Tina4::ResponseCache.new(ttl: 60)
        expect(cache.backend_name).to eq("memory")
      ensure
        if original
          ENV["TINA4_CACHE_BACKEND"] = original
        else
          ENV.delete("TINA4_CACHE_BACKEND")
        end
      end
    end

    it "explicit param overrides env var" do
      original = ENV["TINA4_CACHE_BACKEND"]
      begin
        ENV["TINA4_CACHE_BACKEND"] = "file"
        cache = Tina4::ResponseCache.new(ttl: 60, backend: "memory")
        expect(cache.backend_name).to eq("memory")
      ensure
        if original
          ENV["TINA4_CACHE_BACKEND"] = original
        else
          ENV.delete("TINA4_CACHE_BACKEND")
        end
      end
    end
  end

  # ── Direct cache API ────────────────────────────────────────────

  describe "direct cache API" do
    let(:cache) { Tina4::ResponseCache.new(ttl: 60) }

    it "cache_set and cache_get work" do
      cache.cache_set("test_key", { "hello" => "world" }, ttl: 60)
      result = cache.cache_get("test_key")
      expect(result).to eq({ "hello" => "world" })
    end

    it "cache_get returns nil for missing key" do
      expect(cache.cache_get("nonexistent_key_12345")).to be_nil
    end

    it "cache_delete removes a key" do
      cache.cache_set("del_key", "value", ttl: 60)
      expect(cache.cache_delete("del_key")).to be true
      expect(cache.cache_get("del_key")).to be_nil
      expect(cache.cache_delete("del_key")).to be false
    end

    it "cache_stats includes backend field" do
      stats = cache.cache_stats
      expect(stats[:backend]).to eq("memory")
    end
  end

  # ── Module-level API (parity with Python) ───────────────────────

  describe "module-level Tina4 API" do
    it "Tina4.cache_stats returns stats hash" do
      stats = Tina4.cache_stats
      expect(stats).to include(:hits, :misses, :size, :backend)
    end

    it "Tina4.clear_cache flushes the singleton" do
      Tina4.cache_set("module_key", "module_value")
      expect(Tina4.cache_get("module_key")).to eq("module_value")
      Tina4.clear_cache
      expect(Tina4.cache_get("module_key")).to be_nil
    end

    it "Tina4.cache_get/set/delete round-trips" do
      Tina4.cache_set("round_key", { "data" => 1 })
      expect(Tina4.cache_get("round_key")).to eq({ "data" => 1 })
      expect(Tina4.cache_delete("round_key")).to be true
      expect(Tina4.cache_get("round_key")).to be_nil
    end
  end

  # ── File backend ────────────────────────────────────────────────

  describe "file backend" do
    it "stores and retrieves via file backend" do
      dir = Dir.mktmpdir("tina4_cache_file_test")
      begin
        cache = Tina4::ResponseCache.new(ttl: 60, backend: "file", cache_dir: dir)

        cache._internal_store("GET", "/file-test", 200, "text/plain", "file-data")
        entry = cache._internal_lookup("GET", "/file-test")
        expect(entry).not_to be_nil
        expect(entry.body).to eq("file-data")

        cache.clear_cache
        expect(cache._internal_lookup("GET", "/file-test")).to be_nil
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "direct API works with file backend" do
      dir = Dir.mktmpdir("tina4_cache_file_direct_test")
      begin
        cache = Tina4::ResponseCache.new(ttl: 60, backend: "file", cache_dir: dir)

        cache.cache_set("file_key", { "data" => true }, ttl: 60)
        result = cache.cache_get("file_key")
        expect(result).to eq({ "data" => true })

        cache.cache_delete("file_key")
        expect(cache.cache_get("file_key")).to be_nil
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
