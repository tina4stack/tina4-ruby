# frozen_string_literal: true
require "json"
require_relative "resp_client"

module Tina4
  module SessionHandlers
    # Redis-backed session handler. Prefers the `redis` gem when it is installed
    # (parity with Python, which prefers redis-py the same way, INSIDE this one
    # handler rather than as a separate backend name — Node's `redis-npm`
    # backend did the latter and was retired 2026-07-31 as drift); otherwise
    # speaks raw RESP over a TCP socket via RespClient — zero dependencies, so a
    # Tina4 app stores sessions in Redis with no extra gem.
    class RedisHandler
      # Connection is configured from TINA4_SESSION_REDIS_* env vars (parity with
      # Python's RedisSessionHandler and the Ruby ValkeyHandler shape) so
      # TINA4_SESSION_BACKEND=redis can actually be pointed at a server by env.
      # An explicit constructor option always wins over the environment.
      def initialize(options = {})
        @prefix = options[:prefix] || "tina4:session:"
        @ttl = options[:ttl] || 86400
        @host = options[:host] || ENV["TINA4_SESSION_REDIS_HOST"] || "localhost"
        @port = options[:port] || (ENV["TINA4_SESSION_REDIS_PORT"] ? ENV["TINA4_SESSION_REDIS_PORT"].to_i : 6379)
        @db = options[:db] || (ENV["TINA4_SESSION_REDIS_DB"] ? ENV["TINA4_SESSION_REDIS_DB"].to_i : 0)
        @password = options[:password] || ENV["TINA4_SESSION_REDIS_PASSWORD"]
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
        # Redis handles TTL automatically
      end

      private

      # Use the official `redis` gem only when the REAL gem is loadable (guard
      # against an in-test fake `Redis` constant that has no VERSION). Returns nil
      # when the gem is absent so the caller falls back to the raw RESP client.
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
