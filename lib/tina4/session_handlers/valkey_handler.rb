# frozen_string_literal: true
require "json"

module Tina4
  module SessionHandlers
    class ValkeyHandler
      def initialize(options = {})
        require "redis"
        @prefix = options[:prefix] || ENV["TINA4_SESSION_VALKEY_PREFIX"] || "tina4:session:"
        @ttl = options[:ttl] || (ENV["TINA4_SESSION_VALKEY_TTL"] ? ENV["TINA4_SESSION_VALKEY_TTL"].to_i : 86400)
        @redis = Redis.new(
          host: options[:host] || ENV["TINA4_SESSION_VALKEY_HOST"] || "localhost",
          port: options[:port] || (ENV["TINA4_SESSION_VALKEY_PORT"] ? ENV["TINA4_SESSION_VALKEY_PORT"].to_i : 6379),
          db: options[:db] || (ENV["TINA4_SESSION_VALKEY_DB"] ? ENV["TINA4_SESSION_VALKEY_DB"].to_i : 0),
          password: options[:password] || ENV["TINA4_SESSION_VALKEY_PASSWORD"]
        )
      rescue LoadError
        raise "Valkey session handler requires the 'redis' gem (Valkey uses the RESP protocol). Install with: gem install redis"
      end

      def read(session_id)
        data = @redis.get("#{@prefix}#{session_id}")
        return nil unless data
        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      def write(session_id, data)
        key = "#{@prefix}#{session_id}"
        @redis.setex(key, @ttl, JSON.generate(data))
      end

      def destroy(session_id)
        @redis.del("#{@prefix}#{session_id}")
      end

      def cleanup
        # Valkey handles TTL automatically (same as Redis)
      end
    end
  end
end
