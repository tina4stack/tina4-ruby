# frozen_string_literal: true
require "json"

module Tina4
  module SessionHandlers
    class MongoHandler
      def initialize(options = {})
        require "mongo"
        @ttl = options[:ttl] || 86400
        client = Mongo::Client.new(
          options[:uri] || "mongodb://localhost:27017",
          database: options[:database] || "tina4_sessions"
        )
        @collection = client[options[:collection] || "sessions"]
        # Ensure TTL index
        @collection.indexes.create_one(
          { updated_at: 1 },
          expire_after_seconds: @ttl
        )
      rescue LoadError
        raise "MongoDB session handler requires the 'mongo' gem. Install with: gem install mongo"
      rescue Mongo::Error => e
        Tina4::Debug.error("MongoDB session setup failed: #{e.message}")
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
    end
  end
end
