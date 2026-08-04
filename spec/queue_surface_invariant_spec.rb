# frozen_string_literal: true

# queue_contract.json :: every-method-exists-on-every-backend
#
# RULE: every public Queue method RESOLVES and runs on every configured backend.
# No method may be a fatal error or a NoMethodError on any backend the framework
# offers.
#
# This is not the same rule as invariant 6. Invariant 6 says an operation a
# backend cannot perform must RAISE naming itself. Invariant 1 says the method
# must EXIST to do the raising. A named refusal satisfies both; a NoMethodError
# satisfies neither.
#
# MEASURED 2026-08-03: queue.size raised NoMethodError on kafka - the Ruby Kafka
# backend simply had no size method, though Python and PHP both answer 0.
# ADR-0022 decision 5 records 0 as the documented answer: a log has no queue
# depth, and computing one means an admin round-trip per call.
#
# NO MOCKS. Every assertion drives a live MongoDB over TCP, and the broker cases
# drive a live RabbitMQ/Kafka. If a service is unreachable the group skips,
# unless TINA4_REQUIRE_SERVICES is set - then a missing service is a FAILURE.
#
# NOTE: NotImplementedError descends from ScriptError, NOT StandardError, so a
# bare `rescue` will not catch a refusal. That is deliberate.
#
# The three case names here are shared VERBATIM with the Python, PHP and Node
# suites, because scripts/audit-contract-fixtures.py resolves ONE fixture case
# against EVERY framework's file.

require "spec_helper"
require "socket"
require "securerandom"

