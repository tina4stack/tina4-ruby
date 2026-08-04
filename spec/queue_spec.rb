# frozen_string_literal: true

require "spec_helper"
# Explicit: the live-Mongo group builds a per-example database name from
# SecureRandom. Do not lean on a transitive require from another gem.
require "securerandom"

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

# ── consume()/process()/produce() topic targeting (Bug A) ──────────
#
# consume(topic)/process(topic:) must honor the topic ARGUMENT, not the topic
# the Queue was constructed with. Regression lock mirroring the Python master:
# in Python pop() used the construction-time topic so consume("other") silently
# drained the wrong queue. Ruby's consume/process pass the argument topic
# straight to backend.dequeue(topic) and acks route by job.topic, so it has
# always honoured the argument — these tests guard against drift. Engine-
# agnostic (file/lite backend), so they cover every backend's read path.
RSpec.describe "Tina4::Queue consume/process topic targeting" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_queue_topic_test") }
  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def topic_queue(topic: "default", max_retries: 3)
    backend = Tina4::QueueBackends::LiteBackend.new(dir: tmp_dir, max_retries: max_retries)
    Tina4::Queue.new(topic: topic, backend: backend, max_retries: max_retries)
  end

  it "consume(topic) drains the argument topic, not the construction topic" do
    q = topic_queue(topic: "default")
    q.push({ "where" => "default" })             # lands on 'default'
    q.produce("alerts", { "where" => "alerts" }) # lands on 'alerts'

    drained = []
    q.consume("alerts", poll_interval: 0) do |job|
      drained << job.payload
      job.complete
    end
    expect(drained).to eq([{ "where" => "alerts" }])  # only alerts

    leftover = []
    q.consume("default", poll_interval: 0) do |job|
      leftover << job.payload
      job.complete
    end
    expect(leftover).to eq([{ "where" => "default" }])  # default untouched
  end

  it "consume() with no topic uses the construction topic" do
    q = topic_queue(topic: "orders")
    q.push({ "id" => 1 })
    drained = []
    q.consume(poll_interval: 0) { |job| drained << job.payload; job.complete }
    expect(drained).to eq([{ "id" => 1 }])
  end

  it "process(topic:) targets the requested topic" do
    q = topic_queue(topic: "default")
    q.produce("work", { "v" => 1 })
    q.produce("work", { "v" => 2 })
    seen = []
    q.process(topic: "work") do |job|
      seen << job.payload["v"]
      job.complete
    end
    expect(seen).to eq([1, 2])
  end

  it "isolates topics: draining one leaves the other intact" do
    q = topic_queue(topic: "default")
    3.times { |i| q.produce("orders", { "k" => "order", "i" => i }) }
    2.times { |i| q.produce("emails", { "k" => "email", "i" => i }) }

    drained = []
    q.consume("orders", poll_interval: 0) { |job| drained << job.payload; job.complete }
    expect(drained.length).to eq(3)
    expect(drained.all? { |d| d["k"] == "order" }).to be true

    remaining = []
    q.consume("emails", poll_interval: 0) { |job| remaining << job.payload; job.complete }
    expect(remaining.length).to eq(2)
    expect(remaining.all? { |d| d["k"] == "email" }).to be true
  end

  it "produce(topic) retargets per call and never leaks across topics" do
    q = topic_queue(topic: "default")
    q.produce("a", { "n" => 1 })
    q.produce("b", { "n" => 2 })

    expect(q.consume("a", poll_interval: 0).map { |j| j.complete; j.payload }).to eq([{ "n" => 1 }])
    expect(q.consume("b", poll_interval: 0).map { |j| j.complete; j.payload }).to eq([{ "n" => 2 }])
  end

  it "an explicit backend instance survives consume/process retargeting" do
    # consume(topic)/process(topic:) must not swap an explicitly-provided backend
    # for the env default — Ruby reuses the same @backend the whole time.
    backend = Tina4::QueueBackends::LiteBackend.new(dir: tmp_dir)
    ENV["TINA4_QUEUE_BACKEND"] = "rabbitmq"   # env says rabbitmq...
    begin
      q = Tina4::Queue.new(topic: "default", backend: backend)  # ...explicit wins
      q.produce("t", { "n" => 1 })
      expect(q.backend).to equal(backend)
      q.consume("t", poll_interval: 0) { |job| job.complete }
      expect(q.backend).to equal(backend)   # still the same lite backend
    ensure
      ENV.delete("TINA4_QUEUE_BACKEND")
    end
  end
