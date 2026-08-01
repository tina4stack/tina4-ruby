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

      # Write session data. A per-call +ttl+ WINS over the handler default.
      #
      # Expiry itself is delegated to MongoDB's native TTL index on +updated_at+
      # (see ensure_ttl_index), which is why this handler was never at risk of the
      # destroy-on-unstamped defect: there is no hand-rolled comparison to feed a
      # missing stamp into. A per-call ttl shorter than the index's interval is
      # honoured by back-dating +updated_at+ so the index reaps it on schedule.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        stamp = Time.now - (@ttl - effective_ttl)
        @collection.update_one(
          { _id: session_id },
          { "$set" => { data: data, updated_at: stamp } },
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
