# frozen_string_literal: true

require_relative "cache_backends/base_backend"
require_relative "cache_backends/memory_backend"
require_relative "cache_backends/file_backend"
require_relative "cache_backends/redis_backend"
require_relative "cache_backends/valkey_backend"
require_relative "cache_backends/memcached_backend"
require_relative "cache_backends/mongo_backend"
require_relative "cache_backends/database_backend"

module Tina4
  # Unified cache backend family (parity with Python tina4_python.cache).
  #
  # Backends are key/value stores with TTL semantics, selected via env vars:
  #
  #   memory    — in-process LRU cache (default, zero deps)
  #   file      — JSON files in data/cache/
  #   redis     — Redis (redis gem or raw RESP over TCP)
  #   valkey    — Valkey (Redis wire protocol; reports "valkey")
  #   memcached — Memcached (zero-dep text protocol over TCP)
  #   mongodb   — MongoDB TTL collection (requires the mongo gem)
  #   database  — tina4_cache table in any Tina4-supported database
  #
  # Environment:
  #   TINA4_CACHE_BACKEND     — memory|file|redis|valkey|memcached|mongodb|database
  #   TINA4_CACHE_URL         — connection URL (redis/valkey/memcached/mongo) OR
  #                             SQL URL for database (falls back to TINA4_DATABASE_URL)
  #   TINA4_CACHE_TTL         — default TTL in seconds (default: 60)
  #   TINA4_CACHE_MAX_ENTRIES — max cached entries (default: 1000)
  #   TINA4_CACHE_DIR         — file backend directory (default: data/cache)
  #   TINA4_CACHE_USERNAME / TINA4_CACHE_PASSWORD — credentials when not in the URL
  module CacheBackends
    module_function

    # Create a cache backend from explicit params or env vars.
    #
    # Graceful degradation: if the configured backend's driver is missing or its
    # service is unreachable, the factory logs a warning and falls back to the
    # file backend (persistent, zero-dep, always available) — never a silent
    # no-op cache.
    #
    # @param backend [String, nil]
    # @param url [String, nil]
    # @param max_entries [Integer, nil]
    # @param cache_dir [String, nil]
    # @return [Tina4::CacheBackends::BaseBackend]
    def create_backend(backend: nil, url: nil, max_entries: nil, cache_dir: nil)
      backend ||= ENV.fetch("TINA4_CACHE_BACKEND", "memory")
      max_entries ||= (ENV["TINA4_CACHE_MAX_ENTRIES"] || "1000").to_i
      backend = backend.to_s.downcase.strip

      be =
        case backend
        when "redis"
          RedisBackend.new(url: url || ENV.fetch("TINA4_CACHE_URL", "redis://localhost:6379"),
                           max_entries: max_entries)
        when "valkey"
          ValkeyBackend.new(url: url || ENV.fetch("TINA4_CACHE_URL", "valkey://localhost:6379"),
                            max_entries: max_entries)
        when "memcached", "memcache"
          MemcachedBackend.new(url: url || ENV.fetch("TINA4_CACHE_URL", "memcached://localhost:11211"),
                               max_entries: max_entries)
        when "mongodb", "mongo"
          MongoBackend.new(url: url || ENV.fetch("TINA4_CACHE_URL", "mongodb://localhost:27017"),
                           max_entries: max_entries)
        when "database", "db"
          DatabaseBackend.new(url: url, max_entries: max_entries)
        when "file"
          dir = cache_dir || ENV.fetch("TINA4_CACHE_DIR", "data/cache")
          return FileBackend.new(cache_dir: dir, max_entries: max_entries)
        else
          return MemoryBackend.new(max_entries: max_entries)
        end

      return be if be.available?

      # Configured backend unusable — degrade to the file backend.
      begin
        Tina4::Log.warning(
          "Cache backend '#{backend}' is unavailable " \
          "(driver missing or service unreachable) — falling back to 'file'."
        )
      rescue StandardError
        # Logging must never break cache construction.
      end
      dir = cache_dir || ENV.fetch("TINA4_CACHE_DIR", "data/cache")
      FileBackend.new(cache_dir: dir, max_entries: max_entries)
    end
  end
end
