# frozen_string_literal: true

require "json"
require "uri"
require_relative "base_backend"

module Tina4
  module CacheBackends
    # MongoDB backend backed by a TTL collection (parity with Python
    # _MongoBackend). Requires the `mongo` gem — reuses the same connection
    # style as the Mongo session handler. The cache lives in collection
    # tina4_cache with a TTL index on expires_at. The database name is taken
    # from the URL path (mongodb://host:27017/<db>) or defaults to tina4_cache.
    class MongoBackend < BaseBackend
      def initialize(url: "mongodb://localhost:27017", max_entries: 1000)
        @max_entries = max_entries
        @hits = 0
        @misses = 0
        @coll = nil
        begin
          require "mongo"
          Mongo::Logger.logger.level = Logger::FATAL if defined?(Mongo::Logger)
          db_name = database_from_url(url)
          client_opts = { server_selection_timeout: 5, database: db_name }
          # Credentials from env when not embedded in the URL (parity with DB layer).
          unless url.include?("@")
            mu = env_nonempty("TINA4_CACHE_USERNAME")
            mp = env_nonempty("TINA4_CACHE_PASSWORD")
            client_opts[:user] = mu if mu
            client_opts[:password] = mp if mp
          end
          client = Mongo::Client.new(url, **client_opts)
          @coll = client[:tina4_cache]
          @coll.indexes.create_one({ expires_at: 1 }, expire_after: 0)
          client.database.command(ping: 1)
        rescue LoadError, StandardError
          @coll = nil
        end
      end

      def available?
        !@coll.nil?
      end

      def get(key)
        if @coll.nil?
          @misses += 1
          return nil
        end
        begin
          doc = @coll.find(_id: key).first
          unless doc
            @misses += 1
            return nil
          end
          exp = doc["expires_at"]
          if exp && exp < Time.now.utc
            @coll.delete_one(_id: key)
            @misses += 1
            return nil
          end
          @hits += 1
          JSON.parse(doc["value"])
        rescue StandardError
          @misses += 1
          nil
        end
      end

      def set(key, value, ttl)
        return if @coll.nil?

        begin
          doc = { _id: key, value: JSON.generate(value) }
          doc[:expires_at] = Time.now.utc + ttl if ttl > 0
          @coll.replace_one({ _id: key }, doc, upsert: true)
        rescue StandardError
        end
      end

      def delete(key)
        return false if @coll.nil?

        begin
          @coll.delete_one(_id: key).deleted_count > 0
        rescue StandardError
          false
        end
      end

      def clear
        @hits = 0
        @misses = 0
        return if @coll.nil?

        begin
          @coll.delete_many({})
        rescue StandardError
        end
      end

      def stats
        size = 0
        unless @coll.nil?
          begin
            size = @coll.count_documents({})
          rescue StandardError
          end
        end
        { hits: @hits, misses: @misses, size: size, backend: "mongodb" }
      end

      def name
        "mongodb"
      end

      private

      def env_nonempty(key)
        v = ENV[key]
        v && !v.empty? ? v : nil
      end

      def database_from_url(url)
        uri = URI.parse(url)
        path = (uri.path || "").sub(%r{^/}, "")
        path.empty? ? "tina4_cache" : path
      rescue URI::InvalidURIError
        "tina4_cache"
      end
    end
  end
end
