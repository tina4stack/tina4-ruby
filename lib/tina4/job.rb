# frozen_string_literal: true
require "json"
require "securerandom"

module Tina4
  class Job
    attr_reader :id, :topic, :payload, :created_at, :priority, :available_at
    attr_accessor :status, :attempts, :error, :queue

    def initialize(topic:, payload:, id: nil, priority: 0, available_at: nil,
                   attempts: 0, created_at: nil, error: nil, queue: nil)
      @id = id || SecureRandom.uuid
      @topic = topic
      @payload = payload
      @created_at = created_at || Time.now
      @attempts = attempts
      @priority = priority
      @available_at = available_at
      # Populated by fail()/reject() — why the job last died. Surfaces in
      # dead_letters() so consumers can see the failure reason without
      # trawling logs.
      @error = error
      @status = :pending
      @queue = queue
    end

    # Re-queue this message with optional delay. Always re-enqueues regardless
    # of the retry limit — this is a manual override, distinct from the
    # automatic fail() path. Increments attempts.
    def retry(delay_seconds: 0)
      q = @queue
      raise ArgumentError, "No queue reference — set at construction" unless q

      if q.backend.respond_to?(:retry)
        q.backend.retry(self, delay_seconds: delay_seconds)
      else
        @attempts += 1
        @status = :pending
        @available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
        q.backend.enqueue(self)
      end
      self
    end

    def to_array
      [@id, @topic, @payload, @priority, @attempts]
    end

    def to_hash
      h = {
        id: @id,
        topic: @topic,
        payload: @payload,
        created_at: @created_at.iso8601(6),
        attempts: @attempts,
        status: @status,
        priority: @priority,
        error: @error
      }
      h[:available_at] = @available_at.iso8601 if @available_at
      h
    end

    def to_json(*_args)
      JSON.generate(to_hash)
    end

    def increment_attempts!
      @attempts += 1
    end

    # Mark this job as completed. Terminal — the job is done and removed.
    def complete
      @status = :completed
      @queue.backend.complete(self) if @queue && @queue.backend.respond_to?(:complete)
      self
    end

    # Record a failed attempt.
    #
    # Increments +attempts+ and stores +reason+. If the job still has retries
    # left (+attempts < max_retries+) it is automatically re-enqueued to the
    # pending queue, so the next pop/consume picks it up again (after the
    # queue's retry_backoff delay, if any). Once it has been attempted
    # +max_retries+ times it is moved to the dead-letter store, where
    # queue.dead_letters returns it. No manual retry_failed is required.
    def fail(reason = "")
      @error = reason
      if @queue && @queue.backend.respond_to?(:fail)
        @queue.backend.fail(self, reason)
        @status = @attempts >= @queue.max_retries ? :dead : :pending
      else
        # No backend reference — degrade to in-memory bookkeeping only.
        @attempts += 1
        @status = :failed
      end
      self
    end

    # Reject this job with a reason. Alias for fail().
    def reject(reason = "")
      fail(reason)
    end
  end
end
