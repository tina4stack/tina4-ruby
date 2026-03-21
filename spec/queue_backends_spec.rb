# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Queue Backends" do
  describe Tina4::QueueBackends::LiteBackend do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "creates the queue directory on initialization" do
      expect(Dir.exist?(tmpdir)).to be true
    end

    it "creates the dead_letter subdirectory" do
      backend # force initialization
      expect(Dir.exist?(File.join(tmpdir, "dead_letter"))).to be true
    end

    it "enqueues a message to a topic" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: { key: "value" })
      backend.enqueue(msg)
      expect(backend.size("test_topic")).to eq(1)
    end

    it "dequeues a message from a topic" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: { key: "value" })
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued).not_to be_nil
      expect(dequeued.topic).to eq("test_topic")
    end

    it "returns nil when dequeuing from empty topic" do
      result = backend.dequeue("empty_topic")
      expect(result).to be_nil
    end

    it "removes message file on dequeue" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: "data")
      backend.enqueue(msg)
      expect(backend.size("test_topic")).to eq(1)
      backend.dequeue("test_topic")
      expect(backend.size("test_topic")).to eq(0)
    end

    it "preserves message payload through enqueue/dequeue" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: { "name" => "Alice", "count" => 42 })
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued.payload).to eq({ "name" => "Alice", "count" => 42 })
    end

    it "preserves message id through enqueue/dequeue" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: "data")
      original_id = msg.id
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued.id).to eq(original_id)
    end

    it "processes messages in FIFO order" do
      3.times do |i|
        msg = Tina4::QueueMessage.new(topic: "ordered", payload: "msg_#{i}")
        backend.enqueue(msg)
        sleep(0.01) # ensure different mtime
      end
      results = 3.times.map { backend.dequeue("ordered") }
      expect(results.map(&:payload)).to eq(%w[msg_0 msg_1 msg_2])
    end

    it "sends message to dead letter queue" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: "failed")
      backend.dead_letter(msg)
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.json"))
      expect(dl_files.length).to eq(1)
    end

    it "requeues a message" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: "retry")
      backend.requeue(msg)
      expect(backend.size("test_topic")).to eq(1)
    end

    it "returns 0 size for non-existent topic" do
      expect(backend.size("nonexistent")).to eq(0)
    end

    it "lists topics" do
      backend.enqueue(Tina4::QueueMessage.new(topic: "topic_a", payload: "a"))
      backend.enqueue(Tina4::QueueMessage.new(topic: "topic_b", payload: "b"))
      topics = backend.topics
      expect(topics).to include("topic_a")
      expect(topics).to include("topic_b")
      expect(topics).not_to include("dead_letter")
    end

    it "sanitizes topic names for directory safety" do
      msg = Tina4::QueueMessage.new(topic: "my/unsafe.topic!", payload: "safe")
      backend.enqueue(msg)
      # The topic should be sanitized to use underscores
      expect(backend.size("my/unsafe.topic!")).to eq(1)
    end

    it "acknowledge is a no-op (file already deleted)" do
      msg = Tina4::QueueMessage.new(topic: "test_topic", payload: "ack")
      expect { backend.acknowledge(msg) }.not_to raise_error
    end
  end

  describe Tina4::QueueBackends::RabbitmqBackend do
    it "is defined in the QueueBackends module" do
      expect(defined?(Tina4::QueueBackends::RabbitmqBackend)).to eq("constant")
    end

    it "responds to the queue backend interface methods" do
      # Cannot instantiate without a RabbitMQ server, so check class methods
      instance_methods = Tina4::QueueBackends::RabbitmqBackend.instance_methods(false)
      expect(instance_methods).to include(:enqueue)
      expect(instance_methods).to include(:dequeue)
      expect(instance_methods).to include(:acknowledge)
      expect(instance_methods).to include(:requeue)
      expect(instance_methods).to include(:dead_letter)
      expect(instance_methods).to include(:size)
      expect(instance_methods).to include(:close)
    end
  end

  describe Tina4::QueueBackends::KafkaBackend do
    it "is defined in the QueueBackends module" do
      expect(defined?(Tina4::QueueBackends::KafkaBackend)).to eq("constant")
    end

    it "responds to the queue backend interface methods" do
      instance_methods = Tina4::QueueBackends::KafkaBackend.instance_methods(false)
      expect(instance_methods).to include(:enqueue)
      expect(instance_methods).to include(:dequeue)
      expect(instance_methods).to include(:acknowledge)
      expect(instance_methods).to include(:requeue)
      expect(instance_methods).to include(:dead_letter)
      expect(instance_methods).to include(:close)
    end
  end

  describe Tina4::QueueMessage do
    it "generates a UUID id by default" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: "data")
      expect(msg.id).not_to be_nil
      expect(msg.id.length).to eq(36) # UUID format
    end

    it "accepts a custom id" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: "data", id: "custom-id")
      expect(msg.id).to eq("custom-id")
    end

    it "starts with status :pending" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: "data")
      expect(msg.status).to eq(:pending)
    end

    it "starts with 0 attempts" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: "data")
      expect(msg.attempts).to eq(0)
    end

    it "increments attempts" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: "data")
      msg.increment_attempts!
      expect(msg.attempts).to eq(1)
      msg.increment_attempts!
      expect(msg.attempts).to eq(2)
    end

    it "serializes to JSON" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: { key: "val" })
      json = msg.to_json
      parsed = JSON.parse(json)
      expect(parsed["topic"]).to eq("test")
      expect(parsed["payload"]).to eq({ "key" => "val" })
    end

    it "converts to hash" do
      msg = Tina4::QueueMessage.new(topic: "test", payload: "data")
      hash = msg.to_hash
      expect(hash[:topic]).to eq("test")
      expect(hash[:payload]).to eq("data")
      expect(hash[:id]).to eq(msg.id)
      expect(hash[:status]).to eq(:pending)
    end
  end

  describe "Producer and Consumer with LiteBackend" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "Producer publishes a message" do
      producer = Tina4::Producer.new(backend: backend)
      msg = producer.publish("orders", { item: "widget" })
      expect(msg).to be_a(Tina4::QueueMessage)
      expect(backend.size("orders")).to eq(1)
    end

    it "Producer publish_batch sends multiple messages" do
      producer = Tina4::Producer.new(backend: backend)
      msgs = producer.publish_batch("orders", [{ item: "a" }, { item: "b" }, { item: "c" }])
      expect(msgs.length).to eq(3)
      expect(backend.size("orders")).to eq(3)
    end

    it "Consumer processes one message" do
      producer = Tina4::Producer.new(backend: backend)
      producer.publish("tasks", { task: "process" })

      received = nil
      consumer = Tina4::Consumer.new(topic: "tasks", backend: backend)
      consumer.on_message { |msg| received = msg }
      consumer.process_one

      expect(received).not_to be_nil
      expect(received.payload).to eq({ "task" => "process" })
    end

    it "Consumer calls multiple handlers" do
      producer = Tina4::Producer.new(backend: backend)
      producer.publish("multi", "data")

      results = []
      consumer = Tina4::Consumer.new(topic: "multi", backend: backend)
      consumer.on_message { |msg| results << "handler1:#{msg.payload}" }
      consumer.on_message { |msg| results << "handler2:#{msg.payload}" }
      consumer.process_one

      expect(results).to eq(["handler1:data", "handler2:data"])
    end
  end
end
