# frozen_string_literal: true
require "json"
require "fileutils"
require "time"

module Tina4
  module QueueBackends
    # File-based queue backend — JSON files on disk. Zero dependencies.
    #
    # Each job is stored as a separate .json file under <dir>/<topic>/.
    # Dead-lettered jobs (those that exhausted their retries) live under the
    # shared <dir>/dead_letter/ directory, tagged with their topic.
    #
    # Dequeue policy: highest priority first, ties broken oldest-first by the
    # stored created_at (ISO-8601, so lexicographic == chronological). The
    # file name is NOT the ordering key — the stored priority/created_at are.
    class LiteBackend
      # Retry policy — settable so a Queue can propagate its own max_retries /
      # retry_backoff onto a backend instance passed directly (legacy path).
      attr_accessor :max_retries, :retry_backoff

      def initialize(options = {})
        @dir = options[:dir] || File.join(Dir.pwd, ".queue")
        @dead_letter_dir = File.join(@dir, "dead_letter")
        # Retry policy. Mirrors the Python lite backend: a failed job is
        # re-enqueued while attempts < max_retries, then dead-lettered.
        @max_retries = options[:max_retries] || 3
        # Seconds to delay a job's next attempt when fail() re-enqueues it.
        # 0 (default) = retry on the very next pop/consume iteration.
        @retry_backoff = options[:retry_backoff] || 0
        FileUtils.mkdir_p(@dir)
        FileUtils.mkdir_p(@dead_letter_dir)
        @mutex = Mutex.new
      end

      def enqueue(message)
        @mutex.synchronize do
          topic_dir = topic_path(message.topic)
          FileUtils.mkdir_p(topic_dir)
          path = File.join(topic_dir, "#{message.id}.json")
          File.write(path, message.to_json)
        end
      end

      def dequeue(topic)
        @mutex.synchronize do
          candidate = available_candidates(topic).first
          return nil unless candidate

          File.delete(candidate[:file])
          job_from_data(candidate[:data], topic)
        end
      end

      def dequeue_batch(topic, count)
        @mutex.synchronize do
          chosen = available_candidates(topic).first(count)
          chosen.map do |c|
            File.delete(c[:file])
            job_from_data(c[:data], topic)
          end
        end
      end

      # Find a specific pending job by id, claim it (delete the file) and
      # return it. Returns nil when no pending job with that id exists.
      def find_by_id(topic, id)
        @mutex.synchronize do
          dir = topic_path(topic)
          return nil unless Dir.exist?(dir)

          target = id.to_s
          Dir.glob(File.join(dir, "*.json")).each do |f|
            data = JSON.parse(File.read(f))
            next unless data["id"].to_s == target

            File.delete(f)
            return job_from_data(data, topic)
          rescue JSON::ParserError
            next
          end
          nil
        end
      end

      def acknowledge(message)
        # File already deleted on dequeue — nothing to do.
      end

      def complete(message)
        # Job file was already deleted on dequeue. complete() is terminal:
        # the job is done and gone.
      end

      def requeue(message)
        enqueue(message)
      end

      # Record a failed attempt. Increments attempts and stores the error.
      # While attempts < max_retries the job is re-enqueued to pending (after
      # the configured retry_backoff). Once attempts >= max_retries it is moved
      # to the dead-letter store.
      def fail(job, error = "")
        job.attempts += 1
        job.error = error
        if job.attempts < @max_retries
          requeue_job(job, delay_seconds: @retry_backoff, error: error)
        else
          move_to_dead_letter(job, error)
        end
      end

      # Explicit re-queue requested by the caller (job.retry()). Always
      # re-enqueues regardless of the retry limit — a manual override, distinct
      # from the automatic fail() path. Increments attempts, clears the error.
      def retry(job, delay_seconds: 0)
        job.attempts += 1
        requeue_job(job, delay_seconds: delay_seconds, error: nil)
      end

      def dead_letter(message)
        path = File.join(@dead_letter_dir, "#{message.id}.json")
        data = message.to_hash
        data[:status] = "dead"
        File.write(path, JSON.generate(data))
      end

      def size(topic)
        dir = topic_path(topic)
        return 0 unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "*.json")).length
      end

      # Count dead-letter / failed messages for a topic.
      def dead_letter_count(topic)
        return 0 unless Dir.exist?(@dead_letter_dir)

        count = 0
        Dir.glob(File.join(@dead_letter_dir, "*.json")).each do |file|
          data = JSON.parse(File.read(file))
          count += 1 if data["topic"] == topic.to_s
        rescue JSON::ParserError
          next
        end
        count
      end

      def topics
        return [] unless Dir.exist?(@dir)
        Dir.children(@dir)
           .reject { |d| d == "dead_letter" }
           .select { |d| File.directory?(File.join(@dir, d)) }
      end

      # Get dead letter jobs for a topic — messages that exceeded max retries.
      # Returns Hashes (raw job data with status "dead").
      def dead_letters(topic, max_retries: 3)
        return [] unless Dir.exist?(@dead_letter_dir)

        files = Dir.glob(File.join(@dead_letter_dir, "*.json")).sort_by { |f| File.mtime(f) }
        jobs = []

        files.each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if (data["attempts"] || 0) < max_retries
          data["status"] = "dead"
          jobs << data
        rescue JSON::ParserError
          next
        end

        jobs
      end

      # Delete messages by status. For "failed"/"dead"/"dead_letter", removes
      # from the dead_letter directory. For "completed"/"pending", removes
      # matching jobs from the topic (pending) directory. Returns count purged.
      def purge(topic, status)
        count = 0

        if dead_status?(status)
          return 0 unless Dir.exist?(@dead_letter_dir)

          Dir.glob(File.join(@dead_letter_dir, "*.json")).each do |file|
            data = JSON.parse(File.read(file))
            if data["topic"] == topic.to_s
              File.delete(file)
              count += 1
            end
          rescue JSON::ParserError
            next
          end
        else
          dir = topic_path(topic)
          return 0 unless Dir.exist?(dir)

          Dir.glob(File.join(dir, "*.json")).each do |file|
            data = JSON.parse(File.read(file))
            if data["status"].to_s == status.to_s
              File.delete(file)
              count += 1
            end
          rescue JSON::ParserError
            next
          end
        end

        count
      end

      # Revive dead-letter jobs (under max_retries) back to pending.
      # Returns the number of jobs re-queued.
      def retry_failed(topic, max_retries: 3)
        return 0 unless Dir.exist?(@dead_letter_dir)

        dir = topic_path(topic)
        FileUtils.mkdir_p(dir)
        count = 0

        Dir.glob(File.join(@dead_letter_dir, "*.json")).each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if (data["attempts"] || 0) >= max_retries

          msg = Tina4::Job.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"],
            priority: data["priority"] || 0,
            attempts: data["attempts"] || 0,
            error: data["error"]
          )
          enqueue(msg)
          File.delete(file)
          count += 1
        rescue JSON::ParserError
          next
        end

        count
      end

      # Remove all pending jobs from a topic. Returns count removed.
      def clear(topic)
        dir = topic_path(topic)
        return 0 unless Dir.exist?(dir)
        count = 0
        Dir.glob(File.join(dir, "*.json")).each do |file|
          File.delete(file)
          count += 1
        end
        count
      end

      # Jobs that have failed at least once but are still being retried.
      #
      # Under the auto-retry lifecycle a failed-but-retryable job lives in the
      # pending queue (not the dead-letter dir), so this scans the topic dir
      # for jobs with 0 < attempts < max_retries. Dead-lettered jobs are
      # returned by dead_letters(). Returns Hashes.
      def failed(topic, max_retries: 3)
        dir = topic_path(topic)
        return [] unless Dir.exist?(dir)
        jobs = []
        Dir.glob(File.join(dir, "*.json")).sort_by { |f| File.mtime(f) }.each do |file|
          data = JSON.parse(File.read(file))
          attempts = data["attempts"] || 0
          next unless attempts > 0 && attempts < max_retries
          jobs << data
        rescue JSON::ParserError
          next
        end
        jobs
      end

      # Revive a specific dead-letter job by id back to the pending queue.
      # When job_id is nil, revives every dead-letter for the topic.
      #
      # This is a manual override (Queue#retry(job_id)) — it always revives a
      # dead-letter regardless of attempt count, mirroring job.retry. Returns
      # true if any job was re-queued.
      def retry_job(topic, job_id: nil, delay_seconds: 0)
        return false unless Dir.exist?(@dead_letter_dir)

        available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
        count = 0

        Dir.glob(File.join(@dead_letter_dir, "*.json")).each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if job_id && data["id"] != job_id.to_s

          msg = Tina4::Job.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"],
            priority: data["priority"] || 0,
            attempts: (data["attempts"] || 0) + 1,
            available_at: available_at,
            error: nil
          )
          enqueue(msg)
          File.delete(file)
          count += 1
          break if job_id  # found the specific job, stop scanning
        rescue JSON::ParserError
          next
        end

        count > 0
      end

      private

      DEAD_STATES = %w[failed dead dead_letter].freeze

      def dead_status?(status)
        DEAD_STATES.include?(status.to_s)
      end

      # Return [{file:, data:}, ...] for every pending, non-delayed job in the
      # topic, ordered by the dequeue policy: priority DESC, then created_at
      # ASC (oldest first).
      def available_candidates(topic)
        dir = topic_path(topic)
        return [] unless Dir.exist?(dir)

        now = Time.now
        candidates = []

        Dir.glob(File.join(dir, "*.json")).each do |f|
          data = JSON.parse(File.read(f))
          # Skip messages that are not yet available (delayed).
          if data["available_at"]
            available_at = Time.parse(data["available_at"])
            next if available_at > now
          end
          candidates << { file: f, data: data }
        rescue JSON::ParserError
          next
        end

        # priority DESC, then created_at ASC. created_at is an ISO-8601 string
        # so lexicographic order == chronological order. Fall back to the file
        # name for jobs written before created_at was persisted.
        candidates.sort_by do |c|
          [-(c[:data]["priority"] || 0), c[:data]["created_at"].to_s, c[:file]]
        end
      end

      def job_from_data(data, topic)
        Tina4::Job.new(
          topic: data["topic"] || topic.to_s,
          payload: data["payload"],
          id: data["id"],
          priority: data["priority"] || 0,
          available_at: data["available_at"] ? Time.parse(data["available_at"]) : nil,
          attempts: data["attempts"] || 0,
          created_at: data["created_at"] ? Time.parse(data["created_at"]) : nil,
          error: data["error"]
        )
      end

      # Write the job back to the pending queue with a fresh created_at (so
      # within a priority tier it sorts behind jobs not yet attempted) and the
      # current attempts/error carried over.
      def requeue_job(job, delay_seconds: 0, error: nil)
        available_at = delay_seconds > 0 ? (Time.now + delay_seconds).iso8601(6) : nil
        data = {
          id: job.id,
          topic: job.topic,
          payload: job.payload,
          status: "pending",
          priority: job.priority,
          attempts: job.attempts,
          error: error,
          created_at: Time.now.iso8601(6)
        }
        data[:available_at] = available_at if available_at
        @mutex.synchronize do
          topic_dir = topic_path(job.topic)
          FileUtils.mkdir_p(topic_dir)
          File.write(File.join(topic_dir, "#{job.id}.json"), JSON.generate(data))
        end
      end

      # Move a failed job to the dead-letter directory. Terminal until a manual
      # retry_failed/retry revives it.
      def move_to_dead_letter(job, error = "")
        data = {
          id: job.id,
          topic: job.topic,
          payload: job.payload,
          status: "dead",
          priority: job.priority,
          attempts: job.attempts,
          error: error,
          failed_at: Time.now.iso8601(6)
        }
        @mutex.synchronize do
          FileUtils.mkdir_p(@dead_letter_dir)
          File.write(File.join(@dead_letter_dir, "#{job.id}.json"), JSON.generate(data))
        end
      end

      def topic_path(topic)
        safe_topic = topic.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
        File.join(@dir, safe_topic)
      end
    end
  end
end
