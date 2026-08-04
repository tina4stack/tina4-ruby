# frozen_string_literal: true

# Queue#close - the connection an app opens must be one it can hand back.
#
# MEASURED 2026-08-04: close was ABSENT on the top-level Queue class in ALL FOUR
# frameworks. The backends below it were in four different states -
#
#   ruby    close on rabbitmq/mongo/kafka, MISSING on lite. So every
#           `backend.close if backend.respond_to?(:close)` guard in the tree
#           silently did nothing on the DEFAULT backend, and none of them was
#           reachable from Queue anyway. The three that existed were also NOT
#           idempotent: they left @connection/@producer set, and both Bunny and
#           rdkafka raise on closing an already-closed handle.
#   php     close on the QueueBackend INTERFACE and all four backends, surfaced
#           on nothing.
#   nodejs  nowhere on any backend class.
#   python  nowhere at all on the queue adapters.
#
# - so an application holding a broker- or Mongo-backed queue had NO WAY to
# release the connection. Build a Queue per request and you leak one client per
# request, invisibly, until the broker refuses new connections. That is exactly
# the leak ADR-0025 corollary 4 (client-lifecycle-is-bounded) fixed in DocStore.
#
# The three cases are positive AND negative on purpose:
#
#   1. closing releases the connection      - the POSITIVE rule. A close that
#                                             exists but delegates nowhere fails
#                                             here and nowhere else.
#   2. closing twice is safe                - NEGATIVE, and the case Ruby was
#                                             actually failing: Bunny raises
#                                             Bunny::ChannelAlreadyClosed and
#                                             rdkafka raises on a re-close, so a
#                                             shutdown path that ran twice
#                                             crashed on the second pass.
#   3. closing the lite backend is no error - NEGATIVE. The zero-config default
#                                             holds no connection and close must
#                                             be a no-op there, not a
#                                             NoMethodError.
#
# NO MOCKS. Every handle inspected here belongs to a REAL backend holding a REAL
# socket to a REAL MongoDB / RabbitMQ / Kafka over TCP; the lite cases use the
# real on-disk store. instance_variable_get reads the real object's real state -
# it substitutes nothing and simulates nothing. A service that is unreachable
# skips, unless TINA4_REQUIRE_SERVICES is set - then it is a FAILURE, because a
# suite that silently skips its only real verification is not verification.
#
# The three case names are shared VERBATIM with the Python, PHP and Node suites,
# so one fixture case in scripts/audit-contract-fixtures.py resolves against
# EVERY framework's file.
#
# EVERY constant and helper below is prefixed QCLOSE_/qclose_. A bare constant
# assigned in a spec file is defined on Object - it is GLOBAL, and a bare
# HANDLE_IVARS here would silently overwrite another spec file's.

require "spec_helper"
require "socket"

QCLOSE_MONGO_HOST = ENV.fetch("TINA4_TEST_MONGO_HOST", "127.0.0.1")
QCLOSE_MONGO_PORT = ENV.fetch("TINA4_TEST_MONGO_PORT", "27017").to_i
QCLOSE_RABBIT_HOST = ENV.fetch("TINA4_TEST_RABBITMQ_HOST", "127.0.0.1")
QCLOSE_RABBIT_PORT = ENV.fetch("TINA4_TEST_RABBITMQ_PORT", "5672").to_i
QCLOSE_KAFKA_HOST = ENV.fetch("TINA4_TEST_KAFKA_HOST", "127.0.0.1")
QCLOSE_KAFKA_PORT = ENV.fetch("TINA4_TEST_KAFKA_PORT", "9092").to_i

# Backends that hold a real connection: [service name, host, port, client gem].
QCLOSE_SERVICES = {
  "mongodb" => ["MongoDB", QCLOSE_MONGO_HOST, QCLOSE_MONGO_PORT, "mongo"],
  "rabbitmq" => ["RabbitMQ", QCLOSE_RABBIT_HOST, QCLOSE_RABBIT_PORT, "bunny"],
  "kafka" => ["Kafka", QCLOSE_KAFKA_HOST, QCLOSE_KAFKA_PORT, "rdkafka"]
}.freeze
QCLOSE_CONNECTED_BACKENDS = %w[mongodb rabbitmq kafka].freeze

# Every ivar a queue backend uses to hold a LIVE connection. Configuration
# ivars (@uri, @brokers, @dir) are deliberately absent - close releases
# connections, not settings.
QCLOSE_HANDLE_IVARS = %i[@client @db @connection @channel @producer @consumer].freeze

def qclose_reachable?(host, port)
  Socket.tcp(host, port, connect_timeout: 2, &:close)
  true
rescue StandardError
  false
end

def qclose_gem_loadable?(name)
  require name
  true
rescue LoadError
  false
end

# Names of the connection handles the queue's backend is holding RIGHT NOW.
def qclose_live_handles(queue)
  backend = queue.backend
  QCLOSE_HANDLE_IVARS.select do |ivar|
    backend.instance_variable_defined?(ivar) && !backend.instance_variable_get(ivar).nil?
  end
end

