# frozen_string_literal: true

require_relative "redis_backend"

module Tina4
  module CacheBackends
    # Valkey backend (parity with Python _ValkeyBackend). Valkey speaks the
    # Redis wire protocol, so it reuses the Redis client / raw-RESP transport
    # and only reports a different name.
    class ValkeyBackend < RedisBackend
      def initialize(url: "valkey://localhost:6379", max_entries: 1000)
        super(url: url.sub(%r{^valkey://}, "redis://"), max_entries: max_entries, name: "valkey")
      end
    end
  end
end
