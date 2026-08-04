# frozen_string_literal: true
require "json"
require_relative "resp_client"

module Tina4
  module SessionHandlers
    # Valkey-backed session handler. Valkey speaks the RESP protocol, so it works
    # through the `redis` gem when installed (parity with Python/Node); otherwise
    # it speaks raw RESP over a TCP socket via RespClient — zero dependencies.
    # Same as RedisHandler but reads VALKEY-prefixed configuration variables.
    class ValkeyHandler
      def initialize(options = {})
        @prefix = options[:prefix] || ENV["TINA4_SESSION_VALKEY_PREFIX"] || "tina4:session:"
        # TINA4_SESSION_VALKEY_TTL stays as the valkey-specific override, but it
        # now falls back to TINA4_SESSION_TTL - the ONE session-lifetime variable
        # every backend must honour (ADR-0024) - instead of a hard-coded 86400.
        # 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_VALKEY_TTL"] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @host = options[:host] || ENV["TINA4_SESSION_VALKEY_HOST"] || "localhost"
        @port = options[:port] || (ENV["TINA4_SESSION_VALKEY_PORT"] ? ENV["TINA4_SESSION_VALKEY_PORT"].to_i : 6379)
        @db = options[:db] || (ENV["TINA4_SESSION_VALKEY_DB"] ? ENV["TINA4_SESSION_VALKEY_DB"].to_i : 0)
        @password = options[:password] || ENV["TINA4_SESSION_VALKEY_PASSWORD"]
        @redis = build_gem_client
        @resp = @redis ? nil : RespClient.new(host: @host, port: @port, password: @password, db: @db)
      end

      def read(session_id)
        key = "#{@prefix}#{session_id}"
        data = @redis ? @redis.get(key) : @resp.get(key)
        return nil unless data
        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      # Write session data. A per-call +ttl+ WINS over the handler default, so
      # asking for a 60s session really gets 60s; 0 uses the default. Every
      # handler in every Tina4 framework takes this third argument -- Session#write
      # passes it, and a handler that did not accept it raised ArgumentError,
      # which safe_write swallowed into a silent STALE write.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        key = "#{@prefix}#{session_id}"
        payload = JSON.generate(data)
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        if @redis
          @redis.setex(key, effective_ttl, payload)
        else
          @resp.setex(key, effective_ttl, payload)
        end
      end

      def destroy(session_id)
        key = "#{@prefix}#{session_id}"
        @redis ? @redis.del(key) : @resp.del(key)
      end

      def cleanup
        # Valkey handles TTL automatically (same as Redis)
      end

      private

      # Use the official `redis` gem (RESP-compatible with Valkey) only when the
      # REAL gem is loadable; otherwise nil so the caller falls back to raw RESP.
      def build_gem_client
        require "redis"
        return nil unless defined?(::Redis::VERSION)
        Redis.new(host: @host, port: @port, db: @db, password: @password)
      rescue LoadError
        nil
      end
    end
  end
end
