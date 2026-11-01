# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"

# Kafka consumer offset-reset override (tina4-ruby#263) and the raw producer
# refusal on non-Kafka backends (tina4-ruby#264). Pure/offline — no broker and no
# rdkafka gem needed (offset_reset is a class method; the file backend needs no
# service), so these run in every job. The live raw round-trip proving a raw
# produce carries no envelope is in kafka_integration_spec (gated on a broker).

RSpec.describe "Kafka offset-reset + raw producer (offline)" do
  around(:each) do |example|
    saved = {}
    %w[TINA4_KAFKA_AUTO_OFFSET_RESET KAFKA_AUTO_OFFSET_RESET].each do |k|
      saved[k] = ENV[k]
      ENV.delete(k)
    end
    example.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # ── #263: auto.offset.reset resolution ──────────────────────────────────
  describe "KafkaBackend.offset_reset" do
    it "defaults to earliest" do
      expect(Tina4::QueueBackends::KafkaBackend.offset_reset).to eq("earliest")
    end

    it "honours TINA4_KAFKA_AUTO_OFFSET_RESET" do
      ENV["TINA4_KAFKA_AUTO_OFFSET_RESET"] = "latest"
      expect(Tina4::QueueBackends::KafkaBackend.offset_reset).to eq("latest")
    end

    it "falls back to the bare KAFKA_AUTO_OFFSET_RESET" do
      ENV["KAFKA_AUTO_OFFSET_RESET"] = "latest"
      expect(Tina4::QueueBackends::KafkaBackend.offset_reset).to eq("latest")
    end

    it "prefers TINA4_ over the bare KAFKA_ name" do
      ENV["TINA4_KAFKA_AUTO_OFFSET_RESET"] = "latest"
      ENV["KAFKA_AUTO_OFFSET_RESET"] = "earliest"
      expect(Tina4::QueueBackends::KafkaBackend.offset_reset).to eq("latest")
    end

    it "treats a blank value as unset" do
      ENV["TINA4_KAFKA_AUTO_OFFSET_RESET"] = ""
      expect(Tina4::QueueBackends::KafkaBackend.offset_reset).to eq("earliest")
    end
  end

  # ── #264: raw is Kafka-only — other backends refuse by name ─────────────
  describe "raw producer refusal" do
    it "refuses push(raw: true) on the file backend, naming it" do
      queue = Tina4::Queue.new(topic: "tina4_raw_refusal_#{rand(1_000_000)}", backend: :file)
      expect { queue.push({ "event" => "x" }, raw: true) }
        .to raise_error(NotImplementedError, /file queue backend cannot honour push\(raw: true\)/)
    end

    it "leaves the default raw: false path unchanged on the file backend" do
      queue = Tina4::Queue.new(topic: "tina4_raw_default_#{rand(1_000_000)}", backend: :file)
      job = queue.push({ "event" => "x" })
      expect(job).not_to be_nil
      popped = queue.pop
      expect(popped).not_to be_nil
      expect(popped.payload).to eq("event" => "x")
      popped.complete
    end
  end
end