RSpec.describe "Queue surface invariant" do

  # Every Mongo-backed Queue opens its own Mongo::Client and Tina4::Queue has NO
  # public close (a real gap - see the note in the changelog). These specs create
  # many queues, so without this the clients accumulate for the whole run: the
  # full suite then failed docstore "connections do not grow" (rounds=[99,99,99])
  # and starved the live-Puma dev-admin specs with EOFError. Track and release.
  def track(queue)
    (@tracked ||= []) << queue
    queue
  end

  after do
    (@tracked || []).each do |q|
      begin
        q.instance_variable_get(:@backend)&.close
      rescue StandardError, NotImplementedError # rubocop:disable Lint/SuppressedException
      end
    end
    @tracked = []
  end
  SURFACE_MONGO_HOST = ENV["TINA4_TEST_MONGO_HOST"] || "127.0.0.1"
  SURFACE_MONGO_PORT = (ENV["TINA4_TEST_MONGO_PORT"] || "27017").to_i

  # Every public Queue method that needs no live job to exercise.
  SURFACE_METHODS = {
    "size"         => ->(q) { q.size },
    "pop_batch"    => ->(q) { q.pop_batch(1) },
    "pop_by_id"    => ->(q) { q.pop_by_id("nope") },
    "failed"       => ->(q) { q.failed },
    "dead_letters" => ->(q) { q.dead_letters },
    "retry"        => ->(q) { q.retry },
    "retry_failed" => ->(q) { q.retry_failed },
    "purge"        => ->(q) { q.purge("completed") },
    "clear"        => ->(q) { q.clear }
  }.freeze

  def self.reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  before(:all) do
    # Leave ENV exactly as found. These vars are process-global and the
    # dev-admin specs boot a live Puma that INHERITS them, so a stray
    # TINA4_MONGO_URI from here changed how that server came up and its
    # requests died with EOFError. Restored in after(:all) below.
    @env_snapshot = ENV.slice(*%w[TINA4_MONGO_URI TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT TINA4_KAFKA_BROKERS])
    unless self.class.reachable?(SURFACE_MONGO_HOST, SURFACE_MONGO_PORT)
      why = "MongoDB is not reachable at #{SURFACE_MONGO_HOST}:#{SURFACE_MONGO_PORT}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      skip why
    end
    ENV["TINA4_MONGO_URI"] = "mongodb://#{SURFACE_MONGO_HOST}:#{SURFACE_MONGO_PORT}"
  end

  after(:all) do
    %w[TINA4_MONGO_URI TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT TINA4_KAFKA_BROKERS].each { |k| ENV.delete(k) }
    (@env_snapshot || {}).each { |k, v| ENV[k] = v }
  end

  # Every TINA4_TEST_* name spelled out literally, as a QUOTED string so the
  # contract gate can see it. These were built by interpolation, which no static
  # scan can resolve, so test_env_contract_spec could not check them - a hole in
  # the gate. An unknown backend now raises KeyError rather than quietly reading
  # a name nobody declared. See spec/fixtures/test_env_contract.json (ADR-0038).
  SURFACE_BROKER_ENV = {
    "rabbitmq" => ["TINA4_TEST_RABBITMQ_HOST", "TINA4_TEST_RABBITMQ_PORT"],
    "kafka"    => ["TINA4_TEST_KAFKA_HOST", "TINA4_TEST_KAFKA_PORT"]
  }.freeze

  # Resolve a backend's host/port from the runner env, skipping (or failing
  # under TINA4_REQUIRE_SERVICES) when the service is absent.
  def broker_ready?(backend, default_port)
    host_var, port_var = SURFACE_BROKER_ENV.fetch(backend)
    host = ENV[host_var] || "127.0.0.1"
    port = (ENV[port_var] || default_port.to_s).to_i
    unless self.class.reachable?(host, port)
      why = "#{backend} is not reachable at #{host}:#{port}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      return false
    end
    # Set ONLY this backend's vars. Setting the RabbitMQ host/port
    # unconditionally meant the kafka probe overwrote TINA4_RABBITMQ_PORT with
    # 9092, and bunny then dialled the Kafka port and got an empty response.
    if backend == "rabbitmq"
      ENV["TINA4_RABBITMQ_HOST"] = host
      ENV["TINA4_RABBITMQ_PORT"] = port.to_s
    else
      ENV["TINA4_KAFKA_BROKERS"] = "#{host}:#{port}"
    end
    true
  end

  def queue(backend)
    track(Tina4::Queue.new(topic: "surf_#{SecureRandom.hex(6)}", backend: backend))
  end

  # A method must never be ABSENT. NoMethodError means the call site cannot even
  # reach a refusal - the upgrade path is severed rather than degraded, which is
  # the exact scenario ADR-0024 exists to prevent.
  it "every public queue method resolves on every backend" do
    unresolved = []

    backends = %w[lite mongodb]
    backends << "rabbitmq" if broker_ready?("rabbitmq", 5672)
    backends << "kafka" if broker_ready?("kafka", 9092)

    # Each method is exercised TWICE. FRESH catches a method that never
    # initialises what it uses (Python's clear() reached an unconnected
    # collection; on a shared queue an earlier call had already connected,
    # hiding it). SHARED catches state a previous call left behind (PHP's
    # broker socket held FALSE after a failed connect).
    backends.each do |backend|
      %w[fresh shared].each do |mode|
        shared = mode == "shared" ? queue(backend) : nil
        SURFACE_METHODS.each do |name, call|
          q = shared || queue(backend)
          begin
            call.call(q)
          rescue NoMethodError => e
            unresolved << "#{backend}##{name} (#{mode}) - #{e.message}"
          rescue Exception # rubocop:disable Lint/SuppressedException
            # A named refusal, or any runtime failure, is not this invariant's
            # concern - the method resolved.
          end
        end
      end
    end

    expect(unresolved).to eq([]), "methods that do not resolve:\n#{unresolved.join("\n")}"
  end

  # kafka has no queue depth to report, so it answers 0 (ADR-0022 decision 5)
  # rather than raising - and it must not be ABSENT, which is what it was.
  it "a backend that cannot answer a question refuses by name instead of lying" do
    # `return` is illegal inside an RSpec block (LocalJumpError) - skip instead.
    # broker_ready? already RAISES under TINA4_REQUIRE_SERVICES, so this skip
    # only happens on a developer machine with no broker.
    skip "kafka is not reachable" unless broker_ready?("kafka", 9092)

    q = queue("kafka")
    expect(q).to respond_to(:size)
    expect(q.size).to eq(0), "kafka has no queue depth; ADR-0022 records 0 as the answer"

    # push(priority) IS something kafka genuinely cannot do, so it refuses BY
    # NAME rather than silently dropping it.
    expect { q.push({ "m" => "x" }, priority: 9) }
      .to raise_error(NotImplementedError, /kafka.*priority/mi)
  end

  # NEGATIVE: without this, "make every method raise a named refusal" would
  # satisfy both examples above while breaking the whole queue. A backend that
  # CAN answer must actually answer.
  it "a supported method returns a real answer rather than a refusal" do
    %w[lite mongodb].each do |backend|
      q = queue(backend)
      expect(q.size).to be_a(Integer), "#{backend}: size must return a real count"
      expect(q.failed).to be_a(Array), "#{backend}: failed must return a real list"
      expect(q.dead_letters).to be_a(Array), "#{backend}: dead_letters must return a real list"
    end
  end
end