end

# ── Reservation / visibility timeout (file backend) ────────────────
#
# Regression lock for the production bug where a consumer that dies before
# job.complete() left the message stuck forever — never re-delivered, never
# retried, never dead-lettered. A popped job is now reserved for
# visibility_timeout seconds; if it is not acked in time the next pop()
# reclaims it (incrementing attempts) or dead-letters it past max_retries.
# Deterministic: a tiny visibility_timeout + a short real sleep.
RSpec.describe "Tina4::Queue visibility timeout" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_queue_vt_test") }
  after(:each) { FileUtils.rm_rf(tmp_dir) }

  # Build a Queue whose lite backend stores under tmp_dir with the given
  # visibility_timeout — mirrors `Queue(topic=, visibility_timeout=)` in Python.
  def vt_queue(visibility_timeout:, max_retries: 3)
    backend = Tina4::QueueBackends::LiteBackend.new(
      dir: tmp_dir, max_retries: max_retries, visibility_timeout: visibility_timeout
    )
    Tina4::Queue.new(topic: "vt", backend: backend,
                     max_retries: max_retries, visibility_timeout: visibility_timeout)
  end

  it "reclaims a reserved-then-abandoned job after the timeout (attempts == 1)" do
    queue = vt_queue(visibility_timeout: 0.05)
    queue.push({ "job" => "import" })

    job = queue.pop                       # consumer A reserves it
    expect(job).not_to be_nil
    expect(job.attempts).to eq(0)
    expect(queue.size(status: "pending")).to eq(0)   # claimed out of pending
    expect(queue.size(status: "reserved")).to eq(1)  # held as a reservation

    # Consumer A "dies" — never calls complete()/fail(). After the window
    # expires the next pop() reclaims the abandoned reservation.
    sleep(0.12)
    reclaimed = queue.pop
    expect(reclaimed).not_to be_nil
    expect(reclaimed.payload["job"]).to eq("import")
    expect(reclaimed.attempts).to eq(1)   # reclaim counted as one attempt
  end

  it "does NOT reclaim before the timeout (a second consumer gets nothing)" do
    queue = vt_queue(visibility_timeout: 30)
    queue.push({ "job" => "import" })

    expect(queue.pop).not_to be_nil       # reserved
    # The reservation is still valid — a second consumer must NOT get it.
    expect(queue.pop).to be_nil
    expect(queue.size(status: "reserved")).to eq(1)
  end

  it "dead-letters instead of re-delivering once reclaim passes max_retries" do
    queue = vt_queue(visibility_timeout: 0.05, max_retries: 1)
    queue.push({ "job" => "import" })

    expect(queue.pop).not_to be_nil       # reserve (attempts 0)
    sleep(0.12)
    # Reclaim bumps attempts to 1 (>= max_retries) → dead-letter, not re-served.
    expect(queue.pop).to be_nil
    expect(queue.size(status: "reserved")).to eq(0)
    dead = queue.dead_letters
    expect(dead.length).to eq(1)
    expect(dead.first["payload"]["job"]).to eq("import")
  end

  it "complete() clears the reservation (no phantom reclaim)" do
    queue = vt_queue(visibility_timeout: 0.05)
    queue.push({ "job" => "import" })

    job = queue.pop
    job.complete                          # acked — reservation cleared
    expect(queue.size(status: "reserved")).to eq(0)
    sleep(0.12)
    expect(queue.pop).to be_nil           # nothing to reclaim
  end

  it "fail() clears the reservation and requeues with attempts incremented" do
    queue = vt_queue(visibility_timeout: 0.05, max_retries: 3)
    queue.push({ "job" => "import" })

    job = queue.pop
    job.fail("boom")                      # acked with failure → requeued
    expect(queue.size(status: "reserved")).to eq(0)  # reservation cleared by fail()
    # The requeued job is pending again with attempts incremented.
    retried = queue.pop
    expect(retried).not_to be_nil
    expect(retried.attempts).to eq(1)
  end

  describe "configuration" do
    around(:each) do |example|
      saved = ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"]
      example.run
      if saved.nil?
        ENV.delete("TINA4_QUEUE_VISIBILITY_TIMEOUT")
      else
        ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"] = saved
      end
    end

    it "defaults to 300 seconds" do
      ENV.delete("TINA4_QUEUE_VISIBILITY_TIMEOUT")
      expect(Tina4::Queue.new(topic: "vt", backend: :file).visibility_timeout).to eq(300.0)
    end

    it "reads TINA4_QUEUE_VISIBILITY_TIMEOUT as the env override" do
      ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"] = "42"
      expect(Tina4::Queue.new(topic: "vt", backend: :file).visibility_timeout).to eq(42.0)
    end

    it "lets the constructor arg win over the env" do
      ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"] = "42"
      expect(Tina4::Queue.new(topic: "vt", backend: :file, visibility_timeout: 7).visibility_timeout).to eq(7.0)
    end
  end

  it "visibility_timeout = 0 disables reclaim (reservation stays put)" do
    queue = vt_queue(visibility_timeout: 0)
    queue.push({ "job" => "import" })

    expect(queue.pop).not_to be_nil
    sleep(0.05)
    # Reclaim is disabled — the reservation stays (opt-out / old behaviour).
    expect(queue.pop).to be_nil
    expect(queue.size(status: "reserved")).to eq(1)
  end
