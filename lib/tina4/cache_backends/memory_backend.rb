# frozen_string_literal: true

require_relative "base_backend"

module Tina4
  module CacheBackends
    # Thread-safe in-memory LRU cache with TTL (parity with Python
    # _MemoryBackend). Default backend — zero dependencies.
    class MemoryBackend < BaseBackend
      def initialize(max_entries: 1000)
        @max_entries = max_entries
        @store = {} # key => [value, expires_at] ; Ruby Hash preserves insertion order
        @mutex = Mutex.new
        @hits = 0
        @misses = 0
      end

      def get(key)
        @mutex.synchronize do
          entry = @store[key]
          if entry.nil?
            @misses += 1
            return nil
          end
          value, expires_at = entry
          if expires_at && monotonic > expires_at
            @store.delete(key)
            @misses += 1
            return nil
          end
          @hits += 1
          # Move to end (most recently used)
          @store.delete(key)
          @store[key] = entry
          value
        end
      end

      def set(key, value, ttl)
        @mutex.synchronize do
          expires_at = ttl > 0 ? monotonic + ttl : nil
          @store.delete(key)
          @store[key] = [value, expires_at]
          while @store.size > @max_entries
            @store.delete(@store.keys.first)
          end
        end
      end

      def delete(key)
        @mutex.synchronize { !@store.delete(key).nil? }
      end

      def clear
        @mutex.synchronize do
          @store.clear
          @hits = 0
          @misses = 0
        end
      end

      def stats
        @mutex.synchronize do
          now = monotonic
          @store.reject! { |_k, (_v, exp)| exp && now > exp }
          { hits: @hits, misses: @misses, size: @store.size, backend: "memory" }
        end
      end

      def name
        "memory"
      end

      # Evict expired entries and return how many went.
      #
      # An entry stored with ttl <= 0 has expires_at nil - the no-expiry
      # sentinel - and the nil check is what keeps a permanent entry off the
      # eviction list. Dropping it would evict every permanent entry on the
      # first sweep, silently, and report it as a successful reclaim.
      def sweep
        @mutex.synchronize do
          now = monotonic
          before = @store.size
          @store.reject! { |_k, (_value, expires_at)| expires_at && now > expires_at }
          before - @store.size
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
