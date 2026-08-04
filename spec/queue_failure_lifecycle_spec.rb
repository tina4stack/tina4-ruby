# frozen_string_literal: true

# queue_contract.json :: the-failure-lifecycle-is-real-everywhere
#
# MEASURED 2026-08-04, and this invariant was OWED with no suite at all - which
# is why every defect below shipped.
#
# The rule: job.fail() reaches the backend on EVERY provider, and a job past
# max_retries becomes observable through dead_letters on EVERY provider. A
# dead-letter handler written against the file backend must find the same jobs
# after deploying onto Mongo or a broker.
#
# What was actually measured in RUBY before the fix, and it was the worst of the
# four:
#
#   rabbitmq  job.fail() NEVER REACHED THE BROKER. Job#fail was guarded by
#             `respond_to?(:fail)` and the broker backends defined no fail
#             method, so it bumped an in-memory counter and set @status while
#             the broker was never told. Measured: `backend responds to :fail?
#             false`, then failed()=0, dead_letters()=0, size(pending)=0 - the
#             job left the queue with no failure record and no dead letter.
#   mongodb   failed() did not exist at all, and Queue#failed silently returned
#             [] for it. retry_failed matched status="failed", which the
#             retryable path never writes, so it updated nothing and reported 0.
#   mongodb   dead_letters rebuilt jobs from topic/payload/id only, dropping
#             attempts and error, and fail() never persisted the final
#             increment - so a handler logging "died after N attempts: <reason>"
#             printed "died after 0 attempts:".
#   all       Queue#failed/#retry/#dead_letters/#purge/#retry_failed each began
#             `return [] / false / 0 unless @backend.respond_to?(...)`, turning
#             "this backend cannot do this" into "nothing has failed".
#
# These cases pin the WHOLE lifecycle, not just the happy path. The first case
# is the boundary (retry, not dead-letter) and the completed-job case is the
# control: without them, "dead-letter everything on first failure" passes the
# past-max-retries case, and "return every job ever seen" passes the rest.
#
# NO MOCKS. Every assertion drives a live MongoDB over TCP, and the refusal case
# drives a live RabbitMQ. If a service is unreachable the file skips, unless
# TINA4_REQUIRE_SERVICES is set - then a missing service is a FAILURE.
#
# The six case names here are shared VERBATIM with the Python, PHP and Node
# suites, because scripts/audit-contract-fixtures.py resolves ONE fixture case
# against EVERY framework's file.
#
# EVERY constant below is prefixed FAILLC_. A bare constant assigned inside an
# RSpec.describe block is defined on Object - it is GLOBAL, and a bare HOST/PORT
# here would silently overwrite another spec file's.

require "spec_helper"
require "socket"

FAILLC_MONGO_HOST = ENV.fetch("TINA4_TEST_MONGO_HOST", "127.0.0.1")
FAILLC_MONGO_PORT = ENV.fetch("TINA4_TEST_MONGO_PORT", "27017").to_i
FAILLC_RABBIT_HOST = ENV.fetch("TINA4_TEST_RABBITMQ_HOST", "127.0.0.1")
FAILLC_RABBIT_PORT = ENV.fetch("TINA4_TEST_RABBITMQ_PORT", "5672").to_i
FAILLC_MAX_RETRIES = 2

def faillc_reachable?(host, port)
  Socket.tcp(host, port, connect_timeout: 2, &:close)
  true
rescue StandardError
  false
end

