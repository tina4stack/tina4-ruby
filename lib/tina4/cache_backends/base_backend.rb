# frozen_string_literal: true

module Tina4
  module CacheBackends
    # Abstract cache backend (parity with Python _CacheBackend).
    #
    # A backend is a key/value store with TTL semantics and stats. Values are
    # arbitrary JSON-serialisable objects; backends round-trip them through JSON
    # for the network/file/db tiers so a value stored by one process can be read
    # by another. The factory (Tina4::CacheBackends.create_backend) picks the
    # right implementation from env vars and falls back to the file backend when
    # a configured network/driver backend is unreachable.
    class BaseBackend
      # @param key [String]
      # @return [Object, nil] cached value or nil on miss/expiry
      def get(_key)
        raise NotImplementedError
      end

      # @param key [String]
      # @param value [Object]
      # @param ttl [Integer] seconds; <= 0 means no expiry
      def set(_key, _value, _ttl)
        raise NotImplementedError
      end

      # @param key [String]
      # @return [Boolean] true if the key existed
      def delete(_key)
        raise NotImplementedError
      end

      # Remove all entries owned by this cache.
      def clear
        raise NotImplementedError
      end

      # @return [Hash] { hits:, misses:, size:, backend: }
      def stats
        raise NotImplementedError
      end

      # @return [String] backend name reported in stats
      def name
        raise NotImplementedError
      end

      # Whether this backend is actually usable (driver present + service
      # reachable). Local backends are always available; network/driver backends
      # override this so the factory can fall back to the file backend.
      #
      # @return [Boolean]
      def available?
        true
      end
    end
  end
end