RSpec.describe "Queue#close releases the backend (live, no mocks)" do
  # Skip, or FAIL under TINA4_REQUIRE_SERVICES. A silent skip is not proof.
  def qclose_require_service(backend)
    name, host, port, gem_name = QCLOSE_SERVICES.fetch(backend)
    missing =
      if !qclose_gem_loadable?(gem_name)
        "the '#{gem_name}' gem is not installed"
      elsif !qclose_reachable?(host, port)
        "#{name} is not reachable at #{host}:#{port}"
      end
    return if missing.nil?

    raise "TINA4_REQUIRE_SERVICES is set but #{missing}" if ENV["TINA4_REQUIRE_SERVICES"]

    skip missing
  end

  # A FRESH queue per call, deliberately: reusing one instance across backends
  # is how a connection opened by an earlier call makes a later assertion pass
  # for the wrong reason.
  def qclose_make_queue(backend)
    queue = Tina4::Queue.new(
      topic: "qclose_#{SecureRandom.hex(6)}",
      backend: backend,
      max_retries: 2
    )
    (@qclose_queues ||= []) << queue
    queue
  end

  around do |example|
    saved = ENV.to_h.slice(
      "TINA4_QUEUE_BACKEND", "TINA4_QUEUE_URL", "TINA4_MONGO_URI",
      "TINA4_RABBITMQ_HOST", "TINA4_RABBITMQ_PORT", "TINA4_KAFKA_BROKERS"
    )
    # TINA4_QUEUE_BACKEND would override the explicit backend: argument, and a
    # stray TINA4_QUEUE_URL re-points every broker at someone else's host.
    ENV.delete("TINA4_QUEUE_BACKEND")
    ENV.delete("TINA4_QUEUE_URL")
    ENV["TINA4_MONGO_URI"] = "mongodb://#{QCLOSE_MONGO_HOST}:#{QCLOSE_MONGO_PORT}"
    ENV["TINA4_RABBITMQ_HOST"] = QCLOSE_RABBIT_HOST
    ENV["TINA4_RABBITMQ_PORT"] = QCLOSE_RABBIT_PORT.to_s
    ENV["TINA4_KAFKA_BROKERS"] = "#{QCLOSE_KAFKA_HOST}:#{QCLOSE_KAFKA_PORT}"
    @qclose_queues = []
    begin
      example.run
    ensure
      # Reap what we spawn: a connection left open by a FAILING case must not be
      # inherited by the next one. Idempotent, which is case 2's whole point.
      @qclose_queues&.each do |queue|
        queue.close
      rescue StandardError
        nil
      end
      %w[TINA4_QUEUE_BACKEND TINA4_QUEUE_URL TINA4_MONGO_URI
         TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT TINA4_KAFKA_BROKERS].each do |key|
        saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key)
      end
    end
  end

  # POSITIVE: close reaches the backend and the live handle is given back.
  #
  # The push is not decoration - it drives real traffic over the connection, so
  # the handle being released is one that genuinely carried a job.
  it "closing a queue releases the backend connection" do
    QCLOSE_CONNECTED_BACKENDS.each do |backend|
      qclose_require_service(backend)

      queue = qclose_make_queue(backend)
      queue.push({ "m" => "connect" })

      held = qclose_live_handles(queue)
      expect(held).not_to be_empty,
                          "#{backend}: expected a live connection handle after a real push, found none " \
                          "- the test cannot prove a release that never had anything to release"

      queue.close

      still_open = qclose_live_handles(queue)
      expect(still_open).to eq([]),
                            "#{backend}: close left #{still_open.inspect} still held - the connection " \
                            "was never released, which is the leak this exists to stop"
    end
  end

  # NEGATIVE: a second close must be a no-op, never an exception.
  #
  # This is the case Ruby was actually failing. Bunny raises on closing an
  # already-closed channel and rdkafka raises on an already-closed consumer, so
  # a shutdown path that ran twice (an explicit close plus an at_exit/ensure)
  # crashed on the second pass - and an `ensure queue.close` masked the original
  # error with the close error.
  it "closing a queue twice is safe" do
    (["lite"] + QCLOSE_CONNECTED_BACKENDS).each do |backend|
      qclose_require_service(backend) unless backend == "lite"

      queue = qclose_make_queue(backend)
      queue.push({ "m" => "connect" })

      expect { queue.close; queue.close }.not_to raise_error,
                                                 "#{backend}: closing twice must not raise"

      expect(qclose_live_handles(queue)).to eq([]),
                                            "#{backend}: a handle is still held after two closes"
    end
  end

  # NEGATIVE: the zero-config default has no connection, and must not care.
  #
  # The lite backend is what every app gets before it configures anything, and
  # it was the ONE backend with no close at all - so `queue.close` on the
  # default would have been a NoMethodError, and every respond_to? guard in the
  # tree silently skipped it. This pins that the no-op is real, and that it does
  # not disturb the queue's contents.
  it "closing a file backed queue is not an error" do
    queue = qclose_make_queue("lite")
    queue.push({ "m" => "on disk" })

    before = queue.size(status: "pending")
    expect(before).to eq(1), "lite: expected the pushed job to be pending, got #{before}"

    expect { queue.close }.not_to raise_error

    expect(qclose_live_handles(queue)).to eq([]), "lite: the file backend must hold no connection"
    expect(queue.size(status: "pending")).to eq(before),
                                             "lite: close must not disturb the queue contents - it has nothing to close"

    queue.clear
  end
end