RSpec.describe "Queue failure lifecycle (live, no mocks)" do
  before(:all) do
    unless faillc_reachable?(FAILLC_MONGO_HOST, FAILLC_MONGO_PORT)
      if ENV["TINA4_REQUIRE_SERVICES"]
        raise "TINA4_REQUIRE_SERVICES is set but MongoDB is not reachable at " \
              "#{FAILLC_MONGO_HOST}:#{FAILLC_MONGO_PORT}"
      end
      skip "MongoDB not reachable at #{FAILLC_MONGO_HOST}:#{FAILLC_MONGO_PORT}"
    end
  end

  # Env is set per-example and RESTORED in an ensure, so a broker variable set
  # for one backend can never leak into another spec file's run.
  around do |example|
    saved = ENV.to_h.slice(
      "TINA4_MONGO_URI", "TINA4_QUEUE_MONGO_URI", "TINA4_QUEUE_PATH",
      "TINA4_RABBITMQ_HOST", "TINA4_RABBITMQ_PORT"
    )
    ENV["TINA4_MONGO_URI"] = "mongodb://#{FAILLC_MONGO_HOST}:#{FAILLC_MONGO_PORT}"
    ENV["TINA4_QUEUE_MONGO_URI"] = ENV["TINA4_MONGO_URI"]
    ENV["TINA4_QUEUE_PATH"] = Dir.mktmpdir("faillc")
    begin
      example.run
    ensure
      %w[TINA4_MONGO_URI TINA4_QUEUE_MONGO_URI TINA4_QUEUE_PATH
         TINA4_RABBITMQ_HOST TINA4_RABBITMQ_PORT].each do |k|
        saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k)
      end
      @faillc_queues&.each { |q| q.backend.close if q.backend.respond_to?(:close) }
    end
  end

  # A FRESH queue per call, deliberately. Reusing one instance across a loop is
  # how the surface-invariant test once passed with its fix reverted: an earlier
  # call had already connected, so the defect could not reproduce.
  def faillc_queue(backend)
    q = Tina4::Queue.new(
      topic: "faillc_#{SecureRandom.hex(6)}",
      backend: backend,
      max_retries: FAILLC_MAX_RETRIES
    )
    (@faillc_queues ||= []) << q
    q
  end

  def faillc_drain_fail(queue, times, prefix = "boom")
    (1..times).each do |attempt|
      job = queue.pop
      break if job.nil?

      job.fail("#{prefix}-#{attempt}")
      sleep 0.3
    end
  end

  # Both backends implement the full lifecycle, so both must answer identically.
  # That equality IS the invariant - testing only one proves nothing about the swap.
  %w[file mongodb].each do |backend|
    context "on the #{backend} backend" do
      it "a failed job under max retries is retried rather than dead lettered" do
        queue = faillc_queue(backend)
        queue.push({ "m" => "transient" })
        sleep 0.4

        job = queue.pop
        expect(job).not_to be_nil
        job.fail("boom-1")
        sleep 0.4

        expect(queue.dead_letters).to be_empty,
                                      "a job with retries left must NOT be dead-lettered"
        # THE defect this invariant was owed for: on mongodb failed() did not
        # exist and Queue#failed silently returned []. Asserting only "not
        # dead-lettered" would still pass with that bug - the job has to be
        # positively REPORTABLE as failed.
        expect(queue.failed.length).to eq(1),
                                       "a job that failed with retries left must be reported by failed()"
        expect(queue.pop).not_to be_nil,
                                 "a job with retries left must come back for another attempt"
      end

      # SHARED PARITY CASE - this description exists VERBATIM in the Python, PHP
      # and Node suites, so one fixture case resolves against all four files.
      #
      # A job you popped must carry its own lifecycle. PHP was the last
      # framework where it did not: Queue::pop() returned the backend's raw
      # array, so `$queue->pop()->fail("boom")` was a fatal there while the
      # identical line worked here, in Python and in Node.
      #
      # The assertions are on the QUEUE's state after each call, never on the
      # job's own fields: a fail that only set an in-memory status would satisfy
      # an object-level check while the backend never heard about it.
      it "a popped job carries its own lifecycle methods" do
        queue = faillc_queue(backend)
        queue.push({ "m" => "lifecycle" })
        sleep 0.4

        job = queue.pop
        expect(job).not_to be_nil
        expect(job).to respond_to(:fail), "a popped job must expose fail"
        expect(job).to respond_to(:complete), "a popped job must expose complete"

        # Called DIRECTLY on what pop returned - no re-wrap, no queue-level call.
        job.fail("boom-1")
        sleep 0.4

        expect(queue.failed.length).to eq(1),
                                       "fail called on a popped job must reach the backend"

        again = queue.pop
        expect(again).not_to be_nil, "a job with retries left must come back"
        again.complete
        sleep 0.4
        expect(queue.failed).to be_empty,
                                "complete called on a popped job must reach the backend"
      end

      it "a job past max retries becomes a dead letter" do
        queue = faillc_queue(backend)
        queue.push({ "m" => "poison" })
        sleep 0.4

        faillc_drain_fail(queue, FAILLC_MAX_RETRIES)
        sleep 0.4

        expect(queue.dead_letters.length).to eq(1),
                                             "a job past max_retries must appear in dead_letters"
        expect(queue.pop).to be_nil,
                             "a dead-lettered job must NOT still be redelivered"
      end

      it "a dead letter carries the attempt count and the failure reason" do
        queue = faillc_queue(backend)
        queue.push({ "m" => "poison" })
        sleep 0.4

        faillc_drain_fail(queue, FAILLC_MAX_RETRIES)
        sleep 0.4

        dead = queue.dead_letters
        expect(dead.length).to eq(1)
        # Hash access, not .attempts: dead_letters returns plain hashes with
        # string keys on EVERY backend. The mongo backend alone used to return
        # Job objects, which is the divergence this invariant removed.
        expect(dead.first["attempts"]).to eq(FAILLC_MAX_RETRIES),
                                          "dead letter lost the attempt count"
        expect(dead.first["error"]).to eq("boom-#{FAILLC_MAX_RETRIES}"),
                                       "dead letter lost the failure reason"
      end

      it "a completed job never appears in dead letters" do
        queue = faillc_queue(backend)
        queue.push({ "m" => "healthy" })
        sleep 0.4

        job = queue.pop
        expect(job).not_to be_nil
        job.complete
        sleep 0.4

        expect(queue.dead_letters).to be_empty,
                                      "a completed job must never be reported as dead"
        expect(queue.failed).to be_empty,
                                "a completed job must never be reported as failed"
      end

      it "reading dead letters does not consume them" do
        queue = faillc_queue(backend)
        queue.push({ "m" => "poison" })
        sleep 0.4

        faillc_drain_fail(queue, FAILLC_MAX_RETRIES)
        sleep 0.4

        counts = Array.new(3) { queue.dead_letters.length }
        expect(counts).to eq([1, 1, 1]),
                          "reading dead_letters changed the result across reads: #{counts.inspect}"
      end
    end
  end

  it "failing a job reaches the configured backend and not just local memory" do
    # THE headline defect, and the one none of the cases above can catch: they
    # all run on file/mongodb, where the backend HAS a fail method, so restoring
    # the old `respond_to?(:fail)` guard would leave them green. Only a broker
    # exposes it - Ruby's rabbitmq/kafka backends defined no fail, so Job#fail
    # fell through to in-memory bookkeeping and the BROKER WAS NEVER TOLD.
    #
    # The proof is redelivery carrying the incremented count. With the guard,
    # nothing is re-published, the delivery stays unacked, and the next pop
    # returns nil (measured: failed()=0, dead_letters()=0, size(pending)=0).
    unless faillc_reachable?(FAILLC_RABBIT_HOST, FAILLC_RABBIT_PORT)
      if ENV["TINA4_REQUIRE_SERVICES"]
        raise "TINA4_REQUIRE_SERVICES is set but RabbitMQ is not reachable at " \
              "#{FAILLC_RABBIT_HOST}:#{FAILLC_RABBIT_PORT}"
      end
      skip "RabbitMQ not reachable at #{FAILLC_RABBIT_HOST}:#{FAILLC_RABBIT_PORT}"
    end

    ENV["TINA4_RABBITMQ_HOST"] = FAILLC_RABBIT_HOST
    ENV["TINA4_RABBITMQ_PORT"] = FAILLC_RABBIT_PORT.to_s
    queue = faillc_queue("rabbitmq")

    queue.push({ "m" => "poison" })
    sleep 0.5
    job = queue.pop
    expect(job).not_to be_nil
    job.fail("boom-1")
    sleep 0.5

    redelivered = queue.pop
    expect(redelivered).not_to be_nil,
                               "fail() did not reach the broker - nothing was redelivered"
    expect(redelivered.attempts).to eq(1),
                                    "the attempt count did not survive the round-trip through the broker"

    redelivered.fail("boom-2")
    sleep 0.5
    dead = queue.dead_letters
    expect(dead.length).to eq(1),
                           "a broker job past max_retries must reach the dead-letter queue"
    expect(dead.first["attempts"]).to eq(FAILLC_MAX_RETRIES)
    expect(dead.first["error"]).to eq("boom-#{FAILLC_MAX_RETRIES}")
  end

  it "a backend that cannot enumerate retryable failures refuses by name" do
    unless faillc_reachable?(FAILLC_RABBIT_HOST, FAILLC_RABBIT_PORT)
      if ENV["TINA4_REQUIRE_SERVICES"]
        raise "TINA4_REQUIRE_SERVICES is set but RabbitMQ is not reachable at " \
              "#{FAILLC_RABBIT_HOST}:#{FAILLC_RABBIT_PORT}"
      end
      skip "RabbitMQ not reachable at #{FAILLC_RABBIT_HOST}:#{FAILLC_RABBIT_PORT}"
    end

    ENV["TINA4_RABBITMQ_HOST"] = FAILLC_RABBIT_HOST
    ENV["TINA4_RABBITMQ_PORT"] = FAILLC_RABBIT_PORT.to_s
    queue = faillc_queue("rabbitmq")

    # rescue Exception, NOT StandardError: NotImplementedError descends from
    # ScriptError, so a bare `rescue` does NOT catch it. expect {}.to
    # raise_error is ancestry-agnostic, but the message checks below are the
    # point - the refusal must name the backend AND the operation.
    expect { queue.failed }.to raise_error(NotImplementedError, /rabbitmq/)
    expect { queue.failed }.to raise_error(NotImplementedError, /failed\(\)/)

    expect { queue.retry_failed }.to raise_error(NotImplementedError, /rabbitmq/)
    # retry_failed must carry its OWN refusal - letting failed()'s message
    # escape would name the wrong operation to the caller.
    expect { queue.retry_failed }.to raise_error(NotImplementedError, /retry_failed\(\)/)
  end
end
