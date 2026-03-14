# frozen_string_literal: true
require "json"
require "fileutils"

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

          files = Dir.glob(File.join(dir, "*.json")).sort_by { |f| File.mtime(f) }
          return nil if files.empty?

          file = files.first
          data = JSON.parse(File.read(file))
          File.delete(file)

          Tina4::QueueMessage.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"]
          )
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

      def topics
        return [] unless Dir.exist?(@dir)
        Dir.children(@dir)
           .reject { |d| d == "dead_letter" }
           .select { |d| File.directory?(File.join(@dir, d)) }
      end

      private

      def topic_path(topic)
        safe_topic = topic.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
        File.join(@dir, safe_topic)
      end
    end
  end
end