end

# ── MongoDB backend adapter contract (no mocks, no live service) ───
#
# The kwarg contract is locked mock-free here: dead_letters/retry_failed must
# accept the max_retries: keyword the Queue facade passes to whatever backend is
# active (a missing kwarg raised ArgumentError at call time). This inspects the
# real method signatures via Method#parameters — no double, no broker, no driver
# — so the class of bug cannot silently reappear. Scoped to the backends that
# implement the lifecycle (file + mongodb); RabbitMQ/Kafka delegate redelivery to
# the broker and intentionally do not define these methods (the Queue guards them
# with respond_to?), so asserting on them would be a false contract.
#
# This REPLACES the former mocked describe that wired an RSpec `double` onto the
# private `collection` — a test double standing in for the real Mongo dependency,
# which the project's absolute no-mock rule forbids and which never exercised real
# Mongo (the kind of gap that let the queue bugs ship for releases). The actual
# dead-letter / retry_failed behaviour is now proven against a LIVE MongoDB by
# "Tina4::Queue MongoDB dead-letter (live, no mocks)" below.
RSpec.describe "Tina4 queue adapter signature contract" do
  let(:lifecycle_backends) do
    {
      "file" => Tina4::QueueBackends::LiteBackend,
      "mongodb" => Tina4::QueueBackends::MongoBackend
    }
  end

  def accepts_max_retries_kwarg?(klass, method_name)
    klass.instance_method(method_name).parameters.any? do |type, pname|
      %i[key keyreq].include?(type) && pname == :max_retries
    end
  end

  it "accepts the max_retries kwarg on dead_letters for every lifecycle backend" do
    lifecycle_backends.each do |name, klass|
      expect(accepts_max_retries_kwarg?(klass, :dead_letters))
        .to be(true), "#{name}.dead_letters is missing the max_retries: kwarg"
    end
  end

  it "accepts the max_retries kwarg on retry_failed for every lifecycle backend" do
    lifecycle_backends.each do |name, klass|
      expect(accepts_max_retries_kwarg?(klass, :retry_failed))
        .to be(true), "#{name}.retry_failed is missing the max_retries: kwarg"
    end
  end
end

