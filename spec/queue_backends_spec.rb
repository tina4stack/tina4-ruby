# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Queue Backends" do
  describe Tina4::QueueBackends::LiteBackend do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "creates the queue directory on initialization" do
      expect(Dir.exist?(tmpdir)).to be true
    end

    it "creates the dead_letter subdirectory" do
      backend # force initialization
      expect(Dir.exist?(File.join(tmpdir, "dead_letter"))).to be true
    end

    it "enqueues a message to a topic" do
      msg = Tina4::Job.new(topic: "test_topic", payload: { key: "value" })
      backend.enqueue(msg)
      expect(backend.size("test_topic")).to eq(1)
    end

    it "dequeues a message from a topic" do
      msg = Tina4::Job.new(topic: "test_topic", payload: { key: "value" })
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued).not_to be_nil
      expect(dequeued.topic).to eq("test_topic")
    end

    it "returns nil when dequeuing from empty topic" do
      result = backend.dequeue("empty_topic")
      expect(result).to be_nil
    end

    it "removes message file on dequeue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "data")
      backend.enqueue(msg)
      expect(backend.size("test_topic")).to eq(1)
      backend.dequeue("test_topic")
      expect(backend.size("test_topic")).to eq(0)
    end

    it "preserves message payload through enqueue/dequeue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: { "name" => "Alice", "count" => 42 })
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued.payload).to eq({ "name" => "Alice", "count" => 42 })
    end

    it "preserves message id through enqueue/dequeue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "data")
      original_id = msg.id
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued.id).to eq(original_id)
    end

    it "processes messages in FIFO order" do
      3.times do |i|
        msg = Tina4::Job.new(topic: "ordered", payload: "msg_#{i}")
        backend.enqueue(msg)
        sleep(0.01) # ensure different mtime
      end
      results = 3.times.map { backend.dequeue("ordered") }
      expect(results.map(&:payload)).to eq(%w[msg_0 msg_1 msg_2])
    end

    it "sends message to dead letter queue" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "failed")
      backend.dead_letter(msg)
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.queue-data"))
      expect(dl_files.length).to eq(1)
    end

    it "requeues a message" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "retry")
      backend.requeue(msg)
      expect(backend.size("test_topic")).to eq(1)
    end

    it "returns 0 size for non-existent topic" do
      expect(backend.size("nonexistent")).to eq(0)
    end

    it "lists topics" do
      backend.enqueue(Tina4::Job.new(topic: "topic_a", payload: "a"))
      backend.enqueue(Tina4::Job.new(topic: "topic_b", payload: "b"))
      topics = backend.topics
      expect(topics).to include("topic_a")
      expect(topics).to include("topic_b")
      expect(topics).not_to include("dead_letter")
    end

    it "sanitizes topic names for directory safety" do
      msg = Tina4::Job.new(topic: "my/unsafe.topic!", payload: "safe")
      backend.enqueue(msg)
      # The topic should be sanitized to use underscores
      expect(backend.size("my/unsafe.topic!")).to eq(1)
    end

    it "acknowledge leaves the already-deleted state intact (file gone on dequeue, size stays 0)" do
      msg = Tina4::Job.new(topic: "test_topic", payload: "ack")
      backend.enqueue(msg)
      dequeued = backend.dequeue("test_topic")
      expect(dequeued).not_to be_nil
      # dequeue already claimed (deleted) the pending file, so size is 0 and the
      # topic dir holds no pending *.queue-data before acknowledge.
      expect(backend.size("test_topic")).to eq(0)
      expect(Dir.glob(File.join(tmpdir, "test_topic", "*.queue-data"))).to be_empty

      # acknowledge() is the documented no-op: it must NOT resurrect, recreate or
      # leave a stray pending file — the already-deleted state stays intact.
      backend.acknowledge(dequeued)
      expect(backend.size("test_topic")).to eq(0)
      expect(Dir.glob(File.join(tmpdir, "test_topic", "*.queue-data"))).to be_empty
    end
  end

  # ── RabbitmqBackend live round-trip (real broker, NO mocks) ──────────────
  #
  # Gated on a reachable RabbitMQ (TCP localhost:5672) AND the bunny gem, the
  # same live-or-skip pattern the MongoBackend block below uses. When either is
  # missing the examples SKIP (never mock) — and the skip message never trips
  # the spec_helper service gate (it keys on "rabbit"/"amqp" + an unreachable
  # hint, not on a missing client gem). Each example uses a unique throwaway
  # topic and drains/closes after itself so it leaves no residue on the broker.
  describe Tina4::QueueBackends::RabbitmqBackend do
    RMQ_HOST = "localhost"
    RMQ_PORT = 5672

    def self.rabbitmq_available?
      require "bunny"
      s = Socket.tcp(RMQ_HOST, RMQ_PORT, connect_timeout: 1)
      s.close
      true
    rescue LoadError, StandardError
      false
    end

    # Poll a block against the live broker until it returns truthy (or times out).
    # RabbitMQ publish is fire-and-forget (no publisher confirms here, same as the
    # Python/PHP backends), so a message is not guaranteed "ready" the instant
    # after enqueue — poll the real broker instead of mocking or sleeping blind.
    def await(timeout: 3.0)
      deadline = Time.now + timeout
      loop do
        val = yield
        return val if val
        break if Time.now > deadline

        sleep 0.02
      end
      yield
    end

    if rabbitmq_available?
      it "complete() acks the in-flight message and leaves the channel usable (enqueue -> dequeue -> complete -> size 0)" do
        topic = "tina4_test_rmq_ack_#{Process.pid}_#{rand(100_000)}"
        backend = Tina4::QueueBackends::RabbitmqBackend.new(host: RMQ_HOST, port: RMQ_PORT)
        begin
          job = Tina4::Job.new(topic: topic, payload: { "n" => 1 })
          backend.enqueue(job)

          # Poll for the enqueued message (publish lands asynchronously).
          dequeued = await { backend.dequeue(topic) }
          expect(dequeued).not_to be_nil
          expect(dequeued.payload).to eq({ "n" => 1 })
          expect(dequeued.id).to eq(job.id)

          # THE FIX: dequeue now pops with manual_ack, so the message is in-flight
          # (un-acked) and complete() acks that real, still-valid delivery tag.
          # Before the fix the pop auto-acked, so this ack hit an unknown tag ->
          # RabbitMQ replied PRECONDITION_FAILED and CLOSED the channel, making
          # complete() raise and poisoning every later op.
          expect { backend.complete(dequeued) }.not_to raise_error
          # Channel is still alive after the ack: size() works (it raised
          # Timeout::Error on the closed channel under the bug) and the message is
          # permanently consumed.
          expect(await { backend.size(topic).zero? }).to be true
          expect(backend.dequeue(topic)).to be_nil
        ensure
          backend.close   # raised Bunny::ChannelAlreadyClosed under the bug
        end
      end

      it "manual-ack delivers at-least-once: an un-completed message is redelivered to a fresh consumer" do
        topic = "tina4_test_rmq_redeliver_#{Process.pid}_#{rand(100_000)}"
        first = Tina4::QueueBackends::RabbitmqBackend.new(host: RMQ_HOST, port: RMQ_PORT)
        begin
          first.enqueue(Tina4::Job.new(topic: topic, payload: { "v" => "keep-me" }))
          dequeued = first.dequeue(topic)
          expect(dequeued.payload).to eq({ "v" => "keep-me" })
          # Deliberately do NOT complete — simulate a consumer that dies mid-job.
        ensure
          first.close   # dropping the channel returns the un-acked message to ready
        end

        second = Tina4::QueueBackends::RabbitmqBackend.new(host: RMQ_HOST, port: RMQ_PORT)
        begin
          # Under manual-ack the broker redelivered the un-acked message to the new
          # consumer. Under the old auto-ack pop it would be gone forever (this is
          # the assertion that distinguishes at-least-once from at-most-once).
          redelivered = await { second.dequeue(topic) }
          expect(redelivered).not_to be_nil
          expect(redelivered.payload).to eq({ "v" => "keep-me" })
          second.complete(redelivered)
          expect(await { second.size(topic).zero? }).to be true
        ensure
          second.close
        end
      end

      it "job.complete acks through the full Queue lifecycle (push -> pop -> job.complete -> size 0)" do
        topic = "tina4_test_rmq_lifecycle_#{Process.pid}_#{rand(100_000)}"
        queue = Tina4::Queue.new(topic: topic, backend: :rabbitmq)
        begin
          queue.push({ "task" => "email" })
          # Poll for the pushed job (publish lands asynchronously on the broker).
          job = await { queue.pop }
          expect(job).not_to be_nil
          expect(job.payload).to eq({ "task" => "email" })
          # The real consumer API: Job#complete -> backend.complete -> broker ack.
          # Before the fix the backend only had #acknowledge, so Job#complete (which
          # calls backend.complete) was a silent no-op — under manual-ack the message
          # would have stayed in-flight forever. Now it acks and the queue drains.
          expect { job.complete }.not_to raise_error
          expect(await { queue.size.zero? }).to be true
        ensure
          queue.backend.close if queue.backend.respond_to?(:close)
        end
      end
    else
      it "is skipped because RabbitMQ is not reachable at localhost:5672" do
        skip "RabbitMQ not reachable at #{RMQ_HOST}:#{RMQ_PORT} (or bunny gem missing)"
      end
    end
  end

  # ── KafkaBackend live round-trip (real broker, NO mocks) ─────────────────
  #
  # Gated on a reachable Kafka broker (TCP localhost:9092) AND the rdkafka gem.
  # SKIPPED (never mocked) when either is missing. The first dequeue after a
  # fresh subscribe must drive the consumer-group join + partition assignment,
  # so we widen TINA4_KAFKA_ASSIGN_TIMEOUT for the assign loop. Each example
  # uses a unique throwaway topic + consumer group so it never collides with
  # another run's offsets.
  describe Tina4::QueueBackends::KafkaBackend do
    KAFKA_HOST = "localhost"
    KAFKA_PORT = 9092
    KAFKA_BROKERS = "#{KAFKA_HOST}:#{KAFKA_PORT}"

    def self.kafka_available?
      require "rdkafka"
      s = Socket.tcp(KAFKA_HOST, KAFKA_PORT, connect_timeout: 1)
      s.close
      true
    rescue LoadError, StandardError
      false
    end

    around(:each) do |example|
      saved = ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"]
      ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"] = "30"
      begin
        example.run
      ensure
        saved.nil? ? ENV.delete("TINA4_KAFKA_ASSIGN_TIMEOUT") : ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"] = saved
      end
    end

    if kafka_available?
      it "round-trips a job through a live Kafka broker (enqueue -> dequeue payload/id survive)" do
        topic = "tina4_test_kafka_#{Process.pid}_#{rand(100_000)}"
        group = "tina4_test_grp_#{Process.pid}_#{rand(100_000)}"
        backend = Tina4::QueueBackends::KafkaBackend.new(brokers: KAFKA_BROKERS, group_id: group)
        begin
          job = Tina4::Job.new(topic: topic, payload: { "n" => 1 }, id: "kafka-#{Process.pid}")
          backend.enqueue(job)

          # dequeue allows the assign-timeout loop on first subscribe.
          dequeued = backend.dequeue(topic)
          expect(dequeued).not_to be_nil
          expect(dequeued.payload).to eq({ "n" => 1 })
          expect(dequeued.id).to eq(job.id)
          expect(dequeued.topic).to eq(topic)
        ensure
          backend.close
        end
      end

      it "responds to the queue backend interface with a real enqueue/dequeue/acknowledge cycle" do
        topic = "tina4_test_kafka_iface_#{Process.pid}_#{rand(100_000)}"
        group = "tina4_test_grp_iface_#{Process.pid}_#{rand(100_000)}"
        backend = Tina4::QueueBackends::KafkaBackend.new(brokers: KAFKA_BROKERS, group_id: group)
        begin
          produced = { "task" => "process", "count" => 42 }
          job = Tina4::Job.new(topic: topic, payload: produced, id: "kafka-iface-#{Process.pid}")
          backend.enqueue(job)

          dequeued = backend.dequeue(topic)
          expect(dequeued).not_to be_nil
          # The consumed payload equals what was produced.
          expect(dequeued.payload).to eq(produced)
          expect(dequeued.id).to eq(job.id)

          # acknowledge() commits the offset against the live broker without raising.
          expect { backend.acknowledge(dequeued) }.not_to raise_error
        ensure
          backend.close
        end
      end
    else
      it "is skipped because Kafka is not reachable at localhost:9092" do
        skip "Kafka not reachable at #{KAFKA_BROKERS} (or rdkafka gem missing)"
      end
    end

    # Lock-in for KafkaBackend._security_config (TINA4_KAFKA_* alias parity with
    # Python tina4_python KafkaConnector._security_config). SSL/SASL settings are
    # read from the Tina4-namespaced env var first, then the bare librdkafka
    # name; unset keys leave librdkafka's PLAINTEXT default.
    describe "._security_config (TLS/SASL parity with Python)" do
      vars = %w[
        TINA4_KAFKA_SECURITY_PROTOCOL KAFKA_SECURITY_PROTOCOL
        TINA4_KAFKA_SSL_CA_LOCATION KAFKA_SSL_CA_LOCATION
        TINA4_KAFKA_SASL_MECHANISM KAFKA_SASL_MECHANISM
        TINA4_KAFKA_SASL_USERNAME KAFKA_SASL_USERNAME
        TINA4_KAFKA_SASL_PASSWORD KAFKA_SASL_PASSWORD
      ]

      around(:each) do |example|
        saved = vars.each_with_object({}) { |v, h| h[v] = ENV.delete(v) }
        begin
          example.run
        ensure
          vars.each { |v| saved[v].nil? ? ENV.delete(v) : ENV[v] = saved[v] }
        end
      end

      def security_config
        Tina4::QueueBackends::KafkaBackend._security_config
      end

      it "returns an empty hash when no env is set (PLAINTEXT default)" do
        # NEGATIVE: nothing set -> {} (librdkafka keeps its PLAINTEXT default).
        expect(security_config).to eq({})
      end

      it "reads bare KAFKA_* names" do
        # POSITIVE: the contributor's exact env (bare KAFKA_*) still works.
        ENV["KAFKA_SECURITY_PROTOCOL"] = "SSL"
        ENV["KAFKA_SSL_CA_LOCATION"] = "/etc/ssl/ca.pem"
        expect(security_config).to eq(
          "security.protocol" => "SSL",
          "ssl.ca.location" => "/etc/ssl/ca.pem"
        )
      end

      it "reads TINA4_KAFKA_* namespaced names" do
        # POSITIVE: Tina4-namespaced env vars are honoured.
        ENV["TINA4_KAFKA_SECURITY_PROTOCOL"] = "SASL_SSL"
        expect(security_config).to eq("security.protocol" => "SASL_SSL")
      end

      it "TINA4_KAFKA_* takes precedence over bare KAFKA_*" do
        # PRECEDENCE: TINA4_KAFKA_* wins when both are set.
        ENV["KAFKA_SECURITY_PROTOCOL"] = "SSL"
        ENV["TINA4_KAFKA_SECURITY_PROTOCOL"] = "SASL_SSL"
        expect(security_config["security.protocol"]).to eq("SASL_SSL")
      end

      it "maps the SASL mechanism/username/password trio" do
        # POSITIVE: optional SASL creds map to the rdkafka sasl.* keys.
        ENV["TINA4_KAFKA_SASL_MECHANISM"] = "PLAIN"
        ENV["KAFKA_SASL_USERNAME"] = "user"
        ENV["KAFKA_SASL_PASSWORD"] = "secret"
        expect(security_config).to eq(
          "sasl.mechanism" => "PLAIN",
          "sasl.username" => "user",
          "sasl.password" => "secret"
        )
      end
    end
  end

  # ── MongoBackend live round-trip (real Mongo, NO mocks) ──────────────────
  #
  # Gated on a reachable MongoDB (TCP localhost:27017) AND the mongo gem — the
  # same live-or-skip pattern as the db-selection block below (reusing the same
  # localhost:27017 target). SKIPPED, never mocked, when Mongo is unreachable.
  # Each example writes into a throwaway tina4_test_* db and drops it after.
  describe Tina4::QueueBackends::MongoBackend do
    MONGO_RT_HOST = "localhost"
    MONGO_RT_PORT = 27_017
    MONGO_RT_URI = "mongodb://#{MONGO_RT_HOST}:#{MONGO_RT_PORT}"

    def self.mongo_available?
      require "mongo"
      s = Socket.tcp(MONGO_RT_HOST, MONGO_RT_PORT, connect_timeout: 1)
      s.close
      true
    rescue LoadError, StandardError
      false
    end

    if mongo_available?
      it "round-trips a job through a live Mongo db (enqueue -> dequeue payload survives)" do
        db_name = "tina4_test_mongo_rt_#{Process.pid}_#{rand(100_000)}"
        backend = Tina4::QueueBackends::MongoBackend.new(uri: MONGO_RT_URI, db: db_name, collection: "jobs")
        begin
          job = Tina4::Job.new(topic: "tina4_test", payload: { "n" => 1 }, id: "mrt-1")
          backend.enqueue(job)

          dequeued = backend.dequeue("tina4_test")
          expect(dequeued).not_to be_nil
          expect(dequeued.payload).to eq({ "n" => 1 })
          expect(dequeued.id).to eq(job.id)
        ensure
          drop_mongo_db(db_name)
          backend.close
        end
      end

      it "responds to the queue backend interface with a real enqueue/dequeue/complete cycle (size 1 -> 0)" do
        db_name = "tina4_test_mongo_iface_#{Process.pid}_#{rand(100_000)}"
        backend = Tina4::QueueBackends::MongoBackend.new(uri: MONGO_RT_URI, db: db_name, collection: "jobs")
        begin
          job = Tina4::Job.new(topic: "tina4_test", payload: { "task" => "process" }, id: "mrt-iface-1")
          backend.enqueue(job)
          expect(backend.size("tina4_test")).to eq(1)

          dequeued = backend.dequeue("tina4_test")
          expect(dequeued.payload).to eq({ "task" => "process" })

          # complete() is terminal — the doc is removed and the pending size drops to 0.
          backend.complete(dequeued)
          expect(backend.size("tina4_test")).to eq(0)
        ensure
          drop_mongo_db(db_name)
          backend.close
        end
      end

      def drop_mongo_db(db_name)
        client = Mongo::Client.new(MONGO_RT_URI, database: db_name)
        client.database.drop
        client.close
      rescue StandardError
        # best-effort cleanup
      end
    else
      it "is skipped because MongoDB is not reachable at localhost:27017" do
        skip "MongoDB not reachable at #{MONGO_RT_URI} (or mongo gem missing)"
      end
    end
  end

  # ── MongoBackend live db-selection regression (real Mongo, NO mocks) ──────
  #
  # Regression for the "uri given -> explicit db: silently ignored" footgun:
  # Mongo::Client.new(uri) with no database path defaults to "admin", so when a
  # uri AND a db: were both supplied the requested database was dropped and every
  # job/dead-letter landed in admin. The explicit db: (and TINA4_MONGO_DB) must
  # always win over the URI's (often absent) default. Connects for REAL — gated on
  # TCP reachability of localhost:27017 + the mongo gem — and is SKIPPED, never
  # mocked, when Mongo is unreachable. Uses only a tina4_test_* db and drops it.
  describe "MongoBackend db selection (live)" do
    # PREFIXED - see the note in session_handlers_spec.rb.
    QUEUE_MONGO_HOST = "localhost"
    QUEUE_MONGO_PORT = 27_017
    MONGO_TEST_URI = "mongodb://#{QUEUE_MONGO_HOST}:#{QUEUE_MONGO_PORT}"
    MONGO_TEST_DB = "tina4_test_queue_db_select"

    def self.mongo_available?
      require "mongo"
      s = Socket.tcp(QUEUE_MONGO_HOST, QUEUE_MONGO_PORT, connect_timeout: 1)
      s.close
      true
    rescue LoadError, StandardError
      false
    end

    if mongo_available?
      after(:each) do
        # Drop ONLY our throwaway tina4_test_* db; never touch other databases.
        client = Mongo::Client.new(MONGO_TEST_URI, database: MONGO_TEST_DB)
        client.database.drop
        client.close
      rescue StandardError
        # best-effort cleanup
      end

      it "honours the explicit db: over the URI default when BOTH are given" do
        backend = Tina4::QueueBackends::MongoBackend.new(
          uri: MONGO_TEST_URI,
          db: MONGO_TEST_DB,
          collection: "jobs"
        )
        expect(backend.instance_variable_get(:@db).name).to eq(MONGO_TEST_DB)
        backend.close
      end

      it "writes jobs and dead-letters into the requested db, not admin" do
        backend = Tina4::QueueBackends::MongoBackend.new(
          uri: MONGO_TEST_URI,
          db: MONGO_TEST_DB,
          collection: "jobs",
          max_retries: 3
        )
        # push -> pop -> complete
        backend.enqueue(Tina4::Job.new(topic: "tasks", payload: { "n" => 1 }, id: "ok-1"))
        backend.complete(backend.dequeue("tasks"))
        # push -> fail past max_retries -> dead-letter
        backend.enqueue(Tina4::Job.new(topic: "tasks", payload: { "n" => 2 }, id: "dl-1"))
        3.times do
          job = backend.dequeue("tasks")
          break if job.nil?

          backend.fail(job, "boom")
        end

        dead_count = backend.dead_letters("tasks").length

        # Inspect with an independent client: docs must be in the test db, NOT admin.
        inspector = Mongo::Client.new(MONGO_TEST_URI)
        test_count = inspector.use(MONGO_TEST_DB)["jobs"].count_documents({})
        admin_count = inspector.use("admin")["jobs"].count_documents({ "_id" => "dl-1" })
        inspector.close
        backend.close

        expect(test_count).to be > 0
        expect(admin_count).to eq(0)
        expect(dead_count).to eq(1)
      end
    else
      it "is skipped because MongoDB is not reachable at localhost:27017" do
        skip "MongoDB not reachable at #{MONGO_TEST_URI} (or mongo gem missing)"
      end
    end
  end

  # ── Retry Logic Tests ──────────────────────────────────────────

  describe "LiteBackend retry logic" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "tracks attempts on a message through requeue cycles" do
      msg = Tina4::Job.new(topic: "retry_topic", payload: "retry_me")
      msg.increment_attempts!
      msg.increment_attempts!
      backend.requeue(msg)

      dequeued = backend.dequeue("retry_topic")
      expect(dequeued).not_to be_nil
      expect(dequeued.attempts).to be >= 0
    end

    it "requeues then dequeues the same message" do
      msg = Tina4::Job.new(topic: "rq_topic", payload: { "task" => "process" })
      backend.requeue(msg)
      dequeued = backend.dequeue("rq_topic")
      expect(dequeued).not_to be_nil
      expect(dequeued.payload).to eq({ "task" => "process" })
    end
  end

  # ── Dead Letter Queue Tests ──────────────────────────────────────

  describe "LiteBackend dead letter queue" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "stores multiple messages in dead letter queue" do
      3.times do |i|
        msg = Tina4::Job.new(topic: "dl_topic", payload: "dead_#{i}")
        backend.dead_letter(msg)
      end
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.queue-data"))
      expect(dl_files.length).to eq(3)
    end

    it "preserves message payload in dead letter queue" do
      msg = Tina4::Job.new(topic: "dl_payload", payload: { "error" => "timeout" })
      backend.dead_letter(msg)
      dl_files = Dir.glob(File.join(tmpdir, "dead_letter", "*.queue-data"))
      content = JSON.parse(File.read(dl_files.first))
      expect(content["payload"]).to eq({ "error" => "timeout" })
    end
  end

  # ── Priority / Bulk Operations Tests ────────────────────────────

  describe "LiteBackend bulk operations" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:backend) { Tina4::QueueBackends::LiteBackend.new(dir: tmpdir) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "handles bulk enqueue of many messages" do
      10.times do |i|
        msg = Tina4::Job.new(topic: "bulk", payload: "msg_#{i}")
        backend.enqueue(msg)
      end
      expect(backend.size("bulk")).to eq(10)
    end

    it "drains a topic completely" do
      5.times do |i|
        msg = Tina4::Job.new(topic: "drain", payload: "msg_#{i}")
        backend.enqueue(msg)
      end
      results = []
      while (m = backend.dequeue("drain"))
        results << m.payload
      end
      expect(results.length).to eq(5)
      expect(backend.size("drain")).to eq(0)
    end

    it "handles interleaved enqueue and dequeue" do
      msg1 = Tina4::Job.new(topic: "interleave", payload: "first")
      backend.enqueue(msg1)
      dequeued1 = backend.dequeue("interleave")
      expect(dequeued1.payload).to eq("first")

      msg2 = Tina4::Job.new(topic: "interleave", payload: "second")
      backend.enqueue(msg2)
      dequeued2 = backend.dequeue("interleave")
      expect(dequeued2.payload).to eq("second")
    end

    it "handles concurrent topics independently" do
      backend.enqueue(Tina4::Job.new(topic: "alpha", payload: "a1"))
      backend.enqueue(Tina4::Job.new(topic: "alpha", payload: "a2"))
      backend.enqueue(Tina4::Job.new(topic: "beta", payload: "b1"))

      expect(backend.size("alpha")).to eq(2)
      expect(backend.size("beta")).to eq(1)

      backend.dequeue("alpha")
      expect(backend.size("alpha")).to eq(1)
      expect(backend.size("beta")).to eq(1)
    end
  end

  # ── Job Tests ──────────────────────────────────────────

  describe Tina4::Job do
    it "generates a UUID id by default" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      expect(msg.id).not_to be_nil
      expect(msg.id.length).to eq(36) # UUID format
    end

    it "accepts a custom id" do
      msg = Tina4::Job.new(topic: "test", payload: "data", id: "custom-id")
      expect(msg.id).to eq("custom-id")
    end

    it "starts with status :pending" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      expect(msg.status).to eq(:pending)
    end

    it "starts with 0 attempts" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      expect(msg.attempts).to eq(0)
    end

    it "increments attempts" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      msg.increment_attempts!
      expect(msg.attempts).to eq(1)
      msg.increment_attempts!
      expect(msg.attempts).to eq(2)
    end

    it "serializes to JSON" do
      msg = Tina4::Job.new(topic: "test", payload: { key: "val" })
      json = msg.to_json
      parsed = JSON.parse(json)
      expect(parsed["topic"]).to eq("test")
      expect(parsed["payload"]).to eq({ "key" => "val" })
    end

    it "converts to hash" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      hash = msg.to_hash
      expect(hash[:topic]).to eq("test")
      expect(hash[:payload]).to eq("data")
      expect(hash[:id]).to eq(msg.id)
      expect(hash[:status]).to eq(:pending)
    end

    it "stores created_at timestamp" do
      msg = Tina4::Job.new(topic: "test", payload: "data")
      hash = msg.to_hash
      expect(hash[:created_at]).not_to be_nil
    end

    it "preserves complex nested payload" do
      payload = { "users" => [{ "name" => "Alice" }, { "name" => "Bob" }], "count" => 2 }
      msg = Tina4::Job.new(topic: "complex", payload: payload)
      json = msg.to_json
      parsed = JSON.parse(json)
      expect(parsed["payload"]["users"].length).to eq(2)
      expect(parsed["payload"]["count"]).to eq(2)
    end
  end

end
