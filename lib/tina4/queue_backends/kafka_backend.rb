# frozen_string_literal: true

module Tina4
  module QueueBackends
    class KafkaBackend
      def initialize(options = {})
        require "rdkafka"
        @brokers = options[:brokers] || "localhost:9092"
        @group_id = options[:group_id] || "tina4_consumer_group"

        producer_config = {
          "bootstrap.servers" => @brokers
        }
        @producer = Rdkafka::Config.new(producer_config).producer

        consumer_config = {
          "bootstrap.servers" => @brokers,
          "group.id" => @group_id,
          "auto.offset.reset" => "earliest",
          "enable.auto.commit" => "false"
        }
        @consumer = Rdkafka::Config.new(consumer_config).consumer
        @subscribed_topics = []
      rescue LoadError
        raise "Kafka backend requires the 'rdkafka' gem. Install with: gem install rdkafka"
      end

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

        Tina4::QueueMessage.new(
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
        dead_msg = Tina4::QueueMessage.new(
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
