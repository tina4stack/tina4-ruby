# frozen_string_literal: true
require "json"
require "securerandom"

module Tina4
  class Job
    attr_reader :id, :topic, :payload, :created_at, :attempts, :priority, :available_at
    attr_accessor :status

    def initialize(topic:, payload:, id: nil, priority: 0, available_at: nil, attempts: 0)
      @id = id || SecureRandom.uuid
      @topic = topic
      @payload = payload
      @created_at = Time.now
      @attempts = attempts
      @priority = priority
      @available_at = available_at
      @status = :pending
    end

    # Re-queue this message with incremented attempts.
    # Delegates to the queue's backend via the queue reference.
    def retry(queue:, delay_seconds: 0)
      @attempts += 1
      @status = :pending
      @available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
      queue.backend.enqueue(self)
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
