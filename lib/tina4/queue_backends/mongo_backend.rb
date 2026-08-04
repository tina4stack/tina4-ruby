# frozen_string_literal: true

module Tina4
  module QueueBackends
    class MongoBackend
      # Reservation/visibility + retry policy (settable so a Queue can propagate
      # its own onto a backend instance passed directly — legacy path).
      attr_accessor :visibility_timeout, :max_retries, :retry_backoff

      def initialize(options = {})
        require "mongo"
        @max_retries = options[:max_retries] || 3
        # Seconds to delay a requeued (failed/retried) job before it is eligible
        # again. Default 0 = available on the very next dequeue, so a fail()'d job
        # retries immediately (matching the lite backend) instead of waiting out
        # the visibility window.
        @retry_backoff = (options[:retry_backoff] || 0).to_f

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
          # Honour the explicit db: / TINA4_MONGO_DB even when a uri is given.
          # Mongo::Client.new(uri) with no database path defaults to "admin", so
          # without passing :database the requested db_name was silently dropped
          # and every job/dead-letter landed in admin (a data-isolation footgun).
          # The explicit db_name always wins over the URI's (often absent) default.
          @client = Mongo::Client.new(uri, database: db_name)
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
        # Queue#push already resolved delay_seconds into an available_at (nil when
        # undelayed). Persisting it is what makes a delayed job invisible until
        # its time: dequeue filters on it below. Before 3.13.95 this field was
        # never written, so a delayed job on Mongo fired immediately while the
        # same code delayed correctly on the file backend.
        collection.insert_one(
          _id: message.id,
          topic: message.topic,
          payload: message.payload,
          created_at: message.created_at.utc,
          available_at: message.available_at&.utc,
          attempts: message.attempts,
          # Stored so the dequeue sort can order on it. It was read back on the
          # way out (doc["priority"] || 0) but never written, so every job
          # scored 0 and the queue was pure FIFO.
          priority: message.priority,
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
        # A job is claimable only once available_at has passed. The $or arm is not
        # optional: documents enqueued before available_at was written have no
        # such field, and a bare { "$lte" => now } would strand every one of them
        # in the collection forever.
        doc = collection.find_one_and_update(
          { topic: topic, status: "pending",
            "$or" => [
              { available_at: nil },
              { available_at: { "$exists" => false } },
              { available_at: { "$lte" => now } }
            ] },
          { "$set" => {
            status: "processing",
            reserved_at: now,
            available_at: now + (@visibility_timeout || 0)
          } },
          # Highest priority first, ties broken oldest-first — the same ordering
          # policy LiteBackend applies. Sorting on created_at alone made the
          # backend pure FIFO, so an urgent job queued behind a backlog waited
          # for all of it.
          sort: { priority: -1, created_at: 1 },
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

      # Terminal success — the job is done and removed (mirrors the lite
      # backend's complete()). Without this, job.complete() was a no-op on
      # MongoDB and the document stayed "processing" forever.
      def complete(message)
        collection.delete_one(_id: message.id)
      end

      # Record a failed attempt (mirrors the lite backend + the Python Mongo
      # adapter). Increments attempts; while attempts < max_retries the job is
      # re-queued to pending (visible again immediately, or after retry_backoff),
      # otherwise it is dead-lettered. The Queue/Job lifecycle expects fail() to
      # route the requeue here — previously MongoBackend had no fail(), so
      # job.fail() degraded to in-memory bookkeeping and never touched Mongo.
      def fail(job, error = "")
        job.attempts += 1
        if job.attempts >= @max_retries
          collection.find_one_and_update(
            { _id: job.id },
            # attempts MUST be persisted here. fail() increments the in-memory
            # counter only; without writing it the dead-letter document keeps
            # the value it held BEFORE the final attempt, so dead_letters()
            # under-reported by one on every Mongo dead letter.
            { "$set" => { status: "dead", topic: "#{job.topic}.dead_letter",
                          attempts: job.attempts,
                          error: error, reserved_at: nil } },
            upsert: true
          )
        else
          requeue_with_error(job, error)
        end
      end

      # Explicit re-queue requested by the caller (job.retry()). Always
      # re-enqueues regardless of the retry limit — a manual override, distinct
      # from the automatic fail() path. Increments attempts, clears the error.
      def retry(job, delay_seconds: 0)
        job.attempts += 1
        backoff = delay_seconds.to_f > 0 ? delay_seconds.to_f : @retry_backoff
        collection.find_one_and_update(
          { _id: job.id },
          { "$set" => { status: "pending", error: nil, reserved_at: nil,
                        available_at: requeue_available_at(backoff) } },
          upsert: true
        )
      end

      def requeue(message)
        # Reset available_at so the requeued job is visible again right away (or
        # after retry_backoff) and clear reserved_at. dequeue() pushed
        # available_at out to the reservation expiry; leaving it there stranded a
        # requeued job for the full visibility window instead of retrying it on
        # the next pop().
        collection.find_one_and_update(
          { _id: message.id },
          { "$set" => { status: "pending", reserved_at: nil,
                        available_at: requeue_available_at(@retry_backoff) },
            "$inc" => { attempts: 1 } },
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

      # Remove every pending job for a topic. Queue#clear used to return 0
      # silently here, because this backend had no clear at all and the caller
      # guarded on respond_to?(:clear) - so clearing a mongo-backed queue was a
      # no-op that looked like success.
      def clear(topic)
        result = collection.delete_many(topic: topic, status: "pending")
        result.deleted_count
      end

      # Claim ONE specific job by id, the same way dequeue claims the head.
      # Queue#pop_by_id used to return nil silently for the same reason.
      def find_by_id(topic, id)
        now = Time.now.utc
        doc = collection.find_one_and_update(
          { _id: id, topic: topic, status: "pending" },
          { "$set" => { status: "processing", reserved_at: now,
                        available_at: now + (@visibility_timeout || 0) } },
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

      def size(topic)
        collection.count_documents(topic: topic, status: "pending")
      end

      # Jobs that failed but are still eligible for retry (under max_retries).
      #
      # Found by the ATTEMPTS COUNTER, not by a "failed" status. fail() under
      # max_retries re-queues the job as "pending" (that is what makes the next
      # dequeue redeliver it), so no document ever carries status="failed" on
      # the normal path. This method did not exist at all, and Queue#failed
      # silently returned [] for it — indistinguishable from "nothing has
      # failed" (ADR-0022 decision 7).
      def failed(topic, max_retries: 3)
        collection.find(
          topic: topic,
          status: { "$in" => %w[pending failed] },
          attempts: { "$gt" => 0, "$lt" => max_retries }
        ).map { |doc| job_from_doc(doc) }
      end

      def dead_letters(topic, max_retries: 3)
        collection.find(topic: "#{topic}.dead_letter", status: "dead")
                  .map { |doc| job_from_doc(doc) }
      end

      def purge(topic, status)
        result = collection.delete_many(topic: topic, status: status.to_s)
        result.deleted_count
      end

      # Re-queue failed-but-retryable jobs back to pending. Returns the count.
      #
      # Matched on the ATTEMPTS COUNTER for the same reason failed() is: the
      # old query was status="failed", which requeue_with_error never writes,
      # so this matched nothing and always returned 0 — silently reporting that
      # there was nothing to retry.
      def retry_failed(topic, max_retries: 3)
        result = collection.update_many(
          { topic: topic,
            # BOTH statuses. "pending" is where the auto-retry fail() path
            # leaves a still-retryable job (it re-queues rather than marking
            # it failed), and matching only "failed" is why this used to
            # return 0 on every real failure. "failed" is still matched
            # because reject(requeue: false) writes it, so a job explicitly
            # parked as failed is retryable too.
            status: { "$in" => %w[pending failed] },
            attempts: { "$gt" => 0, "$lt" => max_retries } },
          # Reset available_at so re-queued failed jobs are visible again — they
          # were reserved with available_at in the future at dequeue. Clear
          # reserved_at too. (Same Bug B reason as requeue/fail.)
          # status MUST be set back to "pending". The match now also picks up
          # docs explicitly parked as "failed" (reject(requeue: false)), and
          # those have to be flipped back or retry_failed reports a re-queue it
          # never performed. A doc already pending is unaffected.
          { "$set" => { status: "pending", error: nil, reserved_at: nil,
                        available_at: requeue_available_at(@retry_backoff) } }
        )
        result.modified_count
      end

      # Move ONE dead-lettered job back to its main topic as pending.
      # Returns true when a job was revived, false when the id was not found.
      def retry_job(topic, job_id: nil, delay_seconds: 0)
        filter = { topic: "#{topic}.dead_letter", status: "dead" }
        filter[:_id] = job_id if job_id
        doc = collection.find(filter).first
        return false unless doc

        available = delay_seconds.to_f > 0 ? (Time.now.utc + delay_seconds.to_f) : Time.now.utc
        collection.update_one(
          { _id: doc["_id"] },
          { "$set" => { topic: topic, status: "pending", error: nil,
                        reserved_at: nil, available_at: available } }
        )
        true
      end

      # Close the MongoClient and release its connection pool.
      #
      # IDEMPOTENT by construction: the handles are dropped in an ensure, so a
      # second close finds nothing and returns. Before 3.13.95 the ivars were
      # left set, so a shutdown path that ran twice (an explicit close plus an
      # at_exit / ensure) closed an already-closed client.
      def close
        @client&.close
      ensure
        @client = nil
        @db = nil
      end

      private

      # A stored document as a plain Hash with string keys, CARRYING attempts
      # and error.
      #
      # Hash, not Job: the lite backend returns plain hashes from failed() and
      # dead_letters(), so returning Job objects here would make the same
      # caller need two different accessors depending on the backend — the very
      # divergence this invariant exists to remove.
      #
      # The old dead_letters() mapped only topic/payload/id, so every Mongo dead
      # letter read back as attempts=0 with no error text while the file backend
      # reported the real values — a handler logging "died after N attempts:
      # <reason>" printed "died after 0 attempts:" on Mongo only.
      def job_from_doc(doc)
        {
          "id" => doc["_id"],
          "topic" => doc["topic"],
          "payload" => doc["payload"],
          "attempts" => doc["attempts"] || 0,
          "status" => doc["status"],
          "error" => doc["error"]
        }
      end

      # Re-queue a failed job to pending, carrying the failure reason and
      # resetting available_at (now, or now + retry_backoff) + clearing
      # reserved_at so the next dequeue picks it up.
      def requeue_with_error(job, error)
        collection.find_one_and_update(
          { _id: job.id },
          # Persist the incremented attempt count (fail() already did job.attempts
          # += 1). Without this the doc's attempts stayed at its old value, so the
          # next dequeue surfaced a stale count, fail()'s attempts >= max_retries
          # check never tripped, and the job was re-queued forever instead of
          # dead-lettering.
          { "$set" => { status: "pending", error: error, reserved_at: nil,
                        attempts: job.attempts,
                        available_at: requeue_available_at(@retry_backoff) } },
          upsert: true
        )
      end

      # available_at for a re-queued job: now (immediately retryable) or
      # now + backoff when a backoff is configured.
      def requeue_available_at(backoff)
        b = (backoff || 0).to_f
        b > 0 ? (Time.now.utc + b) : Time.now.utc
      end

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
