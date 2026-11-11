# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "json"
require_relative "../parse_json"
require_relative "republish_retry_policy"

module Tina4
  module QueueBackends
    class KafkaBackend
      # Shared at-least-once fail() (ADR-0022): re-publish carrying the new
      # attempt count, dead-letter at the limit, ack last. See RabbitmqBackend.
      include RepublishRetryPolicy

      def initialize(options = {})
        require "rdkafka"
        @brokers = options[:brokers] || "localhost:9092"
        @group_id = options[:group_id] || "tina4_consumer_group"
        @max_retries = options[:max_retries] || 3

        security = self.class._security_config
        # Kept so dead_letters() can build a short-lived READER consumer with
        # its own group id, which reads the dead-letter topic from the start
        # without disturbing the main subscription or committing offsets.
        @security = security

        producer_config = {
          "bootstrap.servers" => @brokers
        }.merge(security)
        @producer = Rdkafka::Config.new(producer_config).producer

        consumer_config = {
          "bootstrap.servers" => @brokers,
          "group.id" => @group_id,
          "auto.offset.reset" => self.class.offset_reset,
          "enable.auto.commit" => "false"
        }.merge(security)
        @consumer = Rdkafka::Config.new(consumer_config).consumer
        @subscribed_topics = []
        # Records polled but not yet acknowledged, keyed by the id the Queue
        # hands back to acknowledge(), valued by the rdkafka message (its
        # topic/partition/offset). acknowledge() commits exactly THAT record's
        # offset, never a single "last message" slot (ADR-0022 decision 3).
        @in_flight = {}
      rescue LoadError
        raise "Kafka backend requires the 'rdkafka' gem. Install with: gem install rdkafka"
      end

      # Build SSL/SASL client config from env (for a TLS broker/proxy).
      #
      # Mirrors tina4_python KafkaConnector._security_config: each setting is
      # read from the Tina4-namespaced env var first (TINA4_KAFKA_<NAME>) and
      # falls back to the bare librdkafka-convention name (KAFKA_<NAME>) that
      # many Kafka deployments already set. Honours security.protocol (e.g. SSL,
      # SASL_SSL), ssl.ca.location, and optional SASL (mechanism / username /
      # password). Unset keys are omitted, leaving librdkafka's PLAINTEXT default.
      # Queue propagates its own configuration onto the backend after construction.
      attr_accessor :max_retries

      def self._security_config
        # rdkafka key -> env suffix (read as TINA4_KAFKA_<suffix>, then KAFKA_<suffix>)
        mapping = {
          "security.protocol" => "SECURITY_PROTOCOL",
          "ssl.ca.location" => "SSL_CA_LOCATION",
          "sasl.mechanism" => "SASL_MECHANISM",
          "sasl.username" => "SASL_USERNAME",
          "sasl.password" => "SASL_PASSWORD"
        }
        config = {}
        mapping.each do |rdk, suffix|
          value = env_value("TINA4_KAFKA_#{suffix}") || env_value("KAFKA_#{suffix}")
          config[rdk] = value if value
        end
        config
      end

      # Resolve the consumer's auto.offset.reset policy from the environment.
      #
      # Where a NEW consumer group (one with no committed offset) starts reading:
      # "earliest" (the default, unchanged) replays the retained backlog;
      # "latest" skips it. Read from the Tina4-namespaced env var first
      # (TINA4_KAFKA_AUTO_OFFSET_RESET), then the bare librdkafka-convention name
      # (KAFKA_AUTO_OFFSET_RESET) — the same precedence the TLS/SASL keys use. A
      # blank value falls through to the default (tina4-ruby#263). rdkafka honours
      # it directly, so "latest" takes real effect on the consume path.
      #
      # Mirrors tina4_python/queue_backends/kafka_backend.py::_offset_reset.
      def self.offset_reset
        env_value("TINA4_KAFKA_AUTO_OFFSET_RESET") ||
          env_value("KAFKA_AUTO_OFFSET_RESET") ||
          "earliest"
      end

      # Read an env var, treating empty/blank values as unset (parity with
      # Python's `os.environ.get(...) or ...` truthiness).
      def self.env_value(name)
        value = ENV[name]
        return nil if value.nil? || value.empty?

        value
      end
      private_class_method :env_value

      def enqueue(message, raw: false)
        if message.priority.to_i > 0
          raise NotImplementedError,
                "The kafka queue backend cannot honour push(priority): Kafka has no " \
                "priority concept at all - a consumer reads a partition in offset " \
                "order. Use the file or mongodb backend for prioritised jobs."
        end

        if message.available_at
          raise NotImplementedError,
                "The kafka queue backend cannot honour push(delay_seconds): Kafka " \
                "has no per-message delay at all. A consumer reads a partition in " \
                "offset order, so a delayed record would stall every record behind " \
                "it. Use the file or mongodb backend for delayed jobs, or schedule " \
                "the push itself."
        end

        # raw (tina4-ruby#264): produce the bare payload with NO Tina4 envelope
        # (the full Job hash) so a non-Tina4 consumer reads the schema it expects.
        # The id rides as the record KEY only (for partitioning), never in the value.
        payload = raw ? JSON.generate(message.payload) : message.to_json

        @producer.produce(
          topic: message.topic,
          payload: payload,
          key: message.id
        ).wait
      end

      def dequeue(topic)
        first = !@subscribed_topics.include?(topic)
        if first
          @consumer.subscribe(topic)
          @subscribed_topics << topic
        end

        # The first poll after subscribing must drive the consumer-group join +
        # partition assignment, which takes several seconds on a cold broker.
        # Until partitions are assigned, poll returns nil even when the topic
        # already has messages -- so a single poll made dequeue return nil right
        # after enqueue. Poll in a bounded loop on first subscribe (deadline
        # TINA4_KAFKA_ASSIGN_TIMEOUT, default 15s); steady state stays one ~1s poll.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   (first ? (ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"] || "15").to_f : 1.0)
        msg = poll_past_tombstones(deadline)
        return nil unless msg

        job = job_from_message(topic, msg)
        return nil unless job

        @in_flight[job.id.to_s] = msg
        job
      rescue Rdkafka::RdkafkaError
        nil
      end

      # Poll until a record with a value arrives or the deadline passes.
      #
      # A tombstone carries no job: skip it and poll on. Returning nil at the
      # first one read as an empty queue, so a single-pass drain
      # (consume(poll_interval: 0)) stopped at the tombstone. The deadline holds
      # while skipping too: a steady stream of tombstones must not hold dequeue
      # past it. Nothing is committed here: acknowledging the next record commits
      # past the skipped tombstones, as before.
      def poll_past_tombstones(deadline)
        loop do
          candidate = @consumer.poll(500)
          return candidate if candidate && !candidate.payload.nil?
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
      end

      # Build a Job from a polled record, or nil for a record that carries no job.
      #
      # A null-value record is a tombstone / delete marker: Debezium emits these on
      # deletes and log-compacted topics use them as delete markers, so they are
      # normal on Kafka. rdkafka hands back a nil payload for one; return nil (skip
      # it) so dequeue advances past it. Before this guard, JSON.parse(nil) raised a
      # TypeError that dequeue's `rescue Rdkafka::RdkafkaError` did NOT catch, so the
      # tombstone was a poison pill that killed the consumer on every restart
      # (tina4-python#303, same crash in the rdkafka path).
      #
      # A record carrying a "payload" key is a Tina4 envelope: keep its own id
      # (falling back to the coordinate) and carry attempts/error back so a
      # redelivery does not reset the count and re-produce a poison record forever.
      # A record WITHOUT one is externally produced (Debezium/CDC and friends, no
      # envelope, no id -- tina4#274): its whole value IS the payload, and the
      # coordinate becomes its id. Either way the job gets the id acknowledge()
      # maps back to this record's offset.
      def job_from_message(topic, msg)
        return nil if msg.payload.nil?

        data = Tina4.parse_json(msg.payload)
        coordinate = "#{topic}:#{msg.partition}:#{msg.offset}"
        if data.is_a?(Hash) && data.key?("payload")
          id = data["id"].to_s.empty? ? coordinate : data["id"]
          Tina4::Job.new(
            topic: topic, payload: data["payload"], id: id,
            attempts: data["attempts"] || 0, error: data["error"]
          )
        else
          Tina4::Job.new(topic: topic, payload: data, id: coordinate, attempts: 0)
        end
      end

      # Kafka has no queue depth: a log is a sequence of offsets, not a queue,
      # and computing a "remaining" count means an admin round-trip per call.
      # ADR-0022 decision 5 records 0 as the documented answer, which Python and
      # PHP already return. Ruby had no size method at all, so queue.size raised
      # NoMethodError on kafka - a method that does not resolve at all, which is
      # what invariant 1 forbids.
      def size(_topic)
        0
      end

      # Commit the offset JUST PAST the acknowledged record so the group never
      # re-reads it, even across a restart (ADR-0022 decisions 2 + 4). The offset
      # is committed for the specific record dequeue() tracked against this job's
      # id -- NOT a bare @consumer.commit of the whole polled position, which
      # would commit past records still in flight when jobs are completed out of
      # order (decision 3). A job never dequeued (or already acked) is a no-op.
      def acknowledge(message)
        msg = @in_flight.delete(message.id.to_s)
        return unless msg

        tpl = Rdkafka::Consumer::TopicPartitionList.new
        tpl.add_topic_and_partitions_with_offsets(msg.topic, msg.partition => msg.offset + 1)
        @consumer.commit(tpl, false)
      end

      def requeue(message)
        enqueue(message)
      end

      def dead_letter(message)
        # attempts and error MUST ride along, else every Kafka dead letter reads
        # back as attempts=0 with no reason while file/mongodb report the real
        # values.
        dead_msg = Tina4::Job.new(
          topic: "#{message.topic}.dead_letter",
          payload: message.payload,
          id: message.id,
          attempts: message.attempts,
          error: message.error
        )
        enqueue(dead_msg)
      end

      # Terminal ack. Job#complete calls backend.complete, and this backend only
      # had acknowledge() - so job.complete was a silent no-op on kafka and the
      # consumer-group offset was never committed, making the broker redeliver
      # every completed record.
      def complete(message)
        acknowledge(message)
      end

      # fail() comes from RepublishRetryPolicy (re-produce carrying the new
      # count, dead-letter at the limit, commit the offset LAST). Kafka's
      # +complete+ is +acknowledge+, so the terminal ack commits the offset.

      def retry(job, delay_seconds: 0)
        if delay_seconds.to_f > 0
          raise NotImplementedError,
                "The kafka queue backend cannot honour retry(delay_seconds): " \
                "Kafka has no per-message delay, for the same reason " \
                "push(delay_seconds) is refused - a consumer reads a partition " \
                "in offset order, so a delayed record stalls every record behind " \
                "it. Re-producing immediately while silently dropping the delay " \
                "would run the job far sooner than asked. Use the file or mongodb " \
                "backend for delayed retries."
        end

        job.attempts += 1
        job.error = nil
        enqueue(job)
        acknowledge(job)
        true
      end

      # Dead-lettered jobs, read back from the <topic>.dead_letter topic this
      # backend produces to itself. Kafka's log is not queryable by job state,
      # but it IS readable from the beginning - so this ANSWERS rather than
      # refusing, and a dead-letter handler written against the file backend
      # finds the same jobs here (invariant 3).
      #
      # Uses a short-lived consumer with a UNIQUE group id and never commits, so
      # it always reads from the start and a read never consumes. Reading with
      # the main consumer would move its offsets and steal the subscription.
      def dead_letters(topic, max_retries: 3)
        name = "#{topic}.dead_letter"
        reader = Rdkafka::Config.new({
          "bootstrap.servers" => @brokers,
          "group.id" => "#{@group_id}.reader.#{Process.pid}.#{object_id}",
          "auto.offset.reset" => "earliest",
          "enable.auto.commit" => "false"
        }.merge(@security)).consumer
        out = []
        begin
          reader.subscribe(name)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                     (ENV["TINA4_KAFKA_ASSIGN_TIMEOUT"] || "15").to_f
          loop do
            msg = reader.poll(500)
            if msg
              # Skip a tombstone / null-value record the same way dequeue does, so
              # a null-value dead-letter never crashes the reader on JSON.parse(nil)
              # (tina4-python#303).
              next if msg.payload.nil?

              data = Tina4.parse_json(msg.payload)
              data["status"] = "dead"
              out << data
              next
            end
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          end
        rescue Rdkafka::RdkafkaError
          # An absent topic means nothing has been dead-lettered yet.
          nil
        ensure
          reader.close
        end
        out
      end

      # Reject a job permanently — dead-letter it NOW, no retry (ADR-0023).
      def reject(job, reason = "")
        job.attempts = [job.attempts + 1, @max_retries].max
        job.error = reason
        dead_letter(job)
        acknowledge(job)
      end

      def failed(_topic, max_retries: 3)
        raise NotImplementedError,
              "The kafka queue backend cannot answer failed(): a job that failed " \
              "but is still retryable is re-produced to the main topic, and a log " \
              "cannot be queried by job state, so it cannot be told apart from a " \
              "normal pending record. Returning an empty list would claim nothing " \
              "has failed. Use dead_letters() for exhausted jobs, or the file or " \
              "mongodb backend to enumerate retryable failures."
      end

      def retry_failed(_topic, max_retries: 3)
        raise NotImplementedError,
              "The kafka queue backend cannot perform retry_failed(): it must " \
              "first enumerate the failed-but-retryable jobs, which a log cannot " \
              "be queried for. Returning 0 would claim nothing needed retrying. " \
              "Use retry(job_id) with an id you already hold, or the file or " \
              "mongodb backend."
      end

      def retry_job(_topic, job_id: nil, delay_seconds: 0)
        raise NotImplementedError,
              "The kafka queue backend cannot perform retry(job_id): a log cannot " \
              "retract a record, so the dead letter would stay on the " \
              ".dead_letter topic and be revived again on the next call, " \
              "duplicating the job. Re-produce it yourself with push() if that " \
              "is what you want, or use the file or mongodb backend."
      end

      def purge(_topic, _status)
        raise NotImplementedError,
              "The kafka queue backend cannot perform purge(): a log cannot " \
              "delete records by status - retention is time- and size-based and " \
              "set on the topic. Returning 0 would claim nothing needed purging. " \
              "Configure topic retention, or use the file or mongodb backend."
      end

      def clear(_topic)
        raise NotImplementedError,
              "The kafka queue backend cannot perform clear(): a log cannot " \
              "delete records on demand - retention is time- and size-based and " \
              "set on the topic. Returning 0 would claim the queue was emptied " \
              "when it was not. Configure topic retention, or use the file or " \
              "mongodb backend."
      end

      # Close the rdkafka producer and consumer (leaving the consumer group).
      #
      # IDEMPOTENT by construction: the handles are dropped in an ensure, so a
      # second close finds nothing and returns. Before 3.13.95 they were left
      # set, and rdkafka raises on closing an already-closed consumer - so a
      # shutdown path that ran twice crashed on the second pass.
      def close
        @producer&.close
        @consumer&.close
      ensure
        @producer = nil
        @consumer = nil
        @subscribed_topics = []
      end
    end
  end
end
