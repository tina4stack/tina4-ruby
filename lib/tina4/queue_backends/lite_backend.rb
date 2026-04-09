# frozen_string_literal: true
require "json"
require "fileutils"
require "time"

module Tina4
  module QueueBackends
    class LiteBackend
      def initialize(options = {})
        @dir = options[:dir] || File.join(Dir.pwd, ".queue")
        @dead_letter_dir = File.join(@dir, "dead_letter")
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
          dir = topic_path(topic)
          return nil unless Dir.exist?(dir)

          now = Time.now
          candidates = []

          Dir.glob(File.join(dir, "*.json")).each do |f|
            data = JSON.parse(File.read(f))
            # Skip messages that are not yet available (delayed)
            if data["available_at"]
              available_at = Time.parse(data["available_at"])
              next if available_at > now
            end
            candidates << { file: f, data: data, priority: data["priority"] || 0, mtime: File.mtime(f) }
          rescue JSON::ParserError
            next
          end

          return nil if candidates.empty?

          # Sort by priority descending (higher first), then by mtime ascending (oldest first)
          candidates.sort_by! { |c| [-c[:priority], c[:mtime]] }

          chosen = candidates.first
          File.delete(chosen[:file])
          data = chosen[:data]

          Tina4::Job.new(
            topic: data["topic"] || topic.to_s,
            payload: data["payload"],
            id: data["id"],
            priority: data["priority"] || 0,
            available_at: data["available_at"] ? Time.parse(data["available_at"]) : nil,
            attempts: data["attempts"] || 0
          )
        end
      end

      def dequeue_batch(topic, count)
        @mutex.synchronize do
          dir = topic_path(topic)
          return [] unless Dir.exist?(dir)

          now = Time.now
          candidates = []

          Dir.glob(File.join(dir, "*.json")).each do |f|
            data = JSON.parse(File.read(f))
            if data["available_at"]
              available_at = Time.parse(data["available_at"])
              next if available_at > now
            end
            candidates << { file: f, data: data, priority: data["priority"] || 0, mtime: File.mtime(f) }
          rescue JSON::ParserError
            next
          end

          return [] if candidates.empty?

          candidates.sort_by! { |c| [-c[:priority], c[:mtime]] }
          chosen = candidates.first(count)

          chosen.map do |c|
            File.delete(c[:file])
            data = c[:data]
            Tina4::Job.new(
              topic: data["topic"] || topic.to_s,
              payload: data["payload"],
              id: data["id"],
              priority: data["priority"] || 0,
              available_at: data["available_at"] ? Time.parse(data["available_at"]) : nil,
              attempts: data["attempts"] || 0
            )
          end
        end
      end

      def acknowledge(message)
        # File already deleted on dequeue
      end

      def requeue(message)
        enqueue(message)
      end

      def dead_letter(message)
        path = File.join(@dead_letter_dir, "#{message.id}.json")
        File.write(path, message.to_json)
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
      def dead_letters(topic, max_retries: 3)
        return [] unless Dir.exist?(@dead_letter_dir)

        files = Dir.glob(File.join(@dead_letter_dir, "*.json")).sort_by { |f| File.mtime(f) }
        jobs = []

        files.each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          data["status"] = "dead"
          jobs << data
        rescue JSON::ParserError
          next
        end

        jobs
      end

      # Delete messages by status (completed, failed, dead).
      # For 'dead', removes from the dead_letter directory.
      # For 'failed', removes from the topic directory (re-queued failed messages).
      # Returns the number of jobs purged.
      def purge(topic, status)
        count = 0

        if status.to_s == "dead"
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
        elsif status.to_s == "failed" || status.to_s == "completed" || status.to_s == "pending"
          dir = topic_path(topic)
          return 0 unless Dir.exist?(dir)

          Dir.glob(File.join(dir, "*.json")).each do |file|
            data = JSON.parse(File.read(file))
            if data["status"] == status.to_s
              File.delete(file)
              count += 1
            end
          rescue JSON::ParserError
            next
          end
        end

        count
      end

      # Re-queue failed messages (under max_retries) back to pending.
      # Returns the number of jobs re-queued.
      def retry_failed(topic, max_retries: 3)
        return 0 unless Dir.exist?(@dead_letter_dir)

        dir = topic_path(topic)
        FileUtils.mkdir_p(dir)
        count = 0

        # Dead letter directory contains messages that the Consumer moved there.
        # Only retry those whose attempts are under max_retries.
        Dir.glob(File.join(@dead_letter_dir, "*.json")).each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if (data["attempts"] || 0) >= max_retries

          data["status"] = "pending"
          msg = Tina4::Job.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"]
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

      # Get jobs that failed but are still eligible for retry (under max_retries).
      def failed(topic, max_retries: 3)
        return [] unless Dir.exist?(@dead_letter_dir)
        jobs = []
        Dir.glob(File.join(@dead_letter_dir, "*.json")).sort_by { |f| File.mtime(f) }.each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if (data["attempts"] || 0) >= max_retries
          jobs << data
        rescue JSON::ParserError
          next
        end
        jobs
      end

      # Retry all dead letter jobs for this topic. Returns true if any were re-queued.
      def retry_job(topic, delay_seconds: 0)
        return false unless Dir.exist?(@dead_letter_dir)

        available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
        count = 0

        Dir.glob(File.join(@dead_letter_dir, "*.json")).each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s

          msg = Tina4::Job.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"],
            attempts: (data["attempts"] || 0) + 1,
            available_at: available_at
          )
          enqueue(msg)
          File.delete(file)
          count += 1
        rescue JSON::ParserError
          next
        end

        count > 0
      end

      private

      def topic_path(topic)
        safe_topic = topic.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
        File.join(@dir, safe_topic)
      end
    end
  end
end
