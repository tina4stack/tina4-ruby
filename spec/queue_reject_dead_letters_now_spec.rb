# frozen_string_literal: true

# Tina4 — Queue reject dead-letters IMMEDIATELY, no retry (ADR-0023).
#
# Bug 4 (book review). Job#reject was a literal alias for fail
# (`def reject(reason = ""); fail(reason); end`). ADR-0023 (Accepted) redefines
# reject: it is the "this message is poison, do NOT retry it" path — the job
# goes straight to the dead-letter store on this call, without burning the
# retry budget. AMQP basic.reject(requeue=false) semantics.
#
# Pins BOTH sides on the same max_retries=3 file-backed queue:
#   reject -> dead-lettered NOW (1 delivery), never re-queued
#   fail   -> re-queued, still pending, NOT dead-lettered (control)
#
# File backend, real filesystem (no mock). Needs no external service.

require "spec_helper"
require "tina4"

RSpec.describe "Queue#reject dead-letters immediately (ADR-0023)" do
  around(:each) do |example|
    Dir.mktmpdir("tina4_reject") do |dir|
      old = ENV["TINA4_QUEUE_PATH"]
      old_backend = ENV["TINA4_QUEUE_BACKEND"]
      ENV["TINA4_QUEUE_PATH"] = dir
      ENV.delete("TINA4_QUEUE_BACKEND") # never let the env override the file backend
      begin
        example.run
      ensure
        ENV["TINA4_QUEUE_PATH"] = old
        ENV["TINA4_QUEUE_BACKEND"] = old_backend
      end
    end
  end

  def new_queue
    Tina4::Queue.new(topic: "reject_#{SecureRandom.hex(4)}", max_retries: 3)
  end

  it "dead-letters on the first delivery, even with retries left" do
    q = new_queue
    q.push({ "task" => "poison" })
    job = q.pop
    expect(job).not_to be_nil

    job.reject("payload will never parse")

    dead = q.dead_letters
    expect(dead.length).to eq(1)          # reject dead-letters now, not after max_retries
    expect(q.size(status: "dead")).to eq(1)
    expect(q.size(status: "pending")).to eq(0)  # a rejected job is NOT re-queued
  end

  it "fail() with retries left re-queues, does NOT dead-letter (control)" do
    q = new_queue
    q.push({ "task" => "transient" })
    job = q.pop
    job.fail("temporary blip")

    expect(q.size(status: "dead")).to eq(0)     # fail under max_retries must NOT dead-letter
    expect(q.size(status: "pending")).to eq(1)  # fail under max_retries re-queues
    expect(q.dead_letters.length).to eq(0)
  end

  it "a rejected job is never redelivered to pop" do
    q = new_queue
    q.push({ "task" => "poison" })
    q.pop.reject("nope")
    expect(q.pop).to be_nil
  end
end
