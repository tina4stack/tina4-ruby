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
        # TINA4_SESSION_TTL reaches every backend (ADR-0024); was a hard-coded
        # 86400. 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
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

      # Decide whether a stored document has expired, FROM THE DOCUMENT ALONE.
      #
      # THE CONTRACT: an ABSENT or ZERO expiry stamp means "never expires". It is
      # guarded OUT of the comparison, never fed INTO it - so a document written
      # by another framework, an older version, or a direct insert is returned
      # rather than destroyed. Identical to the Python master's _has_expired.
      def self.expired?(doc)
        expires_at = doc["expires_at"].to_f
        expires_at.positive? && expires_at < Time.now.to_f
      end

      def read(session_id)
        doc = @collection.find(_id: session_id).first
        return nil unless doc

        # Expiry is checked HERE, at read time, against the document's own
        # absolute deadline. Relying on the TTL index alone (as this handler used
        # to) cannot honour a short TTL at all: mongod's TTL monitor sweeps once
        # every 60 SECONDS, so a 2-second session stayed readable for up to a
        # minute after it expired. The index is still created, but purely as the
        # background reaper that keeps the collection from growing forever.
        if self.class.expired?(doc)
          destroy(session_id)
          return nil
        end

        doc["data"]
      end

      # Write session data. A per-call +ttl+ WINS over the handler default.
      #
      # The ttl is consumed HERE, at write time, and baked into an ABSOLUTE
      # deadline (+expires_at+), so nothing at read time needs to know what the
      # ttl was. That field name and meaning are the shape Python (the master),
      # PHP and Node all store, so a session store SHARED between two frameworks
      # carries one shape instead of four. +updated_at+ is still written to feed
      # the TTL index.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        now = Time.now
        expires_at = effective_ttl.positive? ? now.to_f + effective_ttl : 0.0
        @collection.update_one(
          { _id: session_id },
          { "$set" => { data: data, expires_at: expires_at,
                        updated_at: now - (@ttl - effective_ttl) } },
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
