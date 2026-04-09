# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Job do
  describe "#initialize" do
    it "generates a UUID id" do
      msg = Tina4::Job.new(topic: "emails", payload: { to: "alice@test.com" })
      expect(msg.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "accepts a custom id" do
      msg = Tina4::Job.new(topic: "emails", payload: {}, id: "custom-123")
      expect(msg.id).to eq("custom-123")
    end

    it "stores topic and payload" do
      msg = Tina4::Job.new(topic: "orders", payload: { item: "book" })
      expect(msg.topic).to eq("orders")
      expect(msg.payload).to eq({ item: "book" })
    end

    it "starts with pending status" do
      msg = Tina4::Job.new(topic: "t", payload: {})
      expect(msg.status).to eq(:pending)
    end

    it "starts with 0 attempts" do
      msg = Tina4::Job.new(topic: "t", payload: {})
      expect(msg.attempts).to eq(0)
    end

    it "records created_at as Time" do
      msg = Tina4::Job.new(topic: "t", payload: {})
      expect(msg.created_at).to be_a(Time)
    end
  end

  describe "#to_hash" do
    it "returns a hash representation" do
      msg = Tina4::Job.new(topic: "emails", payload: { to: "bob" })
      h = msg.to_hash
      expect(h[:topic]).to eq("emails")
      expect(h[:payload]).to eq({ to: "bob" })
      expect(h[:status]).to eq(:pending)
      expect(h[:attempts]).to eq(0)
      expect(h[:id]).to be_a(String)
      expect(h[:created_at]).to be_a(String)
    end
  end

  describe "#to_json" do
    it "returns valid JSON" do
      msg = Tina4::Job.new(topic: "t", payload: { key: "value" })
      parsed = JSON.parse(msg.to_json)
      expect(parsed["topic"]).to eq("t")
    end
  end

  describe "#increment_attempts!" do
    it "increments attempts by 1" do
      msg = Tina4::Job.new(topic: "t", payload: {})
      msg.increment_attempts!
      expect(msg.attempts).to eq(1)
      msg.increment_attempts!
      expect(msg.attempts).to eq(2)
    end
  end

  describe "#status=" do
    it "allows changing status" do
      msg = Tina4::Job.new(topic: "t", payload: {})
      msg.status = :processing
      expect(msg.status).to eq(:processing)
      msg.status = :completed
      expect(msg.status).to eq(:completed)
    end
  end
end

RSpec.describe Tina4::QueueBackends::LiteBackend do
  let(:tmp_dir) { Dir.mktmpdir("tina4_queue_test") }
  subject(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmp_dir) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  describe "#enqueue and #dequeue" do
    it "enqueues and dequeues a message (FIFO)" do
      msg1 = Tina4::Job.new(topic: "emails", payload: { seq: 1 })
      msg2 = Tina4::Job.new(topic: "emails", payload: { seq: 2 })
      backend.enqueue(msg1)
      sleep(0.01) # ensure different mtime
      backend.enqueue(msg2)

      dequeued = backend.dequeue("emails")
      expect(dequeued).not_to be_nil
      expect(dequeued.payload["seq"]).to eq(1)
    end

    it "returns nil when queue is empty" do
      expect(backend.dequeue("nonexistent")).to be_nil
    end

    it "removes the message file on dequeue" do
      msg = Tina4::Job.new(topic: "tasks", payload: {})
      backend.enqueue(msg)
      backend.dequeue("tasks")
      expect(backend.size("tasks")).to eq(0)
    end
  end

  describe "#size" do
    it "returns 0 for empty topic" do
      expect(backend.size("empty")).to eq(0)
    end

    it "returns the correct count" do
      3.times { |i| backend.enqueue(Tina4::Job.new(topic: "bulk", payload: { i: i })) }
      expect(backend.size("bulk")).to eq(3)
    end
  end

  describe "#requeue" do
    it "re-adds a message to the queue" do
      msg = Tina4::Job.new(topic: "retry", payload: { data: "x" })
      backend.enqueue(msg)
      dequeued = backend.dequeue("retry")
      expect(backend.size("retry")).to eq(0)
      backend.requeue(dequeued)
      expect(backend.size("retry")).to eq(1)
    end
  end

  describe "#dead_letter" do
    it "moves message to dead letter directory" do
      msg = Tina4::Job.new(topic: "fail", payload: {})
      backend.dead_letter(msg)
      dead_letter_path = File.join(tmp_dir, "dead_letter", "#{msg.id}.json")
      expect(File.exist?(dead_letter_path)).to be true
    end
  end

  describe "#topics" do
    it "lists active topics" do
      backend.enqueue(Tina4::Job.new(topic: "alpha", payload: {}))
      backend.enqueue(Tina4::Job.new(topic: "beta", payload: {}))
      topics = backend.topics
      expect(topics).to include("alpha")
      expect(topics).to include("beta")
      expect(topics).not_to include("dead_letter")
    end
  end

  describe "topic isolation" do
    it "keeps topics independent" do
      backend.enqueue(Tina4::Job.new(topic: "a", payload: { type: "a" }))
      backend.enqueue(Tina4::Job.new(topic: "b", payload: { type: "b" }))

      dequeued_a = backend.dequeue("a")
      expect(dequeued_a.payload["type"]).to eq("a")
      expect(backend.size("b")).to eq(1)
    end
  end
end

RSpec.describe "Queue batch operations" do
  describe "pop_batch" do
    it "returns up to count jobs as an array" do
      queue = Tina4::Queue.new(topic: "batch_test")
      queue.push({ n: 1 })
      queue.push({ n: 2 })
      queue.push({ n: 3 })
      jobs = queue.pop_batch(2)
      expect(jobs).to be_an(Array)
      expect(jobs.length).to eq(2)
      queue.clear
    end

    it "returns partial batch when fewer jobs available" do
      queue = Tina4::Queue.new(topic: "batch_partial")
      queue.push({ n: 1 })
      jobs = queue.pop_batch(10)
      expect(jobs.length).to eq(1)
      queue.clear
    end

    it "returns empty array when queue is empty" do
      queue = Tina4::Queue.new(topic: "batch_empty")
      queue.clear
      jobs = queue.pop_batch(5)
      expect(jobs).to eq([])
    end
  end

  describe "consume with batch_size" do
    it "yields arrays of jobs when batch_size > 1" do
      queue = Tina4::Queue.new(topic: "batch_consume")
      queue.clear
      5.times { |i| queue.push({ n: i }) }
      batches = []
      queue.consume(batch_size: 2, poll_interval: 0) do |jobs|
        batches << jobs
        jobs.each(&:complete)
      end
      expect(batches.flatten.length).to eq(5)
      expect(batches.all? { |b| b.is_a?(Array) }).to be true
    end
  end

  describe "process with batch_size" do
    it "passes arrays of jobs to handler when batch_size > 1" do
      queue = Tina4::Queue.new(topic: "batch_process")
      queue.clear
      6.times { |i| queue.push({ n: i }) }
      received = []
      queue.process(batch_size: 3) do |jobs|
        jobs.each do |job|
          received << job.payload[:n]
          job.complete
        end
      end
      expect(received.length).to eq(6)
    end
  end
end

RSpec.describe Tina4::Queue do
  let(:tmp_dir) { Dir.mktmpdir("tina4_queue_unified_test") }
  let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmp_dir) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  describe "#push and #pop" do
    it "pushes and pops using the unified API" do
      queue = Tina4::Queue.new(topic: "tasks", backend: backend)
      queue.push({ action: "send_email" })
      msg = queue.pop
      expect(msg).not_to be_nil
      expect(msg.payload["action"]).to eq("send_email")
    end

    it "returns nil when empty" do
      queue = Tina4::Queue.new(topic: "empty", backend: backend)
      expect(queue.pop).to be_nil
    end

    it "supports size" do
      queue = Tina4::Queue.new(topic: "sized", backend: backend)
      expect(queue.size).to eq(0)
      queue.push({ a: 1 })
      queue.push({ b: 2 })
      expect(queue.size).to eq(2)
    end
  end

  describe "backend auto-detection" do
    it "defaults to lite backend when no env set" do
      ENV.delete("TINA4_QUEUE_BACKEND")
      queue = Tina4::Queue.new(topic: "auto")
      expect(queue.backend).to be_a(Tina4::QueueBackends::LiteBackend)
    end

    it "uses lite for 'file' backend" do
      queue = Tina4::Queue.new(topic: "auto", backend: :file)
      expect(queue.backend).to be_a(Tina4::QueueBackends::LiteBackend)
    end

    it "uses lite for 'lite' backend" do
      queue = Tina4::Queue.new(topic: "auto", backend: :lite)
      expect(queue.backend).to be_a(Tina4::QueueBackends::LiteBackend)
    end

    it "raises for unknown backend" do
      expect {
        Tina4::Queue.new(topic: "bad", backend: :redis)
      }.to raise_error(ArgumentError, /Unknown queue backend/)
    end

    it "accepts a backend instance directly (legacy)" do
      queue = Tina4::Queue.new(topic: "legacy", backend: backend)
      queue.push({ test: true })
      expect(queue.size).to eq(1)
    end
  end

  describe "#dead_letters" do
    it "delegates to backend" do
      queue = Tina4::Queue.new(topic: "dead", backend: backend, max_retries: 1)
      # Push a message and move it to dead letter
      msg = Tina4::Job.new(topic: "dead", payload: { x: 1 })
      backend.dead_letter(msg)
      dead = queue.dead_letters
      expect(dead).to be_an(Array)
    end
  end

  describe "#retry_failed" do
    it "delegates to backend" do
      queue = Tina4::Queue.new(topic: "retry", backend: backend, max_retries: 3)
      count = queue.retry_failed
      expect(count).to eq(0)
    end
  end

  describe "#purge" do
    it "delegates to backend" do
      queue = Tina4::Queue.new(topic: "purge", backend: backend)
      count = queue.purge("completed")
      expect(count).to eq(0)
    end
  end

  describe "resolve_backend class method" do
    it "resolves lite by default" do
      ENV.delete("TINA4_QUEUE_BACKEND")
      b = Tina4::Queue.resolve_backend
      expect(b).to be_a(Tina4::QueueBackends::LiteBackend)
    end

    it "resolves lite for 'file'" do
      b = Tina4::Queue.resolve_backend("file")
      expect(b).to be_a(Tina4::QueueBackends::LiteBackend)
    end

    it "raises for unknown" do
      expect {
        Tina4::Queue.resolve_backend("unknown")
      }.to raise_error(ArgumentError)
    end
  end
end

