# frozen_string_literal: true

module Tina4
  module QueueBackends
    class RabbitmqBackend
      def initialize(options = {})
        require "bunny"
        @connection = Bunny.new(
          host: options[:host] || "localhost",
          port: options[:port] || 5672,
          username: options[:username] || "guest",
          password: options[:password] || "guest",
          vhost: options[:vhost] || "/"
        )
        @connection.start
        @channel = @connection.create_channel
        @queues = {}
        @exchanges = {}
        @max_retries = options[:max_retries] || 3
      rescue LoadError
        raise "RabbitMQ backend requires the 'bunny' gem. Install with: gem install bunny"
      end

      # Queue propagates its own configuration onto the backend after construction.
      attr_accessor :max_retries

      def enqueue(message)
        if message.priority.to_i > 0
          raise NotImplementedError,
                "The rabbitmq queue backend cannot honour push(priority): RabbitMQ " \
                "orders a queue FIFO. Native priority needs the queue DECLARED " \
                "with an x-max-priority argument, and an existing queue cannot " \
                "be redeclared with one (the broker answers PRECONDITION_FAILED), " \
                "so enabling it would break every queue already in service. Use " \
                "the file or mongodb backend for prioritised jobs."
        end

        if message.available_at
          raise NotImplementedError,
                "The rabbitmq queue backend cannot honour push(delay_seconds): " \
                "RabbitMQ has no per-message delay in core. The " \
                "rabbitmq_delayed_message_exchange plugin is not part of a standard " \
                "broker, and the TTL + dead-letter workaround head-of-line blocks (a " \
                "long-delayed job holds up every shorter one behind it in the same " \
                "queue). Use the file or mongodb backend for delayed jobs, or " \
                "schedule the push itself."
        end

        queue = get_queue(message.topic)
        queue.publish(message.to_json, persistent: true)
      end

      def dequeue(topic)
        queue = get_queue(topic)
        # Manual ack: do NOT let bunny's default auto-ack remove the message on
        # pop. The message stays in-flight (unacked) until complete() acks it, so
        # a consumer crash before complete() makes the broker redeliver it
        # (at-least-once delivery) — parity with the Python/PHP masters, whose
        # basic_get uses auto_ack=false / no-ack=false. With the old auto-ack pop
        # the stored delivery_tag had already been acked, so a later
        # channel.acknowledge raised PRECONDITION_FAILED and closed the channel.
        delivery_info, _properties, payload = queue.pop(manual_ack: true)
        return nil unless payload

        data = JSON.parse(payload)
        # attempts and error MUST be carried back. Rebuilding the Job from
        # topic/payload/id alone reset attempts to 0 on every redelivery, so
        # fail()'s attempts >= max_retries check could never trip and a poison
        # job would be retried forever instead of dead-lettering.
        msg = Tina4::Job.new(
          topic: data["topic"],
          payload: data["payload"],
          id: data["id"],
          attempts: data["attempts"] || 0,
          error: data["error"]
        )
        @last_delivery_tag = delivery_info.delivery_tag
        msg
      end

      # Acknowledge the in-flight message as done (terminal). Named complete() to
      # match the lite/mongo backends AND the Job#complete lifecycle, which calls
      # backend.complete (not acknowledge) — so `job.complete` now actually acks
      # the broker message instead of being a silent no-op. multiple:false acks
      # only this delivery. The stored tag is cleared so a double-complete is a
      # safe no-op rather than a second ack on an unknown tag.
      def complete(_message)
        return unless @last_delivery_tag

        @channel.acknowledge(@last_delivery_tag, false)
        @last_delivery_tag = nil
      end

      def requeue(message)
        enqueue(message)
      end

      def dead_letter(message)
        dlq = get_queue("#{message.topic}.dead_letter")
        dlq.publish(message.to_json, persistent: true)
      end

      # Record a failed attempt, then retry it or dead-letter it.
      #
      # This did not exist. Job#fail guarded on respond_to?(:fail) and silently
      # degraded to in-memory bookkeeping, so job.fail() NEVER reached the
      # broker: the delivery stayed unacked, no dead letter was written, and
      # both failed() and dead_letters() reported nothing. The job was lost as
      # far as the application could see.
      #
      # AMQP basic.nack(requeue=true) returns the ORIGINAL body unmodified --
      # the protocol carries no delivery counter -- so a retry RE-PUBLISHES a
      # body carrying the new count instead. That is what every AMQP client
      # that counts attempts does (Celery, Spring AMQP's
      # RepublishMessageRecoverer, laravel-queue-rabbitmq).
      def fail(job, error = "")
        job.attempts += 1
        job.error = error
        if job.attempts >= @max_retries
          dead_letter(job)
        else
          enqueue(job)
        end
        # Ack LAST: the re-publish (or dead-letter) is durable before the
        # original leaves the queue, so a crash in between redelivers rather
        # than loses. That is at-least-once, which is the contract.
        complete(job)
      end

      # Explicit re-queue requested by the caller (job.retry). Always
      # re-enqueues regardless of the retry limit -- a manual override,
      # distinct from the automatic fail() path.
      def retry(job, delay_seconds: 0)
        if delay_seconds.to_f > 0
          raise NotImplementedError,
                "The rabbitmq queue backend cannot honour retry(delay_seconds): " \
                "RabbitMQ has no per-message delay in core, for the same reason " \
                "push(delay_seconds) is refused. Re-queueing immediately while " \
                "silently dropping the delay would run the job far sooner than " \
                "asked. Use the file or mongodb backend for delayed retries."
        end

        job.attempts += 1
        job.error = nil
        enqueue(job)
        complete(job)
        true
      end

      def acknowledge(message)
        complete(message)
      end

      # Dead-lettered jobs, read back from the <topic>.dead_letter queue this
      # backend writes itself. RabbitMQ's own dead-letter EXCHANGE is not
      # queryable, but the queue Tina4 maintains is -- so this ANSWERS rather
      # than refusing, and a dead-letter handler written against the file
      # backend finds the same jobs here (invariant 3).
      #
      # Drain-and-republish: a read must not consume. Every message popped is
      # published straight back, so the queue is unchanged by the read.
      # Returns plain Hashes with string keys, matching the lite backend — the
      # parsed body already carries id/topic/payload/attempts/error, so a caller
      # reads it the same way on every backend.
      def dead_letters(topic, max_retries: 3)
        drain_dead_letters(topic).map do |data|
          data["status"] = "dead"
          data
        end
      end

      def failed(_topic, max_retries: 3)
        raise NotImplementedError,
              "The rabbitmq queue backend cannot answer failed(): a job that " \
              "failed but is still retryable is re-published to the main topic, " \
              "so it cannot be told apart from a normal pending message without " \
              "draining the live queue. Returning an empty list would claim " \
              "nothing has failed. Use dead_letters() for exhausted jobs, or the " \
              "file or mongodb backend to enumerate retryable failures."
      end

      def retry_failed(_topic, max_retries: 3)
        raise NotImplementedError,
              "The rabbitmq queue backend cannot perform retry_failed(): it must " \
              "first enumerate the failed-but-retryable jobs, which are back on " \
              "the main topic and indistinguishable from pending work. Returning " \
              "0 would claim nothing needed retrying. Use retry(job_id) with an " \
              "id you already hold, or the file or mongodb backend."
      end

      # Move ONE dead-lettered job back to its main topic.
      def retry_job(topic, job_id: nil, delay_seconds: 0)
        found = nil
        keep = []
        drain_dead_letters(topic).each do |data|
          if found.nil? && (job_id.nil? || data["id"].to_s == job_id.to_s)
            found = data
          else
            keep << data
          end
        end
        keep.each { |data| publish_to("#{topic}.dead_letter", data) }
        return false unless found

        found["attempts"] = (found["attempts"] || 0) + 1
        found["status"] = "pending"
        found["error"] = nil
        found["topic"] = topic
        publish_to(topic, found)
        true
      end

      # Remove messages by status. "dead" empties the dead-letter queue;
      # anything else empties the main queue. Returns the count removed.
      def purge(topic, status)
        name = dead_status?(status) ? "#{topic}.dead_letter" : topic
        queue = get_queue(name)
        count = queue.message_count
        queue.purge
        count
      end

      def clear(topic)
        purge(topic, "pending")
      end

      def size(topic)
        queue = get_queue(topic)
        queue.message_count
      end

      # Close the AMQP channel and connection and release the socket.
      #
      # IDEMPOTENT by construction: the handles are dropped in an ensure, so a
      # second close finds nothing and returns. Before 3.13.95 they were left
      # set, and Bunny raises on closing an already-closed channel - so a
      # shutdown path that ran twice crashed on the second pass.
      def close
        @channel&.close
        @connection&.close
      ensure
        @channel = nil
        @connection = nil
        @queues = {}
        @exchanges = {}
      end

      private

      def get_queue(topic)
        @queues[topic] ||= @channel.queue(topic, durable: true)
      end

      def dead_status?(status)
        %w[dead dead_letter deadletter failed].include?(status.to_s.downcase)
      end

      # Pop every message off <topic>.dead_letter and put it straight back.
      # A READ must not consume: dead_letters() is called by dashboards and
      # health checks, and a read that emptied the queue would destroy the very
      # backlog it reports on. Auto-ack removes each message, and each one is
      # re-published before the method returns.
      def drain_dead_letters(topic)
        name = "#{topic}.dead_letter"
        queue = get_queue(name)
        out = []
        loop do
          _info, _props, payload = queue.pop(manual_ack: false)
          break unless payload

          out << JSON.parse(payload)
        end
        out.each { |data| publish_to(name, data) }
        out
      end

      def publish_to(name, data)
        get_queue(name).publish(JSON.generate(data), persistent: true)
      end
    end
  end
end
