# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "socket"
require "securerandom"

# Live Kafka durable-offset spec (no mocks) — ADR-0022 decisions 2/3/4 and the
# tina4#274 family. Proves acknowledge() commits the SPECIFIC record's offset
# (not a bare @consumer.commit of the whole polled position), so:
#   - a completed job is NEVER re-delivered after a restart (decision 4);
#   - a job popped but NOT acknowledged IS re-delivered after a restart (the
#     negative control — it is the durable commit, not the poll position, that
#     suppresses the replay);
#   - an externally-produced record (no Tina4 envelope, no id — Debezium/CDC)
#     is consumable with its payload byte-for-byte (from_payload used to read a
#     nil "payload" key off it) and commits durably under its coordinate id.
#
# A fresh KafkaBackend per "restart" stands in for a new process. Gated exactly
# like kafka_integration_spec; skips carry a provisioned-service keyword so
# TINA4_REQUIRE_SERVICES turns a missing broker in CI into a hard failure.
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

RSpec.describe "Kafka backend durable offsets", :kafka do
  before(:all) do
    @skip_reason = if !_rdkafka_available?
                     "rdkafka gem not installed"
                   elsif ENV["TINA4_TEST_KAFKA_URL"].to_s.empty?
                     "TINA4_TEST_KAFKA_URL not set"
                   elsif !_kafka_reachable?
                     "Kafka not reachable on localhost:9092"
                   end
  end

  before(:each) { skip(@skip_reason) if @skip_reason }

  def backend_in(group)
    Tina4::QueueBackends::KafkaBackend.new(group_id: group)
  end

  def pop_wait(backend, topic, tries = 40)
    tries.times do
      job = backend.dequeue(topic)
      return job unless job.nil?
    end
    nil
  end

  let(:suffix) { "#{Process.pid}_#{SecureRandom.hex(4)}" }
  let(:topic) { "tina4_rb_durable_#{suffix}" }
  let(:group) { "tina4_rb_durable_grp_#{suffix}" }

  it "does not re-deliver a completed job after a restart (ADR-0022 decision 4)" do
    producer = backend_in(group)
    3.times { |i| producer.enqueue(Tina4::Job.new(topic: topic, payload: { "n" => i + 1 })) }
    producer.close

    consumer = backend_in(group)
    completed = 0
    3.times do
      job = pop_wait(consumer, topic)
      next if job.nil?
      consumer.complete(job)
      completed += 1
    end
    consumer.close
    expect(completed).to eq(3)

    after_restart = backend_in(group)
    replay = pop_wait(after_restart, topic, 6)
    after_restart.close
    expect(replay).to be_nil, "a completed job replayed after a restart (offset was not committed)"
  end

  it "re-delivers an un-acknowledged job after a restart (negative control)" do
    nonce = SecureRandom.hex(6)
    producer = backend_in(group)
    producer.enqueue(Tina4::Job.new(topic: topic, payload: { "keep" => true, "nonce" => nonce }))
    producer.close

    first = backend_in(group)
    job = pop_wait(first, topic)
    first.close # never completed — no commit
    expect(job).not_to be_nil
    expect(job.payload["nonce"]).to eq(nonce)

    second = backend_in(group)
    again = pop_wait(second, topic)
    second.close
    expect(again).not_to be_nil, "an un-acknowledged record did not replay after a restart"
    expect(again.payload["nonce"]).to eq(nonce)
  end

  it "consumes an external record byte-for-byte and commits it durably (tina4#274)" do
    external = { "source" => "debezium", "op" => "c", "row" => { "id" => 42, "name" => "ext" } }
    producer = backend_in(group)
    # raw: true => produced with NO Tina4 envelope, as a foreign producer would.
    producer.enqueue(Tina4::Job.new(topic: topic, payload: external), raw: true)
    producer.close

    consumer = backend_in(group)
    job = pop_wait(consumer, topic)
    expect(job).not_to be_nil, "an external record was not consumable"
    expect(job.payload).to eq(external), "the external payload must be delivered byte-for-byte"
    expect(job.id.to_s).to include("#{topic}:"), "an id-less external record takes its coordinate as its id"
    consumer.complete(job)
    consumer.close

    after_restart = backend_in(group)
    replay = pop_wait(after_restart, topic, 6)
    after_restart.close
    expect(replay).to be_nil, "the completed external record replayed after a restart"
  end
end