# ── MongoDB backend visibility-timeout config (pure function, no mocks) ──
#
# resolve_visibility_timeout is a pure env/option parser — no collection, no
# double, no live service. Allocate (skipping the connecting initialize) only to
# reach the instance method; nothing about the Mongo collection is stubbed.
RSpec.describe Tina4::QueueBackends::MongoBackend do
  describe "configuration" do
    around(:each) do |example|
      saved = ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"]
      example.run
      if saved.nil?
        ENV.delete("TINA4_QUEUE_VISIBILITY_TIMEOUT")
      else
        ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"] = saved
      end
    end

    it "reads the visibility timeout from the env (default 300)" do
      backend = Tina4::QueueBackends::MongoBackend.allocate
      ENV.delete("TINA4_QUEUE_VISIBILITY_TIMEOUT")
      expect(backend.resolve_visibility_timeout(nil)).to eq(300.0)
      ENV["TINA4_QUEUE_VISIBILITY_TIMEOUT"] = "45"
      expect(backend.resolve_visibility_timeout(nil)).to eq(45.0)
      # An explicit option wins over the env.
      expect(backend.resolve_visibility_timeout(7)).to eq(7.0)
    end
  end
end

# ── MongoDB queue dead-letter + retry_failed (LIVE MongoDB, NO mocks) ──
#
# End-to-end through the Tina4::Queue facade against a REAL MongoDB (mirrors the
# Python master's TestMongoQueueDeadLetterLive). NO doubles/stubs of the Mongo
# collection or client. Gated on a reachable Mongo (localhost:27017) + the mongo
# gem; the skip reason contains "mongo" + "not reachable"/"not installed" so the
# #252 service gate treats an unavailable Mongo as a failure under
# TINA4_REQUIRE_SERVICES. Uses a THROWAWAY, framework-namespaced database
# (tina4_test_queue_rb) and DROPS it on teardown — never touching app data.
RSpec.describe "Tina4::Queue MongoDB dead-letter (live, no mocks)" do
  mongo_test_uri = ENV["TINA4_TEST_MONGO_URI"] || ENV["TINA4_MONGO_URI"] || "mongodb://localhost:27017"
  topic = "tina4_test_dead_letter"
  # Prefix only - the real database name is built per example (see the db_name
  # `let` below) so no two examples or processes ever share one.
  db_name_prefix = "tina4_test_queue_rb"
  collection_name = "tina4_test_queue_jobs"

  mongo_gem_present =
    begin
      require "mongo"
      true
    rescue LoadError
      false
    end

  mongo_reachable =
    begin
      require "socket"
      m = mongo_test_uri.match(%r{mongodb://([^:/]+)(?::(\d+))?})
      host = m ? m[1] : "localhost"
      port = (m && m[2]) ? m[2].to_i : 27017
      sock = Socket.tcp(host, port, connect_timeout: 1.5)
      sock.close
      true
    rescue StandardError
      false
    end

  skip_reason =
    if !mongo_gem_present
      "mongo gem not installed"
    elsif !mongo_reachable
      "mongo not reachable at #{mongo_test_uri}"
    end

  if skip_reason
    it "is skipped because MongoDB is unavailable" do
      skip skip_reason
    end
  else
    let(:topic) { topic }
    let(:collection_name) { collection_name }

    # Every example gets its OWN database. These examples finish by DROPPING the
    # database they used, and the name used to be a fixed constant shared by the
    # whole group - so example B (or a second `rspec` process on the same mongod,
    # e.g. CI parallelism or two agents in one checkout) could drop the database
    # example A was still working in. That produced a real, seed-independent
    # phantom: "retry_failed re-queues a real failed document back to pending"
    # failed `expected: 1, got: 0` because the seeded document had been dropped
    # out from under the update.
    #
    # pid keeps concurrent PROCESSES apart; the random suffix keeps examples (and
    # repeat runs within one process) apart. With a name this specific, `drop` can
    # only ever destroy data this example created.
    let(:db_name) { "#{db_name_prefix}_#{Process.pid}_#{SecureRandom.hex(6)}" }

    around(:each) do |example|
      keys = {
        "TINA4_MONGO_URI" => mongo_test_uri,
        "TINA4_MONGO_DB" => db_name,
        "TINA4_MONGO_COLLECTION" => collection_name,
        "TINA4_QUEUE_URL" => nil
      }
      saved = keys.keys.to_h { |k| [k, ENV[k]] }
      # Point the Mongo queue backend at a throwaway, namespaced database.
      keys.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
      example.run
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    end

    def build_queue(test_topic)
      queue = Tina4::Queue.new(topic: test_topic, backend: "mongodb", max_retries: 2)
      backend = queue.backend
      coll = backend.instance_variable_get(:@db)[backend.instance_variable_get(:@collection_name)]
      # Pristine slate, even if a prior run left state behind.
      coll.delete_many(topic: test_topic)
      coll.delete_many(topic: "#{test_topic}.dead_letter")
      [queue, backend, coll]
    end

    # Teardown, called from each example's `ensure` so it runs only AFTER that
    # example's assertions.
    #
    # Dropping is safe here ONLY because db_name is unique per example: this
    # drops `backend`'s own database, which no other example or process shares.
    # If the name ever goes back to being a shared constant, this line becomes a
    # cross-example (and cross-process) data-destroyer again.
    #
    # Closing the client is likewise safe: MongoBackend#initialize builds its own
    # Mongo::Client per instance (mongo_backend.rb - `@client = Mongo::Client.new`,
    # no class-level memoization), and build_queue makes a fresh Queue/backend per
    # example, so close only ever tears down this example's connection.
    def drop_db(backend)
      backend.instance_variable_get(:@db).drop
    rescue StandardError
      nil
    ensure
      backend.close if backend.respond_to?(:close)
    end

    it "moves a job past max_retries into the dead-letter store (real Mongo)" do
      queue, backend, coll = build_queue(topic)
      begin
        queue.push({ "to" => "a@example.com" })
        5.times do # bounded; converges in 2 cycles with max_retries: 2
          job = queue.pop
          break if job.nil?

          job.fail("smtp 550")
          break unless queue.dead_letters.empty?
        end

        dead = queue.dead_letters
        expect(dead.length).to eq(1)
        # HASH access, not .topic. dead_letters returns plain hashes with string
        # keys on EVERY backend now. This spec used to read .topic because the
        # mongo backend alone returned Job objects while the lite backend
        # returned hashes (see the lite spec above, which reads
        # dead_letters.first["error"]) — the two backends genuinely disagreed,
        # and each spec had locked in its own backend's shape. The assertion is
        # unchanged; only the accessor is.
        expect(dead.first["topic"]).to eq("#{topic}.dead_letter")
        # attempts and error now survive to the returned hash too, not just to
        # the stored document.
        expect(dead.first["attempts"]).to eq(2)
        expect(dead.first["error"]).to eq("smtp 550")
        # The failure reason also survives to the DLQ document itself — the
        # persisted record is the source of truth.
        dead_doc = coll.find(topic: "#{topic}.dead_letter", status: "dead").first
        expect(dead_doc["error"]).to eq("smtp 550")
        # The original is no longer pending.
        expect(queue.size(status: "pending")).to eq(0)
      ensure
        coll.delete_many(topic: topic)
        coll.delete_many(topic: "#{topic}.dead_letter")
        drop_db(backend)
      end
    end

    it "retry_failed re-queues a real failed document back to pending (real Mongo)" do
      queue, backend, coll = build_queue(topic)
      begin
        # The auto-retry fail() path never leaves a job in "failed" (it re-queues
        # or dead-letters), so seed ONE real failed document directly in the live
        # collection — real data, NOT a mock — to exercise the real update_many.
        coll.insert_one(
          _id: "tina4-test-failed-1", topic: topic, status: "failed",
          attempts: 1, payload: { "x" => 1 }, error: "boom",
          available_at: "1970-01-01T00:00:00+00:00"
        )

        n = queue.retry_failed(max_retries: 3)
        expect(n).to eq(1)

        doc = coll.find(_id: "tina4-test-failed-1").first
        expect(doc["status"]).to eq("pending") # requeued
        expect(doc["error"]).to be_nil         # cleared on requeue
      ensure
        coll.delete_many(topic: topic)
        coll.delete_many(topic: "#{topic}.dead_letter")
        drop_db(backend)
      end
    end
  end
end
