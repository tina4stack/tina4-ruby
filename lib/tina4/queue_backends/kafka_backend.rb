# frozen_string_literal: true

module Tina4
  module QueueBackends
    class KafkaBackend
      def initialize(options = {})
        require "rdkafka"
        @brokers = options[:brokers] || "localhost:9092"
        @group_id = options[:group_id] || "tina4_consumer_group"

        security = self.class._security_config

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

        Tina4::Job.new(
          topic: data["topic"],
          payload: data["payload"],
          id: data["id"]
        )
      rescue Rdkafka::RdkafkaError
        nil
      end

      def acknowledge(_message)
        @consumer.commit if @last_message
      end

      def requeue(message)
        enqueue(message)
      end

      def dead_letter(message)
        dead_msg = Tina4::Job.new(
          topic: "#{message.topic}.dead_letter",
          payload: message.payload,
          id: message.id
        )
        enqueue(dead_msg)
      end

      def close
        @producer&.close
        @consumer&.close
      end
    end
  end
end
