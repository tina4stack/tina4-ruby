# frozen_string_literal: true
require "json"

module Tina4
  module SessionHandlers
    class RedisHandler
      def initialize(options = {})
        require "redis"
        @prefix = options[:prefix] || "tina4:session:"
        @ttl = options[:ttl] || 86400
        @redis = Redis.new(
          host: options[:host] || "localhost",
          port: options[:port] || 6379,
          db: options[:db] || 0,
          password: options[:password]
        )
      rescue LoadError
        raise "Redis session handler requires the 'redis' gem. Install with: gem install redis"
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
        # Redis handles TTL automatically
      end
    end
  end
end
