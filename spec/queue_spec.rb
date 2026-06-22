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

  # Contract: queues are isolated by topic and by storage path. A job pushed to
  # one topic must never leak into another, and a queue on a fresh storage path
  # must start empty. Locks in the per-topic layout so a backend change can't
  # silently cross-contaminate.
  describe "isolation contract" do
    it "isolates topics on the same backend/path" do
      topic_a = Tina4::Queue.new(topic: "topic_a", backend: backend)
      topic_b = Tina4::Queue.new(topic: "topic_b", backend: backend)

      topic_a.push({ to: "a" })
      topic_a.push({ to: "a2" })

      # topic_b shares the base path but must see none of topic_a's jobs.
      expect(topic_b.size).to eq(0)
      expect(topic_b.pop).to be_nil
      expect(topic_a.size).to eq(2)
    end

    it "leaves the other topic intact when one is drained" do
      topic_a = Tina4::Queue.new(topic: "topic_a", backend: backend)
      topic_b = Tina4::Queue.new(topic: "topic_b", backend: backend)
      topic_a.push({ to: "a" })
      topic_b.push({ to: "b" })

      expect(topic_a.pop.payload["to"]).to eq("a")
      expect(topic_a.pop).to be_nil

      # topic_b is untouched.
      expect(topic_b.size).to eq(1)
      expect(topic_b.pop.payload["to"]).to eq("b")
    end

    it "starts empty on a fresh storage path" do
      first = Tina4::Queue.new(topic: "jobs", backend: backend)
      first.push({ n: 1 })
      first.push({ n: 2 })
      expect(first.size).to eq(2)

      # A second backend on a DIFFERENT base path sees zero jobs.
      other_dir = Dir.mktmpdir("tina4_queue_iso_test")
      begin
        other_backend = Tina4::QueueBackends::LiteBackend.new(dir: other_dir)
        second = Tina4::Queue.new(topic: "jobs", backend: other_backend)
        expect(second.size).to eq(0)
        expect(second.pop).to be_nil
      ensure
        FileUtils.rm_rf(other_dir)
      end
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
    it "returns Hashes for jobs that exhausted their retries" do
      queue = Tina4::Queue.new(topic: "dead", backend: backend, max_retries: 1)
      queue.push({ x: 1 })
      queue.pop.fail("boom")  # attempts=1 >= max_retries=1 → dead-lettered

      dead = queue.dead_letters
      expect(dead).to be_an(Array)
      expect(dead.length).to eq(1)
      expect(dead.first).to be_a(Hash)
      expect(dead.first["status"]).to eq("dead")
      expect(dead.first["attempts"]).to eq(1)
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

  # ── Priority-ordered pop (priority DESC, created_at ASC) ──────────
  describe "priority-ordered pop" do
    it "pops the highest-priority job first" do
      queue = Tina4::Queue.new(topic: "prio", backend: backend)
      queue.push({ n: "low" }, priority: 0)
      sleep(0.002)
      queue.push({ n: "high" }, priority: 5)
      sleep(0.002)
      queue.push({ n: "mid" }, priority: 2)

      order = 3.times.map { queue.pop.payload["n"] }
      expect(order).to eq(%w[high mid low])
    end

    it "breaks priority ties oldest-first (created_at ASC)" do
      queue = Tina4::Queue.new(topic: "prio_tie", backend: backend)
      queue.push({ n: "a" }, priority: 1)
      sleep(0.002)
      queue.push({ n: "b" }, priority: 1)
      sleep(0.002)
      queue.push({ n: "c" }, priority: 1)

      order = 3.times.map { queue.pop.payload["n"] }
      expect(order).to eq(%w[a b c])
    end

    it "applies the same ordering to pop_batch" do
      queue = Tina4::Queue.new(topic: "prio_batch", backend: backend)
      queue.push({ n: "low" }, priority: 0)
      sleep(0.002)
      queue.push({ n: "high" }, priority: 9)

      jobs = queue.pop_batch(2)
      expect(jobs.map { |j| j.payload["n"] }).to eq(%w[high low])
    end

    it "skips delayed jobs until they become available" do
      queue = Tina4::Queue.new(topic: "prio_delay", backend: backend)
      queue.push({ n: "later" }, priority: 9, delay_seconds: 60)
      queue.push({ n: "now" }, priority: 0)

      job = queue.pop
      expect(job.payload["n"]).to eq("now")
      expect(queue.pop).to be_nil
    end
  end

  # ── Automatic retry → dead-letter on job.fail() ──────────────────
  describe "automatic retry then dead-letter" do
    it "executes a persistently-failing job exactly max_retries times then dead-letters it" do
      queue = Tina4::Queue.new(topic: "auto_dl", backend: backend, max_retries: 3)
      queue.push({ task: "boom" })

      executions = 0
      # Drain loop: consume keeps re-popping the auto-re-enqueued job until it
      # is dead-lettered. poll_interval: 0 returns when the queue is empty —
      # no manual retry_failed needed.
      queue.consume(poll_interval: 0) do |job|
        executions += 1
        job.fail("kaboom #{executions}")
      end

      expect(executions).to eq(3)
      dead = queue.dead_letters
      expect(dead.length).to eq(1)
      expect(dead.first["attempts"]).to eq(3)
      expect(dead.first["error"]).to eq("kaboom 3")
      expect(queue.size).to eq(0)          # nothing left pending
      expect(queue.failed).to eq([])       # no retryable-pending remnants
    end

    it "re-enqueues a failing job under the limit (does not dead-letter early)" do
      queue = Tina4::Queue.new(topic: "under_limit", backend: backend, max_retries: 3)
      queue.push({ task: "x" })

      job = queue.pop
      job.fail("first failure")

      expect(queue.dead_letters).to eq([])  # not dead yet
      expect(queue.size).to eq(1)           # back in pending
      requeued = queue.pop
      expect(requeued.attempts).to eq(1)
      expect(requeued.error).to eq("first failure")  # prior error carried over
    end

    it "does not dead-letter a job that succeeds on its second attempt" do
      queue = Tina4::Queue.new(topic: "succeed_2nd", backend: backend, max_retries: 3)
      queue.push({ task: "retry-then-ok" })

      attempts = 0
      queue.consume(poll_interval: 0) do |job|
        attempts += 1
        if attempts == 1
          job.fail("transient")
        else
          job.complete
        end
      end

      expect(attempts).to eq(2)
      expect(queue.dead_letters).to eq([])
      expect(queue.size).to eq(0)
    end

    it "delays the re-enqueue when retry_backoff is set" do
      queue = Tina4::Queue.new(topic: "backoff", backend: backend, max_retries: 3, retry_backoff: 60)
      queue.push({ task: "x" })

      job = queue.pop
      job.fail("transient")

      expect(queue.size).to eq(1)   # written back to pending...
      expect(queue.pop).to be_nil   # ...but not yet available (delayed)
    end

    it "treats reject as an alias for fail" do
      queue = Tina4::Queue.new(topic: "reject_alias", backend: backend, max_retries: 1)
      queue.push({ task: "x" })

      job = queue.pop
      job.reject("rejected")

      # max_retries=1 → first failure dead-letters immediately
      expect(queue.dead_letters.length).to eq(1)
      expect(queue.dead_letters.first["error"]).to eq("rejected")
    end

    it "keeps complete terminal — never re-enqueues or dead-letters" do
      queue = Tina4::Queue.new(topic: "complete_terminal", backend: backend, max_retries: 3)
      queue.push({ task: "x" })

      queue.pop.complete
      expect(queue.size).to eq(0)
      expect(queue.dead_letters).to eq([])
    end
  end

  # ── Lifecycle consistency ────────────────────────────────────────
  describe "lifecycle consistency" do
    it "failed returns retryable pending jobs (0 < attempts < max_retries)" do
      queue = Tina4::Queue.new(topic: "lc_failed", backend: backend, max_retries: 3)
      queue.push({ task: "x" })
      queue.pop.fail("once")  # attempts=1 → re-enqueued to pending

      failed = queue.failed
      expect(failed.length).to eq(1)
      expect(failed.first["attempts"]).to eq(1)
      expect(queue.dead_letters).to eq([])
    end

    it "size(status:) and purge(status:) scan the dead-letter store for dead states" do
      queue = Tina4::Queue.new(topic: "lc_size", backend: backend, max_retries: 1)
      queue.push({ task: "x" })
      queue.pop.fail("boom")  # dead immediately

      expect(queue.size(status: "dead")).to eq(1)
      expect(queue.size(status: "failed")).to eq(1)
      expect(queue.size).to eq(0)  # pending

      expect(queue.purge("dead")).to eq(1)
      expect(queue.size(status: "dead")).to eq(0)
    end

    it "Queue#retry(job_id) always revives a specific dead-letter" do
      queue = Tina4::Queue.new(topic: "lc_retry", backend: backend, max_retries: 1)
      pushed = queue.push({ task: "deadme" })
      queue.pop.fail("boom")  # dead immediately (attempts=1 >= max_retries=1)

      expect(queue.dead_letters.length).to eq(1)
      expect(queue.retry(pushed.id)).to be true
      expect(queue.dead_letters).to eq([])
      expect(queue.size).to eq(1)
    end

    it "retry_failed revives dead-letters under a raised limit" do
      queue = Tina4::Queue.new(topic: "lc_retry_failed", backend: backend, max_retries: 2)
      queue.push({ task: "z" })
      2.times { queue.pop&.fail("nope") }  # exhausts to dead at attempts=2

      expect(queue.dead_letters.length).to eq(1)
      revived = queue.retry_failed(max_retries: 5)  # raised limit revives it
      expect(revived).to eq(1)
      expect(queue.size).to eq(1)
    end

    it "job.retry always re-enqueues and increments attempts" do
      queue = Tina4::Queue.new(topic: "lc_job_retry", backend: backend, max_retries: 3)
      queue.push({ task: "y" })

      job = queue.pop
      job.retry
      expect(job.attempts).to eq(1)
      expect(queue.size).to eq(1)
    end
  end

  # ── consume(id:) / pop_by_id bug fixes ───────────────────────────
  describe "consume(id:) and pop_by_id" do
    it "consume(topic, id:) retrieves exactly the matching job" do
      queue = Tina4::Queue.new(topic: "byid", backend: backend)
      queue.push({ k: 1 })
      target = queue.push({ k: 2 })
      queue.push({ k: 3 })

      got = nil
      queue.consume("byid", id: target.id, poll_interval: 0) { |job| got = job }

      expect(got).not_to be_nil
      expect(got.id).to eq(target.id)
      expect(got.payload["k"]).to eq(2)
      expect(queue.size).to eq(2)  # only the targeted job was claimed
    end

    it "consume(id:) does not raise ArgumentError (signature reconciled)" do
      queue = Tina4::Queue.new(topic: "byid_noraise", backend: backend)
      pushed = queue.push({ k: 1 })
      expect {
        queue.consume("byid_noraise", id: pushed.id, poll_interval: 0) { |_job| }
      }.not_to raise_error
    end

    it "pop_by_id returns the matching job and removes it from the queue" do
      queue = Tina4::Queue.new(topic: "pbid", backend: backend)
      first = queue.push({ k: 1 })
      queue.push({ k: 2 })

      popped = queue.pop_by_id(first.id)
      expect(popped).not_to be_nil
      expect(popped.payload["k"]).to eq(1)
      expect(queue.size).to eq(1)
    end

    it "pop_by_id returns nil when no job matches" do
      queue = Tina4::Queue.new(topic: "pbid_miss", backend: backend)
      queue.push({ k: 1 })
      expect(queue.pop_by_id("does-not-exist")).to be_nil
    end

    it "a job popped by id carries the queue reference so fail() persists" do
      queue = Tina4::Queue.new(topic: "pbid_fail", backend: backend, max_retries: 1)
      pushed = queue.push({ k: 1 })

      job = queue.pop_by_id(pushed.id)
      job.fail("boom")  # max_retries=1 → dead-lettered
      expect(queue.dead_letters.length).to eq(1)
    end
  end
end

