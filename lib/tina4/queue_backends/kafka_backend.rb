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
        @producer.produce(
          topic: message.topic,
          payload: message.to_json,
          key: message.id
        ).wait
      end

      def dequeue(topic)
        unless @subscribed_topics.include?(topic)
          @consumer.subscribe(topic)
          @subscribed_topics << topic
        end

        msg = @consumer.poll(1000)
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
