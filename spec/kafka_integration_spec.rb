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
#
# The reachability is PROBED once in before(:all) but the `skip` itself fires per
# EXAMPLE — the house pattern across this suite (see the postgres/mysql/mssql
# live specs). The skip reasons carry a provisioned-service keyword plus an
# unavailable hint, so TINA4_REQUIRE_SERVICES turns a missing broker in CI into a
# hard failure instead of a green skip (spec/spec_helper.rb). The gate now walks
# RSpec.world at suite end, so a before(:all) skip would be caught too; this
# shape simply keeps the reason attached to the example that needs the broker.
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
    @skip_reason = if !_rdkafka_available?
                     "rdkafka gem not installed"
                   elsif ENV["TINA4_TEST_KAFKA_URL"].to_s.empty?
                     "TINA4_TEST_KAFKA_URL not set"
                   elsif !_kafka_reachable?
                     "Kafka not reachable on localhost:9092"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
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
