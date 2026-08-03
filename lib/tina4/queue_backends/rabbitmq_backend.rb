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
        msg = Tina4::Job.new(
          topic: data["topic"],
          payload: data["payload"],
          id: data["id"]
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
