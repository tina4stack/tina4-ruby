# frozen_string_literal: true

module Tina4
  module QueueBackends
    class MongoBackend
      # Reservation/visibility + retry policy (settable so a Queue can propagate
      # its own onto a backend instance passed directly — legacy path).
      attr_accessor :visibility_timeout, :max_retries

      def initialize(options = {})
        require "mongo"
        @max_retries = options[:max_retries] || 3

        uri = options[:uri] || ENV["TINA4_MONGO_URI"]
        host = options[:host] || ENV.fetch("TINA4_MONGO_HOST", "localhost")
        port = (options[:port] || ENV.fetch("TINA4_MONGO_PORT", 27017)).to_i
        username = options[:username] || ENV["TINA4_MONGO_USERNAME"]
        password = options[:password] || ENV["TINA4_MONGO_PASSWORD"]
        db_name = options[:db] || ENV.fetch("TINA4_MONGO_DB", "tina4")
        @collection_name = options[:collection] || ENV.fetch("TINA4_MONGO_COLLECTION", "tina4_queue")
        # Reservation/visibility timeout (seconds): a dequeued message is held
        # reserved (status "processing") with available_at = now + timeout;
        # reclaim_expired returns it once that passes (consumer died mid-flight).
        # <= 0 disables reclaim.
        @visibility_timeout = resolve_visibility_timeout(options[:visibility_timeout])

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

      def resolve_visibility_timeout(option)
        return option.to_f unless option.nil?

        Float(ENV.fetch("TINA4_QUEUE_VISIBILITY_TIMEOUT", "300"))
      rescue ArgumentError, TypeError
        300.0
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
        # Reclaim any reservations whose consumer died before acking, then take
        # the next available message (at-least-once delivery).
        reclaim_expired(topic, @max_retries)
        now = Time.now.utc
        # The claim advances available_at to now + visibility_timeout and records
        # reserved_at so reclaim_expired can return the job if the consumer dies
        # before acknowledge/complete. This is the fix for the "reserved forever"
        # bug — previously available_at was left unchanged.
        doc = collection.find_one_and_update(
          { topic: topic, status: "pending" },
          { "$set" => {
            status: "processing",
            reserved_at: now,
            available_at: now + (@visibility_timeout || 0)
          } },
          sort: { created_at: 1 },
          return_document: :after
        )
        return nil unless doc

        Tina4::Job.new(
          topic: doc["topic"],
          payload: doc["payload"],
          id: doc["_id"],
          priority: doc["priority"] || 0,
          attempts: doc["attempts"] || 0
        )
      end

      # Return reservations whose visibility window expired (at-least-once).
      #
      # A message left "processing" with available_at <= now had a consumer die
      # before acknowledging. Each is atomically flipped back to "pending" with
      # attempts incremented (so the next dequeue re-delivers it); once attempts
      # >= max_retries it is dead-lettered instead. Returns the number reclaimed.
      # Disabled when visibility_timeout <= 0.
      def reclaim_expired(topic, max_retries)
        return 0 if @visibility_timeout.nil? || @visibility_timeout <= 0

        reclaimed = 0
        loop do
          now = Time.now.utc
          doc = collection.find_one_and_update(
            { topic: topic, status: "processing", available_at: { "$lte" => now } },
            { "$set" => { status: "pending", available_at: now, reserved_at: nil },
              "$inc" => { attempts: 1 } },
            sort: { available_at: 1 },
            return_document: :after
          )
          break unless doc

          reclaimed += 1
          next if (doc["attempts"] || 0) < max_retries

          # Out of retries — move it to the dead-letter queue and remove the
          # original so it is not re-delivered.
          collection.insert_one(
            _id: "#{doc["_id"]}.dead_letter",
            topic: "#{topic}.dead_letter",
            payload: doc["payload"],
            status: "dead",
            priority: doc["priority"] || 0,
            attempts: doc["attempts"] || 0,
            error: "reservation timed out - consumer did not acknowledge within the visibility timeout",
            created_at: Time.now.utc
          )
          collection.delete_one(_id: doc["_id"], topic: topic)
        end
        reclaimed
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
