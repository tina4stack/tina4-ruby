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
      rescue LoadError
        raise "RabbitMQ backend requires the 'bunny' gem. Install with: gem install bunny"
      end

      def enqueue(message)
        queue = get_queue(message.topic)
        queue.publish(message.to_json, persistent: true)
      end

      def dequeue(topic)
        queue = get_queue(topic)
        delivery_info, _properties, payload = queue.pop
        return nil unless payload

        data = JSON.parse(payload)
        msg = Tina4::Job.new(
          topic: data["topic"],
          payload: data["payload"],
          id: data["id"]
        )
        @last_delivery_tag = delivery_info.delivery_tag
        msg
      end

      def acknowledge(_message)
        @channel.acknowledge(@last_delivery_tag) if @last_delivery_tag
      end

      def requeue(message)
        enqueue(message)
      end

      def dead_letter(message)
        dlq = get_queue("#{message.topic}.dead_letter")
        dlq.publish(message.to_json, persistent: true)
      end

      def size(topic)
        queue = get_queue(topic)
        queue.message_count
      end

      def close
        @channel&.close
        @connection&.close
      end

      private

      def get_queue(topic)
        @queues[topic] ||= @channel.queue(topic, durable: true)
      end
    end
  end
end
