# frozen_string_literal: true

# queue_contract.json :: delay-is-honoured-on-every-backend
#
# MEASURED 2026-08-03: push(payload, delay_seconds:) was silently DROPPED on
# every non-file backend, in ALL FOUR frameworks. A scheduled job fired
# immediately in production and on time in development — the worst shape of
# divergence, because the environment you test in is the one that behaves
# correctly.
#
# Ruby had TWO halves of the same bug on Mongo: enqueue never wrote the
# available_at that Queue#push had already computed, AND dequeue never filtered
# on it. Writing the field alone would have changed nothing.
#
# The fix splits by what each broker can actually do:
#   mongodb   implemented — a delayed job is stamped available_at in the future
#             and dequeue now claims only what has come due.
#   rabbitmq  RAISES — no per-message delay in core.
#   kafka     RAISES — no per-message delay at all.
#
# Per queue invariant 6, a backend that genuinely cannot perform an operation
# raises naming the backend AND the operation. It may never silently no-op.
#
# NO MOCKS. Every assertion drives a live MongoDB over TCP. If it is unreachable
# the group skips, unless TINA4_REQUIRE_SERVICES is set — then a missing service
# is a FAILURE, because a suite that silently skips its only real verification
# is not verification.
#
# The four case names here are shared VERBATIM with the Python, PHP and Node
# suites, because scripts/audit-contract-fixtures.py resolves ONE fixture case
# against EVERY framework's file.

require "spec_helper"
require "socket"
require "securerandom"

RSpec.describe "Queue delay invariant" do

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
  # Long enough that a dropped delay is unambiguous, short enough to keep the
  # suite quick. A dropped delay shows up instantly, so this is no race.
  DELAY_SECONDS = 3

  HOST = ENV["TINA4_TEST_MONGO_HOST"] || "127.0.0.1"
  PORT = (ENV["TINA4_TEST_MONGO_PORT"] || "27017").to_i

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
    unless self.class.reachable?(HOST, PORT)
      why = "MongoDB is not reachable at #{HOST}:#{PORT}"
      raise "TINA4_REQUIRE_SERVICES is set but #{why}" if ENV["TINA4_REQUIRE_SERVICES"]

      skip why
    end
    ENV["TINA4_MONGO_URI"] = "mongodb://#{HOST}:#{PORT}"
  end

  after(:all) do
    %w[TINA4_MONGO_URI TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT TINA4_KAFKA_BROKERS].each { |k| ENV.delete(k) }
    (@env_snapshot || {}).each { |k, v| ENV[k] = v }
  end

  def mongo_queue
    track(Tina4::Queue.new(topic: "delay_#{SecureRandom.hex(6)}", backend: "mongodb"))
  end

  # NEGATIVE: without this pair, "never return anything" passes both delay
  # examples below. It also proves the queue itself works, so a failure there is
  # really about the delay and not about a broken backend.
  it "an undelayed job is visible immediately" do
    queue = mongo_queue
    queue.push({ "m" => "undelayed" })
    sleep 1

    expect(queue.pop).not_to be_nil, "an undelayed job must be available at once"
  end

  # The measured defect: this job used to come straight back.
  it "a delayed job is not visible before its delay elapses" do
    queue = mongo_queue
    queue.push({ "m" => "delayed" }, delay_seconds: DELAY_SECONDS)
    sleep 1

    expect(queue.pop).to be_nil, "a delayed job must not be claimable before its delay"
  end

  # NEGATIVE of the negative: "hide it forever" would satisfy the example above
  # while losing the job outright. The delay must expire.
  it "a delayed job becomes visible once its delay elapses" do
    queue = mongo_queue
    queue.push({ "m" => "delayed" }, delay_seconds: DELAY_SECONDS)
    sleep DELAY_SECONDS + 2

    expect(queue.pop).not_to be_nil, "a delayed job must be claimable after its delay"
  end

  # These two brokers have no per-message delay. Silently discarding it is the
  # failure mode invariant 6 exists to forbid, so they raise naming both the
  # backend and the operation — and never touch the network to do it, which is
  # why this example needs no live broker.
  #
  # Ruby's RabbitmqBackend opens its connection in #initialize (Python and PHP
  # connect lazily), so unlike the other three suites this example cannot even
  # CONSTRUCT the queue without a live broker. Hence the same reachability
  # guard as Mongo rather than a double.
  it "a backend that cannot delay refuses instead of dropping the delay" do
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

      queue = track(Tina4::Queue.new(topic: "delay_#{SecureRandom.hex(6)}", backend: backend))

      expect { queue.push({ "m" => "delayed" }, delay_seconds: DELAY_SECONDS) }
        .to raise_error(NotImplementedError, /#{backend}.*delay/mi),
            "the #{backend} backend must refuse a delayed push, naming itself and the operation"
    ensure
      saved.each { |k, v| ENV[k] = v }
      %w[TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT TINA4_KAFKA_BROKERS].each do |k|
        ENV.delete(k) unless saved.key?(k)
      end
    end
  end
end
