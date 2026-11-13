# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "socket"
require "json"
require "timeout"

# Live Kafka tombstone regression (tina4-python#303 twin). A tombstone is a record
# whose value is null: normal on Kafka (Debezium emits them on deletes,
# log-compacted topics use them as delete markers). rdkafka hands back a nil
# payload, so Tina4.parse_json(msg.payload) -> JSON.parse(nil) raised a TypeError.
# The only rescue in dequeue is `rescue Rdkafka::RdkafkaError`, which does NOT
# catch TypeError, so it escaped and killed the consumer. Because the tombstone
# sits at the committed offset it was a poison pill: every restart re-crashed.
#
# No mocks — this drives a REAL librdkafka producer/consumer against a REAL broker.
# A tombstone is produced with `payload: nil`, exactly what a Debezium delete
# writes. Gated the same way as kafka_integration_spec (rdkafka gem + a reachable
# broker); the skip reason carries the :kafka service keyword so
# TINA4_REQUIRE_SERVICES turns a missing broker into a hard failure in CI rather
# than a green skip.
#
# Mutation proof: remove the `return nil if msg.payload.nil?` guard in
# KafkaBackend#dequeue and the first example raises TypeError instead of passing.
def _tombstone_rdkafka_available?
  require "rdkafka"
  true
rescue LoadError
  false
end

def _tombstone_kafka_reachable?(host = "localhost", port = 9092)
  Socket.tcp(host, port, connect_timeout: 1) { true }
rescue StandardError
  false
end

def _tombstone_brokers
  ENV["TINA4_KAFKA_BROKERS"].to_s.empty? ? "localhost:9092" : ENV["TINA4_KAFKA_BROKERS"]
end

# Produce (key, value) pairs with a plain librdkafka producer. value == nil is a
# genuine tombstone on the wire, exactly like a Debezium delete.
def _produce_tombstone_records(topic, records)
  producer = Rdkafka::Config.new({ "bootstrap.servers" => _tombstone_brokers }).producer
  handles = records.map do |key, value|
    payload = value.nil? ? nil : JSON.generate(value)
    producer.produce(topic: topic, payload: payload, key: key)
  end
  handles.each { |h| h.wait(max_wait_timeout: 15) }
ensure
  producer.close if producer
end

# The group's durably committed offset for a partition (nil or negative = none).
def _tombstone_committed(topic, group_id, partition = 0)
  probe = Rdkafka::Config.new({
    "bootstrap.servers" => _tombstone_brokers, "group.id" => group_id, "enable.auto.commit" => "false"
  }).consumer
  tpl = Rdkafka::Consumer::TopicPartitionList.new
  tpl.add_topic(topic, [partition])
  probe.committed(tpl, 15_000).to_h[topic]&.first&.offset
ensure
  probe&.close
end

def _tombstone_mono
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

