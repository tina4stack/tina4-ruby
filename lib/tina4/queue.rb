# frozen_string_literal: true
require "json"
require "securerandom"

module Tina4
  class QueueMessage
    attr_reader :id, :topic, :payload, :created_at, :attempts
    attr_accessor :status

    def initialize(topic:, payload:, id: nil)
      @id = id || SecureRandom.uuid
      @topic = topic
      @payload = payload
      @created_at = Time.now
      @attempts = 0
      @status = :pending
    end

    def to_hash
      {
        id: @id,
        topic: @topic,
        payload: @payload,
        created_at: @created_at.iso8601,
        attempts: @attempts,
        status: @status
      }
    end

    def to_json(*_args)
      JSON.generate(to_hash)
    end

    def increment_attempts!
      @attempts += 1
    end
  end

  class Producer
    def initialize(backend: nil)
      @backend = backend || Tina4::QueueBackends::LiteBackend.new
    end

    def publish(topic, payload)
      message = QueueMessage.new(topic: topic, payload: payload)
      @backend.enqueue(message)
      Tina4::Debug.debug("Message published to #{topic}: #{message.id}")
      message
    end

    def publish_batch(topic, payloads)
      payloads.map { |p| publish(topic, p) }
    end
  end

  class Consumer
    def initialize(topic:, backend: nil, max_retries: 3)
      @topic = topic
      @backend = backend || Tina4::QueueBackends::LiteBackend.new
      @max_retries = max_retries
      @handlers = []
      @running = false
    end

    def on_message(&block)
      @handlers << block
    end

    def start(poll_interval: 1)
      @running = true
      Tina4::Debug.info("Consumer started for topic: #{@topic}")

      while @running
        message = @backend.dequeue(@topic)
        if message
          process_message(message)
        else
          sleep(poll_interval)
        end
      end
    end

    def stop
      @running = false
      Tina4::Debug.info("Consumer stopped for topic: #{@topic}")
    end

    def process_one
      message = @backend.dequeue(@topic)
      process_message(message) if message
    end

    private

    def process_message(message)
      message.increment_attempts!
      message.status = :processing

      @handlers.each do |handler|
        handler.call(message)
      end

      message.status = :completed
      @backend.acknowledge(message)
    rescue => e
      Tina4::Debug.error("Queue message failed: #{message.id} - #{e.message}")
      message.status = :failed

      if message.attempts < @max_retries
        message.status = :pending
        @backend.requeue(message)
      else
        @backend.dead_letter(message)
      end
    end
  end
end
