# frozen_string_literal: true

require "json"
require_relative "base_backend"

module Tina4
  module CacheBackends
    # Database backend (parity with Python _DatabaseBackend) — stores entries in
    # a tina4_cache table in any Tina4-supported database. Zero extra
    # infrastructure; reuses the Database layer. Its own connection has query
    # caching disabled to avoid recursion (a cache lookup must not itself try to
    # cache through this same backend).
    class DatabaseBackend < BaseBackend
      def initialize(url: nil, max_entries: 1000)
        @max_entries = max_entries
        @hits = 0
        @misses = 0
        @db = nil
        @available = false

        # The database backend reads TINA4_CACHE_URL (interpreted as a SQL URL),
        # falling back to the app's own TINA4_DATABASE_URL — cache in the DB you
        # already run, no extra connection var needed.
        url ||= env_nonempty("TINA4_CACHE_URL") ||
                env_nonempty("TINA4_DATABASE_URL") ||
                "sqlite://data/tina4.db"

        # The cache's own DB connection must not itself cache (no recursion).
        prev_auto = ENV["TINA4_AUTO_CACHING"]
        prev_db = ENV["TINA4_DB_CACHE"]
        ENV["TINA4_AUTO_CACHING"] = "false"
        ENV["TINA4_DB_CACHE"] = "false"
        begin
          @db = Tina4::Database.new(url)
          @db.execute(
            "CREATE TABLE IF NOT EXISTS tina4_cache " \
            "(cache_key VARCHAR(255) PRIMARY KEY, value TEXT, expires_at DOUBLE PRECISION)"
          )
          @available = true
        rescue StandardError
          @available = false
        ensure
          restore_env("TINA4_AUTO_CACHING", prev_auto)
          restore_env("TINA4_DB_CACHE", prev_db)
        end
      end

      def available?
        @available
      end

      def get(key)
        row = @db.fetch_one("SELECT value, expires_at FROM tina4_cache WHERE cache_key = ?", [key])
        unless row
          @misses += 1
          return nil
        end
        exp = row["expires_at"] || row[:expires_at]
        if exp && exp.to_f > 0 && Time.now.to_f > exp.to_f
          @db.execute("DELETE FROM tina4_cache WHERE cache_key = ?", [key])
          @misses += 1
          return nil
        end
        @hits += 1
        raw = row["value"] || row[:value]
        begin
          JSON.parse(raw)
        rescue JSON::ParserError, TypeError
          raw
        end
      end

      def set(key, value, ttl)
        exp = ttl > 0 ? Time.now.to_f + ttl : 0
        serialized = JSON.generate(value)
        @db.execute("DELETE FROM tina4_cache WHERE cache_key = ?", [key])
        @db.execute(
          "INSERT INTO tina4_cache (cache_key, value, expires_at) VALUES (?, ?, ?)",
          [key, serialized, exp]
        )
      end

      def delete(key)
        existed = !@db.fetch_one("SELECT 1 AS x FROM tina4_cache WHERE cache_key = ?", [key]).nil?
        @db.execute("DELETE FROM tina4_cache WHERE cache_key = ?", [key])
        existed
      end

      def clear
        @hits = 0
        @misses = 0
        @db.execute("DELETE FROM tina4_cache")
      end

      def stats
        row = @db.fetch_one("SELECT COUNT(*) AS c FROM tina4_cache")
        c = row ? (row["c"] || row[:c]) : 0
        { hits: @hits, misses: @misses, size: c.to_i, backend: "database" }
      end

      def name
        "database"
      end

      private

      def env_nonempty(key)
        v = ENV[key]
        v && !v.empty? ? v : nil
      end

      def restore_env(key, value)
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end
  end
end
