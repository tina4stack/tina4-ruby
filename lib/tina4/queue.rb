# frozen_string_literal: true
require "json"
require "securerandom"
require "uri"
require_relative "job"

module Tina4
  # Queue — unified wrapper for queue management operations.
  # Auto-detects backend from TINA4_QUEUE_BACKEND env var.
  #
  # Usage:
  #   # Auto-detect from env (default: lite/file backend)
  #   queue = Queue.new(topic: "tasks")
  #
  #   # Explicit backend
  #   queue = Queue.new(topic: "tasks", backend: :rabbitmq)
  #
  #   # Or pass a backend instance directly (legacy)
  #   queue = Queue.new(topic: "tasks", backend: my_backend)
  class Queue
    attr_reader :topic, :max_retries, :retry_backoff, :visibility_timeout

    def initialize(topic:, backend: nil, max_retries: 3, retry_backoff: 0, visibility_timeout: nil)
      @topic = topic
      @max_retries = max_retries
      # Seconds to wait before a failed job is re-attempted (lite backend).
      # Default 0 = retry on the very next pop/consume iteration.
      @retry_backoff = retry_backoff
      # Reservation/visibility timeout (seconds). A popped job is reserved for
      # this long; if the consumer dies before complete()/fail() the next pop()
      # reclaims it (at-least-once delivery). Falls back to
      # TINA4_QUEUE_VISIBILITY_TIMEOUT, else 300 (5 min). <= 0 disables reclaim.
      # RabbitMQ/Kafka ignore it — the broker owns redelivery.
      @visibility_timeout =
        visibility_timeout.nil? ? self.class.default_visibility_timeout : visibility_timeout.to_f
      @backend = resolve_backend_arg(backend)
    end

    # ── The file store's layout: the ONE answer to "where do the queue files
    # live". ─────────────────────────────────────────────────────────────────
    #
    # Everything that touches the store asks here — the lite backend that
    # writes it, and every dev-admin queue handler that reads it. It exists
    # because they used to disagree: the dev admin scanned a hardcoded
    # Dir.pwd/data/queue while the backend wrote to Dir.pwd/.queue and read
    # TINA4_QUEUE_PATH nowhere, so the panel counted one directory and listed
    # another, and its topic list could never name a real topic. Re-deriving
    # any of this anywhere else re-opens that defect.
    #
    # The layout is the canonical cross-framework one, identical to the Python
    # master, PHP and Node:
    #
    #   <base>/<topic>/*.queue-data            pending
    #   <base>/<topic>/reserved/*.queue-data   reserved (in flight)
    #   <base>/dead_letter/*.queue-data        dead-lettered, tagged by topic

    # Canonical job-file extension in all four frameworks.
    JOB_EXTENSION = ".queue-data"

    # Dead letters share one directory and carry their topic in the record.
    DEAD_LETTER_DIRNAME = "dead_letter"

    # Root of the file store: TINA4_QUEUE_PATH, else "data/queue" relative to
    # the working directory.
    #
    # Absolute, so every caller gets the same directory rather than one that
    # depends on when it was resolved. A blank value is treated as unset (the
    # same normalisation TINA4_SESSION_BACKEND applies) — File.join("", topic)
    # would otherwise silently address /<topic>, at the filesystem root.
    def self.base_path
      configured = ENV["TINA4_QUEUE_PATH"].to_s.strip
      File.expand_path(configured.empty? ? "data/queue" : configured)
    end

    # The single path segment a topic maps to.
    #
    # Sanitised HERE, in the one place that resolves it, so no caller can build
    # a store path out of an unsanitised topic name — the dev-admin queue panel
    # takes its topic straight off a query string, where "../.." would
    # otherwise walk out of the store.
    def self.topic_dirname(topic)
      topic.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
    end

    # Directory holding +topic+'s pending jobs.
    def self.topic_path(topic)
      File.join(base_path, topic_dirname(topic))
    end

    # Every job file in +dir+, name-sorted so two readers of the same directory
    # always see the same order.
    def self.job_files(dir)
      Dir.glob(File.join(dir, "*#{JOB_EXTENSION}")).sort
    end

    def self.job_file(dir, id)
      File.join(dir, "#{id}#{JOB_EXTENSION}")
    end

    # Reservation/visibility timeout in seconds, from env (default 300 = 5 min).
    def self.default_visibility_timeout
      Float(ENV.fetch("TINA4_QUEUE_VISIBILITY_TIMEOUT", "300"))
    rescue ArgumentError, TypeError
      300.0
    end

    # Push a job onto the queue. Returns the Job.
    # priority: higher-priority messages are dequeued first (default 0).
    # delay_seconds: delay before the message becomes available (default 0).
    def push(payload, priority: 0, delay_seconds: 0)
      available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
      message = Job.new(topic: @topic, payload: payload, priority: priority, available_at: available_at, queue: self)
      @backend.enqueue(message)
      message
    end

    # Pop the next available job. Returns Job or nil.
    def pop # -> Job|None
      attach(@backend.dequeue(@topic))
    end

    # Pop up to count jobs at once. Returns a partial batch if fewer available.
    def pop_batch(count)
      jobs =
        if @backend.respond_to?(:dequeue_batch)
          @backend.dequeue_batch(@topic, count)
        else
          collected = []
          count.times do
            job = @backend.dequeue(@topic)
            break if job.nil?
            collected << job
          end
          collected
        end
      jobs.each { |job| attach(job) }
      jobs
    end

    # Clear all pending jobs from this queue's topic. Returns count removed.
    def clear # -> int
      # Was `return 0` - a SILENT no-op that looked exactly like an empty
      # queue. A backend that cannot clear says so, naming itself.
      unless @backend.respond_to?(:clear)
        raise NotImplementedError,
              "The #{@backend.class.name.split('::').last} queue backend cannot " \
              "perform clear(): it cannot remove jobs by topic. Use the file or " \
              "mongodb backend."
      end
      @backend.clear(@topic)
    end

    # Release the backend's connection and free its resources.
    #
    # A queue on RabbitMQ, Kafka or MongoDB holds a REAL client and socket.
    # Until 3.13.95 there was no way to hand it back: close existed on the
    # rabbitmq/mongo/kafka backends but was surfaced on NOTHING, and the lite
    # backend had none at all - so every `backend.close if respond_to?(:close)`
    # guard in the tree silently skipped the default backend. An app that built
    # a Queue per request leaked one client per request, invisibly, until the
    # broker refused new connections. Same class of leak as ADR-0025 corollary 4
    # (client-lifecycle-is-bounded).
    #
    # Safe on EVERY backend: the lite backend holds no connection and closes as
    # a documented no-op, so a TINA4_QUEUE_BACKEND change never turns a working
    # shutdown path into an error. Idempotent - each backend drops its handles
    # on the first call, so a second call finds nothing to close and returns.
    #
    # Treat the queue as spent afterwards and build a new one to keep working.
    def close
      @backend.close
    end

    # Get jobs that failed at least once but are still being retried
    # (0 < attempts < max_retries). These live in the pending queue under
    # the auto-retry lifecycle (fail() re-queues them with an incremented
    # attempts count and a retry_backoff delay) so pop() picks them up
    # again. They are NOT counted by size("failed") — that alias counts
    # the dead-letter store, matching dead_letters(). To include retryable-
    # failed jobs in a total, use size("pending"). Terminal failures are
    # returned by dead_letters().
    def failed # -> list[dict]
      refuse_operation!("failed()") unless @backend.respond_to?(:failed)
      @backend.failed(@topic, max_retries: @max_retries)
    end

    # Retry a specific failed job by ID, or all dead-letter jobs if no id given.
    # Returns true if re-queued.
    #
    # The no-arg branch is materialised by the backend (LiteBackend#retry_job
    # iterates every dead-letter file with .each, MongoBackend materialises
    # find(...).to_a before iterating) — no generator inside any() /
    # short-circuit reduce can silently leave dead letters behind (parity port
    # of PY-12-04, 3.13.105).
    def retry(job_id = nil, delay_seconds: 0) # -> bool
      refuse_operation!("retry()") unless @backend.respond_to?(:retry_job)
      @backend.retry_job(@topic, job_id: job_id, delay_seconds: delay_seconds)
    end

    # Get jobs that exceeded max_retries — terminal failures.
    #
    # Same set counted by size("failed") / size("dead") / size("dead_letter")
    # (three aliases for the dead-letter store). To LIST retryable-but-
    # attempted jobs (attempts > 0 AND attempts < max_retries) that are still
    # being auto-retried, use failed() — those live in the pending queue and
    # are NOT dead letters. Pass max_retries to override the queue's default.
    def dead_letters(max_retries: nil) # -> list[dict]
      refuse_operation!("dead_letters()") unless @backend.respond_to?(:dead_letters)
      @backend.dead_letters(@topic, max_retries: max_retries || @max_retries)
    end

    # Delete messages by status (completed, failed, dead).
    def purge(status, max_retries: nil) # -> int
      refuse_operation!("purge()") unless @backend.respond_to?(:purge)
      @backend.purge(@topic, status)
    end

    # Re-queue failed messages (under max_retries) back to pending.
    # Returns the number of jobs re-queued.
    def retry_failed(max_retries: nil) # -> int
      refuse_operation!("retry_failed()") unless @backend.respond_to?(:retry_failed)
      @backend.retry_failed(@topic, max_retries: max_retries || @max_retries)
    end

    # A backend that does not implement an operation must SAY SO, naming itself
    # and the operation (invariant 6).
    #
    # These five methods used to `return [] / false / 0 unless
    # @backend.respond_to?(...)`. That turned "this backend cannot do this" into
    # "nothing has failed" / "nothing needed retrying" / "nothing was purged" --
    # answers indistinguishable from a genuine empty success (ADR-0022
    # decision 7). It is the silent-no-op class this invariant exists to remove,
    # and it hid every missing broker method behind a plausible-looking result.
    def refuse_operation!(operation)
      name = @backend.class.name.to_s.split("::").last.sub(/Backend\z/, "").downcase
      raise NotImplementedError,
            "The #{name} queue backend cannot perform #{operation}: it does not " \
            "implement that operation. Returning an empty result would be " \
            "indistinguishable from a successful empty answer. Use the file or " \
            "mongodb backend, which implement the full failure lifecycle."
    end

    # Produce a message onto a topic. Convenience wrapper around push().
    def produce(topic, payload, priority: 0, delay_seconds: 0)
      available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
      message = Job.new(topic: topic, payload: payload, priority: priority, available_at: available_at, queue: self)
      @backend.enqueue(message)
      message
    end

    # Consume jobs from a topic using an Enumerator (yield pattern).
    #
    # Usage:
    #   queue.consume("emails") do |job|
    #     process(job)
    #   end
    #
    #   # Consume a specific job by ID:
    #   queue.consume("emails", id: "abc-123") do |job|
    #     process(job)
    #   end
    #
    #   # Or as an enumerator:
    #   queue.consume("emails").each { |job| process(job) }
    #
    # Consume jobs from a topic using a long-running generator.
    #
    # Polls the queue continuously. When empty, sleeps for poll_interval
    # seconds before polling again. No external while-loop or sleep needed.
    #
    #   queue.consume("emails") { |job| process(job) }
    #   queue.consume("emails", poll_interval: 5) { |job| process(job) }
    #   queue.consume("emails", id: "abc-123") { |job| process(job) }
    #
    def consume(topic = nil, id: nil, poll_interval: 1.0, iterations: 0, batch_size: 1, &block)
      topic ||= @topic

      if id
        # Single job by ID — no polling
        job = pop_by_id(topic, id)
        if job
          block_given? ? yield(job) : (return Enumerator.new { |y| y << job })
        end
        return block_given? ? nil : Enumerator.new { |_| }
      end

      # poll_interval=0 → single-pass drain (returns when empty)
      # poll_interval>0 → long-running poll (sleeps when empty, never returns)
      # iterations>0    → stop after consuming N jobs
      if block_given?
        consumed = 0
        if batch_size > 1
          loop do
            jobs = pop_batch(batch_size)
            if jobs.empty?
              break if poll_interval <= 0
              sleep(poll_interval)
              next
            end
            yield jobs
            consumed += jobs.length
            break if iterations > 0 && consumed >= iterations
          end
        else
          loop do
            job = attach(@backend.dequeue(topic))
            if job.nil?
              break if poll_interval <= 0
              sleep(poll_interval)
              next
            end
            yield job
            consumed += 1
            break if iterations > 0 && consumed >= iterations
          end
        end
      else
        Enumerator.new do |yielder|
          consumed = 0
          loop do
            job = attach(@backend.dequeue(topic))
            if job.nil?
              break if poll_interval <= 0
              sleep(poll_interval)
              next
            end
            yielder << job
            consumed += 1
            break if iterations > 0 && consumed >= iterations
          end
        end
      end
    end

    # Pop a specific job by ID from the queue. Searches the pending queue for
    # the given topic (defaults to this queue's topic). Returns the matching
    # Job (claimed/removed from the queue) or nil.
    def pop_by_id(topic = nil, id)
      # Was `return nil` - indistinguishable from "no such job".
      unless @backend.respond_to?(:find_by_id)
        raise NotImplementedError,
              "The #{@backend.class.name.split('::').last} queue backend cannot " \
              "perform pop_by_id(): it cannot address a single message by id. Use " \
              "the file or mongodb backend."
      end
      attach(@backend.find_by_id(topic || @topic, id))
    end

    # Count jobs by status.
    #
    # "pending" counts jobs waiting to be popped — INCLUDES retryable-but-
    # attempted ones, because they live in the pending queue under the
    # auto-retry lifecycle (see failed()).
    # "reserved" counts jobs a consumer has popped but not yet
    # completed/failed (in-flight against the visibility timeout).
    # "completed" counts jobs the consumer has finished successfully
    # (0 on the lite/file backend which deletes on complete; backends that
    # track completion expose completed_count).
    # "failed", "dead", "dead_letter" are ALIASES that all count the
    # dead-letter store — jobs whose attempts >= max_retries and that have
    # given up. Use dead_letters() to list them. Retryable-but-attempted
    # jobs are NOT counted by size("failed"); use failed() to list them or
    # size("pending") to include them in a total.
    def size(status: "pending")
      case status.to_s
      when "pending"
        @backend.size(@topic)
      when "reserved"
        @backend.respond_to?(:reserved_count) ? @backend.reserved_count(@topic) : 0
      when "failed", "dead"
        if @backend.respond_to?(:dead_letter_count)
          @backend.dead_letter_count(@topic)
        else
          0
        end
      when "completed"
        # Terminal-completed jobs. The lite/file backend deletes on complete
        # (no completed store) so this is 0; backends that track completion
        # expose #completed_count. Parity with the Python master's
        # size("completed") ("0 on the file backend") — never the pending count.
        @backend.respond_to?(:completed_count) ? @backend.completed_count(@topic) : 0
      else
        @backend.size(@topic)
      end
    end

    # Get the topic name this queue was constructed with.
    def get_topic
      @topic
    end

    # Consume all available jobs and pass each to handler, then stop.
    #
    # Simpler alternative to consume() for drain-and-exit use cases.
    #
    #   queue.process { |job| handle(job); job.complete }
    #   queue.process(topic: "emails", max_jobs: 10) { |job| ... }
    #
    def process(topic: nil, max_jobs: nil, batch_size: 1, &handler)
      raise ArgumentError, "block required" unless block_given?
      drain_topic = topic || @topic
      processed = 0
      loop do
        break if max_jobs && processed >= max_jobs
        if batch_size > 1
          remaining = max_jobs ? [batch_size, max_jobs - processed].min : batch_size
          jobs = @backend.respond_to?(:dequeue_batch) ?
                   @backend.dequeue_batch(drain_topic, remaining) :
                   (1..remaining).map { @backend.dequeue(drain_topic) }.compact
          break if jobs.empty?
          begin
            handler.call(jobs)
          rescue => e
            jobs.each { |job| job.fail(e.message) }
          end
          processed += jobs.length
        else
          job = @backend.dequeue(drain_topic)
          break if job.nil?
          begin
            handler.call(job)
          rescue => e
            job.fail(e.message)
          end
          processed += 1
        end
      end
    end

    # Get the underlying backend instance.
    def backend
      @backend
    end

    # Resolve the default backend from env vars.
    def self.resolve_backend(name = nil, max_retries: 3, retry_backoff: 0, visibility_timeout: nil)
      # Normalise BOTH sources, not just the env var. `.downcase.strip` used to
      # bind only to the ENV.fetch branch, so an explicit
      # Queue.new(backend: "FILE") fell through to the unknown-backend raise
      # while the identical spelling in TINA4_QUEUE_BACKEND resolved fine -
      # and while python, php and nodejs all accepted it. Python is master here.
      chosen = (name || ENV.fetch("TINA4_QUEUE_BACKEND", "file")).to_s.downcase.strip
      vt = visibility_timeout.nil? ? default_visibility_timeout : visibility_timeout

      case chosen.to_s
      when "lite", "file", "default"
        Tina4::QueueBackends::LiteBackend.new(
          max_retries: max_retries, retry_backoff: retry_backoff, visibility_timeout: vt
        )
      when "rabbitmq"
        # Broker manages visibility/redelivery (unacked messages requeue on
        # channel close) — the framework timeout is accepted but not used.
        # max_retries IS used: fail() counts attempts itself and dead-letters
        # past the limit. Without threading it through, the backend fell back to
        # its own default of 3, so Queue.new(max_retries: 2) gave a job THREE
        # attempts on rabbitmq and two on file — the dead-letter threshold
        # silently changed with the provider.
        config = resolve_rabbitmq_config
        config[:max_retries] = max_retries
        Tina4::QueueBackends::RabbitmqBackend.new(config)
      when "kafka"
        # Consumer-group offsets manage redelivery — framework timeout N/A.
        # max_retries threaded through for the same reason as rabbitmq.
        config = resolve_kafka_config
        config[:max_retries] = max_retries
        Tina4::QueueBackends::KafkaBackend.new(config)
      when "mongodb", "mongo"
        config = resolve_mongo_config
        config[:visibility_timeout] = vt
        config[:max_retries] = max_retries
        # Thread retry_backoff through so a failed/retried job's available_at is
        # reset to now (or now + retry_backoff) instead of being stranded for the
        # full visibility window (Bug B).
        config[:retry_backoff] = retry_backoff
        Tina4::QueueBackends::MongoBackend.new(config)
      else
        raise ArgumentError, "Unknown queue backend: #{chosen.inspect}. Use 'lite', 'rabbitmq', 'kafka', or 'mongodb'."
      end
    end

    private

    # Stamp the queue reference onto a popped job so job.fail / job.retry /
    # job.complete can reach the backend. Returns the job (or nil) unchanged.
    def attach(job)
      job.queue = self if job
      job
    end

    def resolve_backend_arg(backend)
      # If a backend instance is passed directly (legacy), use it. Best-effort
      # propagate the queue's retry policy if the instance exposes setters.
      if backend && !backend.is_a?(Symbol) && !backend.is_a?(String)
        backend.max_retries = @max_retries if backend.respond_to?(:max_retries=)
        backend.retry_backoff = @retry_backoff if backend.respond_to?(:retry_backoff=)
        backend.visibility_timeout = @visibility_timeout if backend.respond_to?(:visibility_timeout=)
        return backend
      end
      # If a symbol or string name is passed, resolve it
      Queue.resolve_backend(backend, max_retries: @max_retries, retry_backoff: @retry_backoff,
                                     visibility_timeout: @visibility_timeout)
    end

    def self.resolve_rabbitmq_config
      config = {}
      url = ENV["TINA4_QUEUE_URL"]
      if url
        config = parse_amqp_url(url)
      end
      config[:host] ||= ENV.fetch("TINA4_RABBITMQ_HOST", "localhost")
      config[:port] ||= (ENV["TINA4_RABBITMQ_PORT"] || 5672).to_i
      config[:username] ||= ENV.fetch("TINA4_RABBITMQ_USERNAME", "guest")
      config[:password] ||= ENV.fetch("TINA4_RABBITMQ_PASSWORD", "guest")
      config[:vhost] ||= ENV.fetch("TINA4_RABBITMQ_VHOST", "/")
      config
    end

    def self.resolve_kafka_config
      config = {}
      url = ENV["TINA4_QUEUE_URL"]
      if url
        config[:brokers] = url.sub("kafka://", "")
      end
      brokers = ENV["TINA4_KAFKA_BROKERS"]
      config[:brokers] = brokers if brokers
      config[:brokers] ||= "localhost:9092"
      config[:group_id] = ENV.fetch("TINA4_KAFKA_GROUP_ID", "tina4_consumer_group")
      config
    end

    def self.resolve_mongo_config
      config = {}
      uri = ENV["TINA4_MONGO_URI"]
      config[:uri] = uri if uri
      config[:host] = ENV.fetch("TINA4_MONGO_HOST", "localhost") unless uri
      config[:port] = (ENV["TINA4_MONGO_PORT"] || 27017).to_i unless uri
      username = ENV["TINA4_MONGO_USERNAME"]
      password = ENV["TINA4_MONGO_PASSWORD"]
      config[:username] = username if username
      config[:password] = password if password
      config[:db] = ENV.fetch("TINA4_MONGO_DB", "tina4")
      config[:collection] = ENV.fetch("TINA4_MONGO_COLLECTION", "tina4_queue")
      config
    end

    def self.parse_amqp_url(url)
      config = {}
      url = url.sub("amqp://", "").sub("amqps://", "")

      if url.include?("@")
        creds, rest = url.split("@", 2)
        if creds.include?(":")
          config[:username], config[:password] = creds.split(":", 2)
        else
          config[:username] = creds
        end
      else
        rest = url
      end

      if rest.include?("/")
        hostport, vhost = rest.split("/", 2)
        # THE VHOST IS THE PATH SEGMENT, URL-DECODED, WITH NO LEADING SLASH
        # (RabbitMQ URI spec). This used to prepend "/", so
        # amqp://guest:guest@rabbit:5672/orders asked for a vhost literally
        # named "/orders". No broker has that one - it is named "orders" - so
        # every publish failed against a named vhost, which is the ordinary
        # multi-tenant setup and the form every RabbitMQ tutorial shows.
        # MEASURED against a real broker: 4 of 5 URL shapes resolved to the
        # wrong name, and the only one that worked carried no vhost at all,
        # which is why four green suites never noticed.
        #
        # Decoding matters for the same reason: the DEFAULT vhost is named "/",
        # which cannot appear literally in a path, so the spec spells it "%2f".
        #
        # DELIBERATE DEVIATION, one shape: the spec reads a bare trailing slash
        # as the EMPTY vhost name. Tina4 treats it as "not specified" and keeps
        # the caller's default - nobody writes a trailing slash intending a
        # vhost named "", and reading it literally would break a working
        # "amqp://host:5672/" for no benefit.
        config[:vhost] = URI::DEFAULT_PARSER.unescape(vhost) if vhost && !vhost.empty?
      else
        hostport = rest
      end

      if hostport.include?(":")
        host, port = hostport.split(":", 2)
        config[:host] = host
        config[:port] = port.to_i
      elsif hostport && !hostport.empty?
        config[:host] = hostport
      end

      config
    end
  end
end
