# frozen_string_literal: true

require "spec_helper"
require "socket"

# Live Kafka integration — the enqueue -> dequeue -> acknowledge cycle against a
# REAL broker. Ruby previously had NO live Kafka spec (only config-resolution),
# which is why the dequeue bug went unnoticed: a single `poll(1000)` right after
# subscribe returns nil because the consumer-group join + partition assignment
# takes several seconds on a cold broker, so dequeue() returned nil right after
# enqueue(). The fix polls in a bounded loop on first subscribe.
#
# Gated: skips cleanly unless the rdkafka gem loads, TINA4_TEST_KAFKA_URL is set,
# and a broker answers on localhost:9092. No mocks — this drives librdkafka.
def _rdkafka_available?
  require "rdkafka"
  true
rescue LoadError
  false
end

def _kafka_reachable?(host = "localhost", port = 9092)
  Socket.tcp(host, port, connect_timeout: 1) { true }
rescue StandardError
  false
end

RSpec.describe "Kafka backend live integration", :kafka do
  before(:all) do
    skip "rdkafka gem not installed" unless _rdkafka_available?
    skip "TINA4_TEST_KAFKA_URL not set" unless ENV["TINA4_TEST_KAFKA_URL"] && !ENV["TINA4_TEST_KAFKA_URL"].empty?
    skip "Kafka not reachable on localhost:9092" unless _kafka_reachable?
  end

  it "enqueues then dequeues the same message (first-subscribe assignment is awaited)" do
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    topic = "tina4_rb_kafka_#{suffix}"
    backend = Tina4::QueueBackends::KafkaBackend.new(group_id: "tina4_rb_test_#{suffix}")

    job = Tina4::Job.new(topic: topic, payload: { "hello" => "world" }, id: "rbk-#{suffix}")
    backend.enqueue(job)

    got = backend.dequeue(topic)
    expect(got).not_to be_nil, "dequeue returned nil right after enqueue (the assignment-wait bug)"
    expect(got.payload).to eq("hello" => "world")
    expect(got.id).to eq("rbk-#{suffix}")

    backend.acknowledge(got)
    backend.close if backend.respond_to?(:close)
  end
end
