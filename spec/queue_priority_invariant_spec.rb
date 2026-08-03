# frozen_string_literal: true

# queue_contract.json :: priority-and-availability-are-honoured
#
# MEASURED 2026-08-03: push(payload, priority:) was honoured ONLY on the lite
# backend. An urgent job queued behind a backlog waited for all of it in
# production, while development on the file backend prioritised correctly.
#
# Ruby had both halves of the bug on Mongo: enqueue never WROTE priority (though
# dequeue read it back as `doc["priority"] || 0`, so every job scored 0), and the
# dequeue sorted on created_at alone. Writing the field alone would have changed
# nothing.
#
# The fix splits by what each backend can actually do:
#   lite      already correct - highest priority first, ties oldest-first.
#   mongodb   implemented - priority is stored and the dequeue sorts on it.
#   rabbitmq  RAISES - a RabbitMQ queue is FIFO. Native priority needs the queue
#             DECLARED with x-max-priority, and an existing queue cannot be
#             redeclared with one (PRECONDITION_FAILED).
#   kafka     RAISES - no priority concept at all.
#
# Per queue invariant 6, a backend that genuinely cannot perform an operation
# raises naming the backend AND the operation. It may never silently no-op.
#
# The AVAILABILITY half of this invariant is proved by the
# delay-is-honoured-on-every-backend examples and is not duplicated here.
#
# NOTE: NotImplementedError descends from ScriptError, NOT StandardError, so a
# bare `rescue` or `rescue StandardError` will NOT catch these refusals. That is
# deliberate - asking a backend for something it cannot do is a programming
# error, not a runtime condition to swallow.
#
# NO MOCKS. Every assertion drives a live MongoDB over TCP. If it is unreachable
# the group skips, unless TINA4_REQUIRE_SERVICES is set - then a missing service
# is a FAILURE.
#
# The three case names here are shared VERBATIM with the Python, PHP and Node
# suites, because scripts/audit-contract-fixtures.py resolves ONE fixture case
# against EVERY framework's file.

require "spec_helper"
require "socket"
require "securerandom"

RSpec.describe "Queue priority invariant" do
  MONGO_HOST = ENV["TINA4_TEST_MONGO_HOST"] || "127.0.0.1"
  MONGO_PORT = (ENV["TINA4_TEST_MONGO_PORT"] || "27017").to_i

  def self.reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  before(:all) do
    unless self.class.reachable?(MONGO_HOST, MONGO_PORT)
      why = "MongoDB is not reachable at #{MONGO_HOST}:#{MONGO_PORT}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      skip why
    end
    ENV["TINA4_MONGO_URI"] = "mongodb://#{MONGO_HOST}:#{MONGO_PORT}"
  end

  def mongo_queue
    Tina4::Queue.new(topic: "prio_#{SecureRandom.hex(6)}", backend: "mongodb")
  end

  def payload_of(job)
    p = job.payload
    p.is_a?(Hash) ? (p["m"] || p[:m]) : p
  end

  # The measured defect. LOW is pushed FIRST, so FIFO order and priority order
  # disagree - the only arrangement that can tell them apart.
  it "a higher priority job is delivered before an older lower priority one" do
    queue = mongo_queue
    queue.push({ "m" => "low" }, priority: 0)
    sleep 0.5                            # distinct created_at, so FIFO is unambiguous
    queue.push({ "m" => "high" }, priority: 9)
    sleep 1

    first = queue.pop
    expect(first).not_to be_nil, "the queue returned nothing - priority is unmeasurable"
    expect(payload_of(first)).to eq("high"), "the higher-priority job must be delivered first"
  end

  # NEGATIVE: pins the TIE-BREAK. Without it, "always deliver the newest job"
  # passes the example above while breaking FIFO for everything else. It also
  # proves both jobs come back at all, so this doubles as the control.
  it "equal priority jobs are delivered oldest first" do
    queue = mongo_queue
    queue.push({ "m" => "first" }, priority: 5)
    sleep 0.5
    queue.push({ "m" => "second" }, priority: 5)
    sleep 1

    first = queue.pop
    second = queue.pop
    expect(first).not_to be_nil, "both jobs must come back"
    expect(second).not_to be_nil, "both jobs must come back"
    expect(payload_of(first)).to eq("first"), "equal priority must fall back to oldest-first"
    expect(payload_of(second)).to eq("second")
  end

  # Neither broker can order by priority. Silently discarding it is the failure
  # mode invariant 6 exists to forbid, so they raise naming both the backend and
  # the operation.
  #
  # Ruby's RabbitmqBackend opens its connection in #initialize (Python and PHP
  # connect lazily), so unlike the other three suites this example cannot even
  # CONSTRUCT the queue without a live broker. Hence the reachability guard
  # rather than a double.
  it "a backend that cannot prioritise refuses instead of dropping the priority" do
    { "rabbitmq" => 5672, "kafka" => 9092 }.each do |backend, default_port|
      host = ENV["TINA4_TEST_#{backend.upcase}_HOST"] || "127.0.0.1"
      port = (ENV["TINA4_TEST_#{backend.upcase}_PORT"] || default_port.to_s).to_i

      unless self.class.reachable?(host, port)
        why = "#{backend} is not reachable at #{host}:#{port}"
        raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

        next
      end

      # Set ONLY this backend's vars, and RESTORE them afterwards. Setting the
      # RabbitMQ host/port unconditionally meant the kafka iteration left
      # TINA4_RABBITMQ_PORT=9092 behind; under RSpec's randomized order that
      # leaked into queue_backends_spec, whose RabbitMQ example then dialled the
      # Kafka port and died with "Empty response received from the server".
      saved = ENV.slice("TINA4_RABBITMQ_HOST", "TINA4_RABBITMQ_PORT", "TINA4_KAFKA_BROKERS")
      if backend == "rabbitmq"
        ENV["TINA4_RABBITMQ_HOST"] = host
        ENV["TINA4_RABBITMQ_PORT"] = port.to_s
      else
        ENV["TINA4_KAFKA_BROKERS"] = "#{host}:#{port}"
      end

      queue = Tina4::Queue.new(topic: "prio_#{SecureRandom.hex(6)}", backend: backend)

      expect { queue.push({ "m" => "high" }, priority: 9) }
        .to raise_error(NotImplementedError, /#{backend}.*priority/mi),
            "the #{backend} backend must refuse a prioritised push, naming itself and the operation"
    ensure
      saved.each { |k, v| ENV[k] = v }
      %w[TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT TINA4_KAFKA_BROKERS].each do |k|
        ENV.delete(k) unless saved.key?(k)
      end
    end
  end
end
