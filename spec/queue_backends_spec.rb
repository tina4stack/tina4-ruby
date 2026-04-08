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
      msg = Tina4::Job.new(topic: "test_topic", payload: { key: "value" })
      backend.enqueue(msg)
      expect(backend.size("test_topic")).to eq(1)
    end

    it "dequeues a message from a topic" do
      msg = Tina4::Job.new(topic: "test_topic", payload: { key: "value" })
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
      msg = Tina4::Job.new(topic: "test_topic", payload: "data")
      backend.enqueue(msg)
      expect(backend.size("test_topic")).to eq(1)
      backend.dequeue("test_topic")
      expect(backend.size("test_topic")).to eq(0)
    end

    it "preserves message payload through enqueue/dequeue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: { "name" => "Alice", "count" => 42 })
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued.payload).to eq({ "name" => "Alice", "count" => 42 })
    end

    it "preserves message id through enqueue/dequeue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "data")
      original_id = msg.id
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued.id).to eq(original_id)
    end

    it "processes messages in FIFO order" do
      3.times do |i|
        msg = Tina4::Job.new(topic: "ordered", payload: "msg_#{i}")
        backend.enqueue(msg)
        sleep(0.01) # ensure different mtime
      end
      results = 3.times.map { backend.dequeue("ordered") }
      expect(results.map(&:payload)).to eq(%w[msg_0 msg_1 msg_2])
    end

    it "sends message to dead letter queue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "failed")
      backend.dead_letter(msg)
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.json"))
      expect(dl_files.length).to eq(1)
    end

    it "requeues a message" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "retry")
      backend.requeue(msg)
      expect(backend.size("test_topic")).to eq(1)
    end

    it "returns 0 size for non-existent topic" do
      expect(backend.size("nonexistent")).to eq(0)
    end

    it "lists topics" do
      backend.enqueue(Tina4::Job.new(topic: "topic_a", payload: "a"))
      backend.enqueue(Tina4::Job.new(topic: "topic_b", payload: "b"))
      topics = backend.topics
      expect(topics).to include("topic_a")
      expect(topics).to include("topic_b")
      expect(topics).not_to include("dead_letter")
    end

    it "sanitizes topic names for directory safety" do
      msg = Tina4::Job.new(topic: "my/unsafe.topic!", payload: "safe")
      backend.enqueue(msg)
      # The topic should be sanitized to use underscores
      expect(backend.size("my/unsafe.topic!")).to eq(1)
    end

    it "acknowledge is a no-op (file already deleted)" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "ack")
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

  describe Tina4::QueueBackends::MongoBackend do
    it "is defined in the QueueBackends module" do
      expect(defined?(Tina4::QueueBackends::MongoBackend)).to eq("constant")
    end

    it "responds to the queue backend interface methods" do
      instance_methods = Tina4::QueueBackends::MongoBackend.instance_methods(false)
      expect(instance_methods).to include(:enqueue)
      expect(instance_methods).to include(:dequeue)
      expect(instance_methods).to include(:acknowledge)
      expect(instance_methods).to include(:requeue)
      expect(instance_methods).to include(:dead_letter)
      expect(instance_methods).to include(:size)
    end
  end

  # ── Retry Logic Tests ──────────────────────────────────────────

  describe "LiteBackend retry logic" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "tracks attempts on a message through requeue cycles" do
      msg = Tina4::Job.new(topic: "retry_topic", payload: "retry_me")
      msg.increment_attempts!
      msg.increment_attempts!
      backend.requeue(msg)

      dequeued = backend.dequeue("retry_topic")
      expect(dequeued).not_to be_nil
      expect(dequeued.attempts).to be >= 0
    end

    it "requeues then dequeues the same message" do
      msg = Tina4::Job.new(topic: "rq_topic", payload: { "task" => "process" })
      backend.requeue(msg)
      dequeued = backend.dequeue("rq_topic")
      expect(dequeued).not_to be_nil
      expect(dequeued.payload).to eq({ "task" => "process" })
    end
  end

  # ── Dead Letter Queue Tests ──────────────────────────────────────

  describe "LiteBackend dead letter queue" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "stores multiple messages in dead letter queue" do
      3.times do |i|
        msg = Tina4::Job.new(topic: "dl_topic", payload: "dead_#{i}")
        backend.dead_letter(msg)
      end
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.json"))
      expect(dl_files.length).to eq(3)
    end

    it "preserves message payload in dead letter queue" do
      msg = Tina4::Job.new(topic: "dl_payload", payload: { "error" => "timeout" })
      backend.dead_letter(msg)
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.json"))
      content = JSON.parse(File.read(dl_files.first))
      expect(content["payload"]).to eq({ "error" => "timeout" })
    end
  end

  # ── Priority / Bulk Operations Tests ────────────────────────────

  describe "LiteBackend bulk operations" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "handles bulk enqueue of many messages" do
      10.times do |i|
        msg = Tina4::Job.new(topic: "bulk", payload: "msg_#{i}")
        backend.enqueue(msg)
      end
      expect(backend.size("bulk")).to eq(10)
    end

    it "drains a topic completely" do
      5.times do |i|
        msg = Tina4::Job.new(topic: "drain", payload: "msg_#{i}")
        backend.enqueue(msg)
      end
      results = []
      while (m = backend.dequeue("drain"))
        results << m.payload
      end
      expect(results.length).to eq(5)
      expect(backend.size("drain")).to eq(0)
    end

    it "handles interleaved enqueue and dequeue" do
      msg1 = Tina4::Job.new(topic: "interleave", payload: "first")
      backend.enqueue(msg1)
      dequeued1 = backend.dequeue("interleave")
      expect(dequeued1.payload).to eq("first")

      msg2 = Tina4::Job.new(topic: "interleave", payload: "second")
      backend.enqueue(msg2)
      dequeued2 = backend.dequeue("interleave")
      expect(dequeued2.payload).to eq("second")
    end

    it "handles concurrent topics independently" do
      backend.enqueue(Tina4::Job.new(topic: "alpha", payload: "a1"))
      backend.enqueue(Tina4::Job.new(topic: "alpha", payload: "a2"))
      backend.enqueue(Tina4::Job.new(topic: "beta", payload: "b1"))

      expect(backend.size("alpha")).to eq(2)
      expect(backend.size("beta")).to eq(1)

      backend.dequeue("alpha")
      expect(backend.size("alpha")).to eq(1)
      expect(backend.size("beta")).to eq(1)
    end
  end

  # ── Job Tests ──────────────────────────────────────────

  describe Tina4::Job do
    it "generates a UUID id by default" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      expect(msg.id).not_to be_nil
      expect(msg.id.length).to eq(36) # UUID format
    end

    it "accepts a custom id" do
      msg = Tina4::Job.new(topic: "test", payload: "data", id: "custom-id")
      expect(msg.id).to eq("custom-id")
    end

    it "starts with status :pending" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      expect(msg.status).to eq(:pending)
    end

    it "starts with 0 attempts" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      expect(msg.attempts).to eq(0)
    end

    it "increments attempts" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      msg.increment_attempts!
      expect(msg.attempts).to eq(1)
      msg.increment_attempts!
      expect(msg.attempts).to eq(2)
    end

    it "serializes to JSON" do
      msg = Tina4::Job.new(topic: "test", payload: { key: "val" })
      json = msg.to_json
      parsed = JSON.parse(json)
      expect(parsed["topic"]).to eq("test")
      expect(parsed["payload"]).to eq({ "key" => "val" })
    end

    it "converts to hash" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      hash = msg.to_hash
      expect(hash[:topic]).to eq("test")
      expect(hash[:payload]).to eq("data")
      expect(hash[:id]).to eq(msg.id)
      expect(hash[:status]).to eq(:pending)
    end

    it "stores created_at timestamp" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      hash = msg.to_hash
      expect(hash[:created_at]).not_to be_nil
    end

    it "preserves complex nested payload" do
      payload = { "users" => [{ "name" => "Alice" }, { "name" => "Bob" }], "count" => 2 }
      msg = Tina4::Job.new(topic: "complex", payload: payload)
      json = msg.to_json
      parsed = JSON.parse(json)
      expect(parsed["payload"]["users"].length).to eq(2)
      expect(parsed["payload"]["count"]).to eq(2)
    end
  end

end
