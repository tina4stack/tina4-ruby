# frozen_string_literal: true

# clear()/purge() on a broker backend refuse by name (ADR-0022, invariant 6).
#
# MEASURED 2026-08-07: the RabbitMQ backend's clear()/purge() DRAINED the live
# broker queue (clear -> purge(topic, "pending") -> queue.purge), destroying
# every pending job, because basic.get pops the head of the queue and the
# adapter cannot select messages by status. The Kafka backend already refused
# (a log cannot delete records on demand).
#
# ADR-0022: "a broker that cannot address messages by status refuses the
# operation by name." clear() and purge(status) are status-addressed. Neither
# RabbitMQ nor Kafka can honour them, so both RAISE NotImplementedError naming
# the backend AND the operation - exactly as they already do for push(priority),
# retry_failed() and failed().
#
# NOTE: NotImplementedError descends from ScriptError, NOT StandardError, so a
# bare `rescue`/`rescue StandardError` will NOT catch these refusals. That is
# deliberate - asking a backend for something it cannot do is a programming
# error, not a runtime condition to swallow.
#
# NO MOCKS.
#   kafka    - rdkafka connects lazily in a background thread, so the queue
#              CONSTRUCTS without a live broker and clear()/purge() raise before
#              any I/O. This half runs locally and is the red-first, mutation-
#              provable one; it needs only the rdkafka gem.
#   rabbitmq - Bunny opens its connection in #initialize, so constructing the
#              queue needs a LIVE broker. This half is lab-only, gated under the
#              require-services convention (reachability), mirroring
#              queue_priority_invariant_spec.rb.
#   lite     - the negative control: it CAN address by status, so it must answer
#              for real rather than join a blanket refusal. Runs everywhere.
#
# No bare constants are declared in this group: a constant inside RSpec.describe
# lands on Object (GLOBAL) and clobbers other spec files (see the note in
# queue_priority_invariant_spec.rb). Everything is a let/method/local.

require "spec_helper"
require "socket"
require "securerandom"
require "tmpdir"
require "fileutils"

RSpec.describe "Queue clear/purge refusal on broker backends" do
  # Close each queue's backend (rdkafka producer/consumer, Bunny channel) after
  # the example rather than leaking a client + background thread for the run.
  def track(queue)
    (@tracked ||= []) << queue
    queue
  end

  after do
    (@tracked || []).each do |q|
      q.close
    rescue StandardError, NotImplementedError # rubocop:disable Lint/SuppressedException
      # a half-open broker client is not this test's concern
    end
    @tracked = []
  end

  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  describe "kafka (constructs offline - runs locally)" do
    before do
      require "rdkafka"
    rescue LoadError
      skip "the kafka refusal needs the rdkafka gem, which is not installed here"
    end

    def kafka_queue
      track(Tina4::Queue.new(topic: "clr_#{SecureRandom.hex(6)}", backend: "kafka"))
    end

    it "clear() refuses by name instead of silently emptying nothing" do
      expect { kafka_queue.clear }
        .to raise_error(NotImplementedError, /kafka.*clear/mi),
            "kafka clear() must refuse, naming the backend and the operation"
    end

    it "purge() refuses by name instead of silently emptying nothing" do
      expect { kafka_queue.purge("completed") }
        .to raise_error(NotImplementedError, /kafka.*purge/mi),
            "kafka purge() must refuse, naming the backend and the operation"
    end
  end

  describe "rabbitmq (connects eagerly - live broker, lab-only)" do
    let(:host) { ENV["TINA4_TEST_RABBITMQ_HOST"] || "127.0.0.1" }
    let(:port) { (ENV["TINA4_TEST_RABBITMQ_PORT"] || "5672").to_i }

    around do |example|
      saved = ENV.slice("TINA4_RABBITMQ_HOST", "TINA4_RABBITMQ_PORT")
      example.run
    ensure
      %w[TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT].each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
    end

    before do
      next if reachable?(host, port)

      why = "RabbitMQ is not reachable at #{host}:#{port}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      skip why
    end

    def rabbitmq_queue
      # resolve_rabbitmq_config reads TINA4_RABBITMQ_HOST/PORT; set them for the
      # construction, restored by the around hook above.
      ENV["TINA4_RABBITMQ_HOST"] = host
      ENV["TINA4_RABBITMQ_PORT"] = port.to_s
      track(Tina4::Queue.new(topic: "clr_#{SecureRandom.hex(6)}", backend: "rabbitmq"))
    end

    it "clear() refuses by name instead of draining the live queue" do
      expect { rabbitmq_queue.clear }
        .to raise_error(NotImplementedError, /rabbitmq.*clear/mi),
            "rabbitmq clear() must refuse rather than drain every pending job"
    end

    it "purge() refuses by name instead of draining the live queue" do
      expect { rabbitmq_queue.purge("completed") }
        .to raise_error(NotImplementedError, /rabbitmq.*purge/mi),
            "rabbitmq purge() must refuse rather than drain every pending job"
    end
  end

  describe "lite (negative control - answers for real)" do
    around do |example|
      saved = ENV["TINA4_QUEUE_PATH"]
      dir = Dir.mktmpdir("tina4_queue_neg")
      ENV["TINA4_QUEUE_PATH"] = dir
      example.run
    ensure
      saved.nil? ? ENV.delete("TINA4_QUEUE_PATH") : (ENV["TINA4_QUEUE_PATH"] = saved)
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
    end

    def lite_queue
      track(Tina4::Queue.new(topic: "file_#{SecureRandom.hex(6)}", backend: "lite"))
    end

    it "clear() returns a real count and never raises a refusal" do
      queue = lite_queue
      queue.push({ "m" => "keep" })
      expect(queue.clear).to be_a(Integer)
    end

    it "purge() returns a real count and never raises a refusal" do
      expect(lite_queue.purge("completed")).to be_a(Integer)
    end
  end
end
