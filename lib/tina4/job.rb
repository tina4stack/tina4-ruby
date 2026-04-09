# frozen_string_literal: true
require "json"
require "securerandom"

module Tina4
  class Job
    attr_reader :id, :topic, :payload, :created_at, :attempts, :priority, :available_at
    attr_accessor :status

    def initialize(topic:, payload:, id: nil, priority: 0, available_at: nil, attempts: 0, queue: nil)
      @id = id || SecureRandom.uuid
      @topic = topic
      @payload = payload
      @created_at = Time.now
      @attempts = attempts
      @priority = priority
      @available_at = available_at
      @status = :pending
      @queue = queue
    end

    # Re-queue this message with incremented attempts.
    # Uses the stored queue reference (set at construction time).
    # Accepts an optional queue: keyword for backwards compatibility.
    def retry(delay_seconds: 0, queue: nil)
      q = queue || @queue
      raise ArgumentError, "No queue reference — pass queue: or set at construction" unless q

      @attempts += 1
      @status = :pending
      @available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
      q.backend.enqueue(self)
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
        created_at: @created_at.iso8601,
        attempts: @attempts,
        status: @status,
        priority: @priority
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

    # Mark this job as completed.
    def complete
      @status = :completed
    end

    # Mark this job as failed with a reason.
    def fail(reason = "")
      @status = :failed
      @error = reason
      @attempts += 1
    end

    # Reject this job with a reason. Alias for fail().
    def reject(reason = "")
      fail(reason)
    end

    attr_reader :error
  end
end
