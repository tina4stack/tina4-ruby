# frozen_string_literal: true

# queue_contract.json :: operations-reach-the-configured-backend
#
# RULE: every operation acts on the CONFIGURED backend. No method may silently
# read or write the local file store, or silently no-op, when another backend is
# selected.
#
# MEASURED 2026-08-03 on mongodb, before the fix: Ruby's clear() and pop_by_id()
# returned 0/nil because MongoBackend had NEITHER method and Queue guarded on
# respond_to?(:clear) / respond_to?(:find_by_id). Clearing a mongo-backed queue
# was a no-op that looked exactly like an already-empty queue.
#
# This is the worst failure class: the call appears to succeed and operates on
# the wrong data, so nothing surfaces it.
#
# NO MOCKS. Live MongoDB over TCP; skips unless TINA4_REQUIRE_SERVICES is set.
#
# The three case names here are shared VERBATIM with the Python, PHP and Node
# suites.

require "spec_helper"
require "socket"
require "securerandom"

RSpec.describe "Queue reaches the configured backend" do
  REACH_HOST = ENV["TINA4_TEST_MONGO_HOST"] || "127.0.0.1"
  REACH_PORT = (ENV["TINA4_TEST_MONGO_PORT"] || "27017").to_i

  def self.reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  before(:all) do
    unless self.class.reachable?(REACH_HOST, REACH_PORT)
      why = "MongoDB is not reachable at #{REACH_HOST}:#{REACH_PORT}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      skip why
    end
    ENV["TINA4_MONGO_URI"] = "mongodb://#{REACH_HOST}:#{REACH_PORT}"
  end

  def mongo_queue
    Tina4::Queue.new(topic: "reach_#{SecureRandom.hex(6)}", backend: "mongodb")
  end

  # If clear() hits the file store, the mongodb jobs survive and size stays 2.
  it "clear acts on the configured backend not the local file store" do
    q = mongo_queue
    q.push({ "m" => "a" })
    q.push({ "m" => "b" })
    expect(q.size).to eq(2), "the pushes must reach mongodb first, or this proves nothing"

    q.clear

    expect(q.size).to eq(0), "clear must empty the CONFIGURED backend"
  end

  # The job is in mongodb and we ask for it by its own id.
  it "pop by id claims the job from the configured backend" do
    q = mongo_queue
    job = q.push({ "m" => "byid" })

    expect(q.pop_by_id(job.id)).not_to be_nil,
                                       "pop_by_id must claim the job from the configured backend"
  end

  # A broker cannot address one message by id. It must say so, naming itself and
  # the operation - never quietly answer from a local directory.
  it "an operation the backend cannot perform refuses instead of silently using the file store" do
    host = ENV["TINA4_TEST_RABBITMQ_HOST"] || "127.0.0.1"
    port = (ENV["TINA4_TEST_RABBITMQ_PORT"] || "5672").to_i
    unless self.class.reachable?(host, port)
      why = "rabbitmq is not reachable at #{host}:#{port}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      skip why
    end
    ENV["TINA4_RABBITMQ_HOST"] = host
    ENV["TINA4_RABBITMQ_PORT"] = port.to_s

    q = Tina4::Queue.new(topic: "reach_#{SecureRandom.hex(6)}", backend: "rabbitmq")

    expect { q.pop_by_id("whatever") }
      .to raise_error(NotImplementedError, /pop_by_id/i),
          "the refusal must name the operation rather than answering from local disk"
  end
end
