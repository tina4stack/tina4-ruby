# frozen_string_literal: true

module Tina4
  module QueueBackends
    class MongoBackend
      def initialize(options = {})
        require "mongo"

        uri = options[:uri] || ENV["TINA4_MONGO_URI"]
        host = options[:host] || ENV.fetch("TINA4_MONGO_HOST", "localhost")
        port = (options[:port] || ENV.fetch("TINA4_MONGO_PORT", 27017)).to_i
        username = options[:username] || ENV["TINA4_MONGO_USERNAME"]
        password = options[:password] || ENV["TINA4_MONGO_PASSWORD"]
        db_name = options[:db] || ENV.fetch("TINA4_MONGO_DB", "tina4")
        @collection_name = options[:collection] || ENV.fetch("TINA4_MONGO_COLLECTION", "tina4_queue")

        if uri
          @client = Mongo::Client.new(uri)
        else
          conn_options = { database: db_name }
          conn_options[:user] = username if username
          conn_options[:password] = password if password
          @client = Mongo::Client.new(["#{host}:#{port}"], conn_options)
        end

        @db = @client.database
        create_indexes
      rescue LoadError
        raise "MongoDB backend requires the 'mongo' gem. Install with: gem install mongo"
      end

      def enqueue(message)
        collection.insert_one(
          _id: message.id,
          topic: message.topic,
          payload: message.payload,
          created_at: message.created_at.utc,
          attempts: message.attempts,
          status: "pending"
        )
      end

      def dequeue(topic)
        doc = collection.find_one_and_update(
          { topic: topic, status: "pending" },
          { "$set" => { status: "processing" } },
          sort: { created_at: 1 },
          return_document: :after
        )
        return nil unless doc

        Tina4::Job.new(
          topic: doc["topic"],
          payload: doc["payload"],
          id: doc["_id"]
        )
      end

      def acknowledge(message)
        collection.delete_one(_id: message.id)
      end

      def requeue(message)
        collection.find_one_and_update(
          { _id: message.id },
          { "$set" => { status: "pending" }, "$inc" => { attempts: 1 } },
          upsert: true
        )
      end

      def dead_letter(message)
        collection.find_one_and_update(
          { _id: message.id },
          { "$set" => { status: "dead", topic: "#{message.topic}.dead_letter" } },
          upsert: true
        )
      end

      def size(topic)
        collection.count_documents(topic: topic, status: "pending")
      end

      def dead_letters(topic, max_retries: 3)
        collection.find(topic: "#{topic}.dead_letter", status: "dead").map do |doc|
          Tina4::Job.new(
            topic: doc["topic"],
            payload: doc["payload"],
            id: doc["_id"]
          )
        end
      end

      def purge(topic, status)
        result = collection.delete_many(topic: topic, status: status.to_s)
        result.deleted_count
      end

      def retry_failed(topic, max_retries: 3)
        result = collection.update_many(
          { topic: topic, status: "failed", attempts: { "$lt" => max_retries } },
          { "$set" => { status: "pending" } }
        )
        result.modified_count
      end

      def close
        @client&.close
      end

      private

      def collection
        @db[@collection_name]
      end

      def create_indexes
        collection.indexes.create_many([
          { key: { topic: 1, status: 1, created_at: 1 } },
          { key: { topic: 1, status: 1, attempts: 1 } }
        ])
      rescue Mongo::Error => e
        Tina4::Log.warning("MongoDB index creation failed: #{e.message}")
      end
    end
  end
end