RSpec.describe "Kafka tombstone (null-value) record", :kafka do
  before(:all) do
    @skip_reason = if !_tombstone_rdkafka_available?
                     "rdkafka gem not installed"
                   elsif ENV["TINA4_TEST_KAFKA_URL"].to_s.empty?
                     "TINA4_TEST_KAFKA_URL not set"
                   elsif !_tombstone_kafka_reachable?
                     "Kafka not reachable on localhost:9092"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
  end

  it "skips a tombstone at the committed offset and still delivers the next record" do
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    topic = "tina4_rb_tomb_#{suffix}"

    # Tombstone FIRST (the poison-pill position), then a real record after it.
    _produce_tombstone_records(topic, [
      ["deleted-key", nil],
      ["live-key", { "event" => "after_tombstone", "n" => 1 }]
    ])

    backend = Tina4::QueueBackends::KafkaBackend.new(group_id: "tina4_rb_tomb_#{suffix}")
    delivered = nil
    begin
      # Without the guard this raises TypeError on the tombstone. With it, the
      # tombstone yields nil (no job) and the consumer advances to the real record.
      12.times do
        got = backend.dequeue(topic)
        if got && got.payload.is_a?(Hash) && got.payload["event"] == "after_tombstone"
          delivered = got
          break
        end
      end
    ensure
      backend.close if backend.respond_to?(:close)
    end

    expect(delivered).not_to be_nil, "real record after the tombstone was not delivered"
    expect(delivered.payload["n"]).to eq(1)
  end

  it "returns nil (no job) for a topic holding only a tombstone, without crashing" do
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    topic = "tina4_rb_tomb_only_#{suffix}"

    _produce_tombstone_records(topic, [["deleted-key", nil]])

    backend = Tina4::QueueBackends::KafkaBackend.new(group_id: "tina4_rb_tomb_only_#{suffix}")
    begin
      # One dequeue consumes the tombstone and must return nil, not raise.
      expect(backend.dequeue(topic)).to be_nil
    ensure
      backend.close if backend.respond_to?(:close)
    end
  end

  it "drains past a tombstone in a single pass (consume with poll_interval: 0)" do
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    topic = "tina4_rb_tomb_drain_#{suffix}"

    _produce_tombstone_records(topic, [
      ["k1", { "n" => 1 }],
      ["k1", nil],
      ["k2", { "n" => 2 }]
    ])

    # Answering a tombstone with nil reads as an empty queue: the drain stopped
    # at it and left the record after it behind, in every fresh process.
    backend = Tina4::QueueBackends::KafkaBackend.new(
      brokers: _tombstone_brokers, group_id: "tina4_rb_tomb_drain_#{suffix}"
    )
    queue = Tina4::Queue.new(topic: topic, backend: backend)
    got = []
    begin
      queue.consume(topic, poll_interval: 0) do |job|
        got << job.payload["n"]
        job.complete
      end
    ensure
      backend.close if backend.respond_to?(:close)
    end

    expect(got).to eq([1, 2]), "the drain stopped at the tombstone: #{got.inspect}"
  end

  it "keeps dequeue's deadline while a stream of tombstones arrives" do
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    topic = "tina4_rb_tomb_deadline_#{suffix}"
    _produce_tombstone_records(topic, [["k0", { "n" => 0 }]])
    backend = Tina4::QueueBackends::KafkaBackend.new(
      brokers: _tombstone_brokers, group_id: "tina4_rb_tomb_deadline_#{suffix}"
    )
    feeder = nil
    begin
      expect(backend.dequeue(topic)&.payload).to eq({ "n" => 0 }) # warm: joined + assigned
      # Skipping went straight back to poll and never reached the deadline
      # check, so one dequeue blocked for as long as the tombstones kept coming.
      stop = _tombstone_mono + 6
      feeder = Thread.new do
        producer = Rdkafka::Config.new({ "bootstrap.servers" => _tombstone_brokers }).producer
        while _tombstone_mono < stop
          producer.produce(topic: topic, payload: nil, partition: 0).wait(max_wait_timeout: 5)
          sleep 0.1
        end
        producer.close
      end
      sleep 0.3
      started = _tombstone_mono
      got = Timeout.timeout(20) { backend.dequeue(topic) }
      took = _tombstone_mono - started
      expect(got).to be_nil
      expect(took).to be < 1.6, "dequeue took #{took.round(1)}s under a tombstone stream (deadline ~1s)"
    ensure
      feeder&.join(10)
      backend.close if backend.respond_to?(:close)
    end
  end

  it "gets a fresh process past a tombstone through the normal acknowledge" do
    # Nothing commits on the tombstone path; acknowledging the record after it
    # commits past both, so a restart neither stops at the tombstone nor
    # redelivers anything.
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    topic = "tina4_rb_tomb_restart_#{suffix}"
    group = "tina4_rb_tomb_restart_#{suffix}"
    _produce_tombstone_records(topic, [["k1", { "n" => 1 }], ["k1", nil], ["k2", { "n" => 2 }]])
    first = Tina4::QueueBackends::KafkaBackend.new(brokers: _tombstone_brokers, group_id: group)
    begin
      job = first.dequeue(topic)
      expect(job&.payload).to eq({ "n" => 1 })
      first.acknowledge(job)
      expect(_tombstone_committed(topic, group)).to eq(1) # at the tombstone
    ensure
      first.close if first.respond_to?(:close)
    end
    second = Tina4::QueueBackends::KafkaBackend.new(brokers: _tombstone_brokers, group_id: group)
    begin
      job = second.dequeue(topic)
      expect(job&.payload).to eq({ "n" => 2 }), "a restart did not get past the tombstone"
      second.acknowledge(job)
      expect(_tombstone_committed(topic, group)).to eq(3)
    ensure
      second.close if second.respond_to?(:close)
    end
    third = Tina4::QueueBackends::KafkaBackend.new(brokers: _tombstone_brokers, group_id: group)
    begin
      expect(third.dequeue(topic)).to be_nil
    ensure
      third.close if third.respond_to?(:close)
    end
  end
end
