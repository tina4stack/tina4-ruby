# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "socket"
require "json"

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
end
