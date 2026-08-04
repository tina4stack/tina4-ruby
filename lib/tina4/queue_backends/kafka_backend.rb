# frozen_string_literal: true

module Tina4
  module QueueBackends
    class KafkaBackend
      def initialize(options = {})
        require "rdkafka"
        @brokers = options[:brokers] || "localhost:9092"
        @group_id = options[:group_id] || "tina4_consumer_group"
        @max_retries = options[:max_retries] || 3

        security = self.class._security_config
        # Kept so dead_letters() can build a short-lived READER consumer with
        # its own group id, which reads the dead-letter topic from the start
        # without disturbing the main subscription or committing offsets.
        @security = security

        producer_config = {
          "bootstrap.servers" => @brokers
        }.merge(security)
        @producer = Rdkafka::Config.new(producer_config).producer

        consumer_config = {
          "bootstrap.servers" => @brokers,
          "group.id" => @group_id,
          "auto.offset.reset" => "earliest",
          "enable.auto.commit" => "false"
        }.merge(security)
        @consumer = Rdkafka::Config.new(consumer_config).consumer
        @subscribed_topics = []
      rescue LoadError
        raise "Kafka backend requires the 'rdkafka' gem. Install with: gem install rdkafka"
      end

      # Build SSL/SASL client config from env (for a TLS broker/proxy).
      #
      # Mirrors tina4_python KafkaConnector._security_config: each setting is
      # read from the Tina4-namespaced env var first (TINA4_KAFKA_<NAME>) and
      # falls back to the bare librdkafka-convention name (KAFKA_<NAME>) that
      # many Kafka deployments already set. Honours security.protocol (e.g. SSL,
      # SASL_SSL), ssl.ca.location, and optional SASL (mechanism / username /
      # password). Unset keys are omitted, leaving librdkafka's PLAINTEXT default.
      # Queue propagates its own configuration onto the backend after construction.
      attr_accessor :max_retries

      def self._security_config
        # rdkafka key -> env suffix (read as TINA4_KAFKA_<suffix>, then KAFKA_<suffix>)
        mapping = {
          "security.protocol" => "SECURITY_PROTOCOL",
          "ssl.ca.location" => "SSL_CA_LOCATION",
          "sasl.mechanism" => "SASL_MECHANISM",
          "sasl.username" => "SASL_USERNAME",
          "sasl.password" => "SASL_PASSWORD"
        }
        config = {}
        mapping.each do |rdk, suffix|
          value = env_value("TINA4_KAFKA_#{suffix}") || env_value("KAFKA_#{suffix}")
          config[rdk] = value if value
        end
        config
      end

      # Read an env var, treating empty/blank values as unset (parity with
      # Python's `os.environ.get(...) or ...` truthiness).
      def self.env_value(name)
        value = ENV[name]
        return nil if value.nil? || value.empty?

        value
      end
      private_class_method :env_value

      def enqueue(message)
        if message.priority.to_i > 0
          raise NotImplementedError,
                "The kafka queue backend cannot honour push(priority): Kafka has no " \
                "priority concept at all - a consumer reads a partition in offset " \
                "order. Use the file or mongodb backend for prioritised jobs."
        end

        if message.available_at
          raise NotImplementedError,
                "The kafka queue backend cannot honour push(delay_seconds): Kafka " \
                "has no per-message delay at all. A consumer reads a partition in " \
                "offset order, so a delayed record would stall every record behind " \
                "it. Use the file or mongodb backend for delayed jobs, or schedule " \
                "the push itself."
        end

        @producer.produce(
          topic: message.topic,
          payload: message.to_json,
          key: message.id
        ).wait
      end

      def dequeue(topic)
        first = !@subscribed_topics.include?(topic)
        if first
          @consumer.subscribe(topic)
          @subscribed_topics << topic
        end

        # The first poll after subscribing must drive the consumer-group join +
        # partition assignment, which takes several seconds on a cold broker.
        # Until partitions are assigned, poll returns nil even when the topic
        # already has messages -- so a single poll made dequeue return nil right
        # after enqueue. Poll in a bounded loop on first subscribe (deadline
        # TINA4_KAFKA_ASSIGN_TIMEOUT, default 15s); steady state stays one ~1s poll.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   (first ? (ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"] || "15").to_f : 1.0)
        msg = nil
        loop do
          candidate = @consumer.poll(500)
          if candidate
            msg = candidate
            break
          end
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
        return nil unless msg

        data = JSON.parse(msg.payload)
        @last_message = msg

        # attempts and error MUST be carried back. Rebuilding from
        # topic/payload/id alone reset attempts to 0 on every redelivery, so
        # fail()'s attempts >= max_retries check could never trip and a poison
        # record would be re-produced forever instead of dead-lettering.
        Tina4::Job.new(
          topic: data["topic"],
          payload: data["payload"],
          id: data["id"],
          attempts: data["attempts"] || 0,
          error: data["error"]
        )
      rescue Rdkafka::RdkafkaError
        nil
      end

      # Kafka has no queue depth: a log is a sequence of offsets, not a queue,
      # and computing a "remaining" count means an admin round-trip per call.
      # ADR-0022 decision 5 records 0 as the documented answer, which Python and
      # PHP already return. Ruby had no size method at all, so queue.size raised
      # NoMethodError on kafka - a method that does not resolve at all, which is
      # what invariant 1 forbids.
      def size(_topic)
        0
      end

      def acknowledge(_message)
        @consumer.commit if @last_message
      end

      def requeue(message)
        enqueue(message)
      end

      def dead_letter(message)
        # attempts and error MUST ride along, else every Kafka dead letter reads
        # back as attempts=0 with no reason while file/mongodb report the real
        # values.
        dead_msg = Tina4::Job.new(
          topic: "#{message.topic}.dead_letter",
          payload: message.payload,
          id: message.id,
          attempts: message.attempts,
          error: message.error
        )
        enqueue(dead_msg)
      end

      # Terminal ack. Job#complete calls backend.complete, and this backend only
      # had acknowledge() - so job.complete was a silent no-op on kafka and the
      # consumer-group offset was never committed, making the broker redeliver
      # every completed record.
      def complete(message)
        acknowledge(message)
      end

      # Record a failed attempt, then retry it or dead-letter it.
      #
      # This did not exist. Job#fail guarded on respond_to?(:fail) and silently
      # degraded to in-memory bookkeeping, so job.fail() NEVER reached Kafka:
      # the offset was never committed and no dead letter was produced.
      #
      # A retry RE-PRODUCES a record carrying the new count, because a Kafka
      # record is immutable and carries no delivery counter. The offset is
      # committed LAST so a crash in between redelivers rather than loses -
      # at-least-once, which is the contract.
      def fail(job, error = "")
        job.attempts += 1
        job.error = error
        if job.attempts >= @max_retries
          dead_letter(job)
        else
          enqueue(job)
        end
        acknowledge(job)
      end

      def retry(job, delay_seconds: 0)
        if delay_seconds.to_f > 0
          raise NotImplementedError,
                "The kafka queue backend cannot honour retry(delay_seconds): " \
                "Kafka has no per-message delay, for the same reason " \
                "push(delay_seconds) is refused - a consumer reads a partition " \
                "in offset order, so a delayed record stalls every record behind " \
                "it. Re-producing immediately while silently dropping the delay " \
                "would run the job far sooner than asked. Use the file or mongodb " \
                "backend for delayed retries."
        end

        job.attempts += 1
        job.error = nil
        enqueue(job)
        acknowledge(job)
        true
      end

      # Dead-lettered jobs, read back from the <topic>.dead_letter topic this
      # backend produces to itself. Kafka's log is not queryable by job state,
      # but it IS readable from the beginning - so this ANSWERS rather than
      # refusing, and a dead-letter handler written against the file backend
      # finds the same jobs here (invariant 3).
      #
      # Uses a short-lived consumer with a UNIQUE group id and never commits, so
      # it always reads from the start and a read never consumes. Reading with
      # the main consumer would move its offsets and steal the subscription.
      def dead_letters(topic, max_retries: 3)
        name = "#{topic}.dead_letter"
        reader = Rdkafka::Config.new({
          "bootstrap.servers" => @brokers,
          "group.id" => "#{@group_id}.reader.#{Process.pid}.#{object_id}",
          "auto.offset.reset" => "earliest",
          "enable.auto.commit" => "false"
        }.merge(@security)).consumer
        out = []
        begin
          reader.subscribe(name)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                     (ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"] || "15").to_f
          loop do
            msg = reader.poll(500)
            if msg
              data = JSON.parse(msg.payload)
              data["status"] = "dead"
              out << data
              next
            end
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          end
        rescue Rdkafka::RdkafkaError
          # An absent topic means nothing has been dead-lettered yet.
          nil
        ensure
          reader.close
        end
        out
      end

      def failed(_topic, max_retries: 3)
        raise NotImplementedError,
              "The kafka queue backend cannot answer failed(): a job that failed " \
              "but is still retryable is re-produced to the main topic, and a log " \
              "cannot be queried by job state, so it cannot be told apart from a " \
              "normal pending record. Returning an empty list would claim nothing " \
              "has failed. Use dead_letters() for exhausted jobs, or the file or " \
              "mongodb backend to enumerate retryable failures."
      end

      def retry_failed(_topic, max_retries: 3)
        raise NotImplementedError,
              "The kafka queue backend cannot perform retry_failed(): it must " \
              "first enumerate the failed-but-retryable jobs, which a log cannot " \
              "be queried for. Returning 0 would claim nothing needed retrying. " \
              "Use retry(job_id) with an id you already hold, or the file or " \
              "mongodb backend."
      end

      def retry_job(_topic, job_id: nil, delay_seconds: 0)
        raise NotImplementedError,
              "The kafka queue backend cannot perform retry(job_id): a log cannot " \
              "retract a record, so the dead letter would stay on the " \
              ".dead_letter topic and be revived again on the next call, " \
              "duplicating the job. Re-produce it yourself with push() if that " \
              "is what you want, or use the file or mongodb backend."
      end

      def purge(_topic, _status)
        raise NotImplementedError,
              "The kafka queue backend cannot perform purge(): a log cannot " \
              "delete records by status - retention is time- and size-based and " \
              "set on the topic. Returning 0 would claim nothing needed purging. " \
              "Configure topic retention, or use the file or mongodb backend."
      end

      def clear(_topic)
        raise NotImplementedError,
              "The kafka queue backend cannot perform clear(): a log cannot " \
              "delete records on demand - retention is time- and size-based and " \
              "set on the topic. Returning 0 would claim the queue was emptied " \
              "when it was not. Configure topic retention, or use the file or " \
              "mongodb backend."
      end

      def close
        @producer&.close
        @consumer&.close
      end
    end
  end
end
