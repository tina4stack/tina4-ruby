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

    # Mark this job as completed.
    def complete
      @status = :completed
    end

    # Mark this job as failed with a reason.
    def fail(reason = "")
      @status = :failed
      @error = reason
      @attempts += 1
    end

    # Reject this job with a reason. Alias for fail().
    def reject(reason = "")
      fail(reason)
    end

    attr_reader :error
  end

  class Producer
    def initialize(backend: nil)
      @backend = backend || Tina4::Queue.resolve_backend
    end

    def publish(topic, payload)
      message = QueueMessage.new(topic: topic, payload: payload)
      @backend.enqueue(message)
      Tina4::Log.debug("Message published to #{topic}: #{message.id}")
      message
    end

    def publish_batch(topic, payloads)
      payloads.map { |p| publish(topic, p) }
    end

    # Unified push method matching the cross-framework API.
    def push(topic, payload)
      publish(topic, payload)
    end
  end

  # Queue — unified wrapper for queue management operations.
  # Auto-detects backend from TINA4_QUEUE_BACKEND env var.
  #
  # Usage:
  #   # Auto-detect from env (default: lite/file backend)
  #   queue = Queue.new(topic: "tasks")
  #
  #   # Explicit backend
  #   queue = Queue.new(topic: "tasks", backend: :rabbitmq)
  #
  #   # Or pass a backend instance directly (legacy)
  #   queue = Queue.new(topic: "tasks", backend: my_backend)
  class Queue
    attr_reader :topic, :max_retries

    def initialize(topic:, backend: nil, max_retries: 3)
      @topic = topic
      @max_retries = max_retries
      @backend = resolve_backend_arg(backend)
    end

    # Push a job onto the queue. Returns the QueueMessage.
    def push(payload)
      message = QueueMessage.new(topic: @topic, payload: payload)
      @backend.enqueue(message)
      message
    end

    # Pop the next available job. Returns QueueMessage or nil.
    def pop
      @backend.dequeue(@topic)
    end

    # Get dead letter jobs — messages that exceeded max retries.
    def dead_letters
      return [] unless @backend.respond_to?(:dead_letters)
      @backend.dead_letters(@topic, max_retries: @max_retries)
    end

    # Delete messages by status (completed, failed, dead).
    def purge(status)
      return 0 unless @backend.respond_to?(:purge)
      @backend.purge(@topic, status)
    end

    # Re-queue failed messages (under max_retries) back to pending.
    # Returns the number of jobs re-queued.
    def retry_failed
      return 0 unless @backend.respond_to?(:retry_failed)
      @backend.retry_failed(@topic, max_retries: @max_retries)
    end

    # Produce a message onto a topic. Convenience wrapper around push().
    def produce(topic, payload)
      message = QueueMessage.new(topic: topic, payload: payload)
      @backend.enqueue(message)
      message
    end

    # Consume jobs from a topic using an Enumerator (yield pattern).
    #
    # Usage:
    #   queue.consume("emails") do |job|
    #     process(job)
    #   end
    #
    #   # Consume a specific job by ID:
    #   queue.consume("emails", id: "abc-123") do |job|
    #     process(job)
    #   end
    #
    #   # Or as an enumerator:
    #   queue.consume("emails").each { |job| process(job) }
    #
    def consume(topic = nil, id: nil, &block)
      topic ||= @topic

      if block_given?
        if id
          job = pop_by_id(topic, id)
          yield job if job
        else
          while (job = @backend.dequeue(topic))
            yield job
          end
        end
      else
        # Return an Enumerator when no block given
        Enumerator.new do |yielder|
          if id
            job = pop_by_id(topic, id)
            yielder << job if job
          else
            while (job = @backend.dequeue(topic))
              yielder << job
            end
          end
        end
      end
    end

    # Pop a specific job by ID from the queue.
    def pop_by_id(topic, id)
      return nil unless @backend.respond_to?(:find_by_id)
      @backend.find_by_id(topic, id)
    end

    # Get the number of pending messages.
    def size
      @backend.size(@topic)
    end

    # Get the underlying backend instance.
    def backend
      @backend
    end

    # Resolve the default backend from env vars.
    # Class method so Producer can also use it.
    def self.resolve_backend(name = nil)
      chosen = name || ENV.fetch("TINA4_QUEUE_BACKEND", "lite").downcase.strip

      case chosen.to_s
      when "lite", "file", "default"
        Tina4::QueueBackends::LiteBackend.new
      when "rabbitmq"
        config = resolve_rabbitmq_config
        Tina4::QueueBackends::RabbitmqBackend.new(config)
      when "kafka"
        config = resolve_kafka_config
        Tina4::QueueBackends::KafkaBackend.new(config)
      when "mongodb", "mongo"
        config = resolve_mongo_config
        Tina4::QueueBackends::MongoBackend.new(config)
      else
        raise ArgumentError, "Unknown queue backend: #{chosen.inspect}. Use 'lite', 'rabbitmq', 'kafka', or 'mongodb'."
      end
    end

    private

    def resolve_backend_arg(backend)
      # If a backend instance is passed directly (legacy), use it
      return backend if backend && !backend.is_a?(Symbol) && !backend.is_a?(String)
      # If a symbol or string name is passed, resolve it
      Queue.resolve_backend(backend)
    end

    def self.resolve_rabbitmq_config
      config = {}
      url = ENV["TINA4_QUEUE_URL"]
      if url
        config = parse_amqp_url(url)
      end
      config[:host] ||= ENV.fetch("TINA4_RABBITMQ_HOST", "localhost")
      config[:port] ||= (ENV["TINA4_RABBITMQ_PORT"] || 5672).to_i
      config[:username] ||= ENV.fetch("TINA4_RABBITMQ_USERNAME", "guest")
      config[:password] ||= ENV.fetch("TINA4_RABBITMQ_PASSWORD", "guest")
      config[:vhost] ||= ENV.fetch("TINA4_RABBITMQ_VHOST", "/")
      config
    end

    def self.resolve_kafka_config
      config = {}
      url = ENV["TINA4_QUEUE_URL"]
      if url
        config[:brokers] = url.sub("kafka://", "")
      end
      brokers = ENV["TINA4_KAFKA_BROKERS"]
      config[:brokers] = brokers if brokers
      config[:brokers] ||= "localhost:9092"
      config[:group_id] = ENV.fetch("TINA4_KAFKA_GROUP_ID", "tina4_consumer_group")
      config
    end

    def self.resolve_mongo_config
      config = {}
      uri = ENV["TINA4_MONGO_URI"]
      config[:uri] = uri if uri
      config[:host] = ENV.fetch("TINA4_MONGO_HOST", "localhost") unless uri
      config[:port] = (ENV["TINA4_MONGO_PORT"] || 27017).to_i unless uri
      username = ENV["TINA4_MONGO_USERNAME"]
      password = ENV["TINA4_MONGO_PASSWORD"]
      config[:username] = username if username
      config[:password] = password if password
      config[:db] = ENV.fetch("TINA4_MONGO_DB", "tina4")
      config[:collection] = ENV.fetch("TINA4_MONGO_COLLECTION", "tina4_queue")
      config
    end

    def self.parse_amqp_url(url)
      config = {}
      url = url.sub("amqp://", "").sub("amqps://", "")

      if url.include?("@")
        creds, rest = url.split("@", 2)
        if creds.include?(":")
          config[:username], config[:password] = creds.split(":", 2)
        else
          config[:username] = creds
        end
      else
        rest = url
      end

      if rest.include?("/")
        hostport, vhost = rest.split("/", 2)
        config[:vhost] = vhost.start_with?("/") ? vhost : "/#{vhost}" if vhost && !vhost.empty?
      else
        hostport = rest
      end

      if hostport.include?(":")
        host, port = hostport.split(":", 2)
        config[:host] = host
        config[:port] = port.to_i
      elsif hostport && !hostport.empty?
        config[:host] = hostport
      end

      config
    end
  end

  class Consumer
    def initialize(topic:, backend: nil, max_retries: 3)
      @topic = topic
      @backend = backend || Tina4::Queue.resolve_backend
      @max_retries = max_retries
      @handlers = []
      @running = false
    end

    def on_message(&block)
      @handlers << block
    end

    def start(poll_interval: 1)
      @running = true
      Tina4::Log.info("Consumer started for topic: #{@topic}")

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
      Tina4::Log.info("Consumer stopped for topic: #{@topic}")
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
      Tina4::Log.error("Queue message failed: #{message.id} - #{e.message}")
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
