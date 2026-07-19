# frozen_string_literal: true
require "json"

module Tina4
  module SessionHandlers
    class MongoHandler
      # Connection is configured from TINA4_SESSION_MONGO_* env vars (parity with
      # Python's MongoDBSessionHandler) so TINA4_SESSION_BACKEND=mongodb can be
      # pointed at a server by env. TINA4_SESSION_MONGO_URI is canonical;
      # TINA4_SESSION_MONGO_URL is a legacy alias. The database default is
      # "tina4" (Python's default — Ruby previously drifted to "tina4_sessions").
      # An explicit constructor option always wins over the environment.
      def initialize(options = {})
        require "mongo"
        @ttl = options[:ttl] || 86400
        @uri = options[:uri] || ENV["TINA4_SESSION_MONGO_URI"] || ENV["TINA4_SESSION_MONGO_URL"] || "mongodb://localhost:27017"
        @database = options[:database] || ENV["TINA4_SESSION_MONGO_DB"] || "tina4"
        @collection_name = options[:collection] || ENV["TINA4_SESSION_MONGO_COLLECTION"] || "sessions"
        client = Mongo::Client.new(@uri, database: @database)
        @collection = client[@collection_name]
        ensure_ttl_index
      rescue LoadError
        raise "MongoDB session handler requires the 'mongo' gem. Install with: gem install mongo"
      rescue Mongo::Error => e
        Tina4::Log.error("MongoDB session setup failed: #{e.message}")
      end

      def read(session_id)
        doc = @collection.find(_id: session_id).first
        return nil unless doc
        doc["data"]
      end

      def write(session_id, data)
        @collection.update_one(
          { _id: session_id },
          { "$set" => { data: data, updated_at: Time.now } },
          upsert: true
        )
      end

      def destroy(session_id)
        @collection.delete_one(_id: session_id)
      end

      def cleanup
        # MongoDB TTL index handles cleanup
      end

      private

      # Create the updated_at TTL index. An existing updated_at index with a
      # DIFFERENT expireAfterSeconds raises IndexOptionsConflict (code 85) — a
      # TTL index cannot be modified in place — so drop and recreate it with the
      # requested TTL. This makes re-init idempotent (no per-run error log) and
      # lets a changed session TTL take effect.
      def ensure_ttl_index
        @collection.indexes.create_one({ updated_at: 1 }, expire_after_seconds: @ttl)
      rescue Mongo::Error::OperationFailure => e
        raise unless e.code == 85 || e.message.include?("IndexOptionsConflict")
        @collection.indexes.drop_one("updated_at_1")
        @collection.indexes.create_one({ updated_at: 1 }, expire_after_seconds: @ttl)
      end
    end
  end
end
