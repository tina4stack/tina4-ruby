# frozen_string_literal: true
require "json"
require "fileutils"

module Tina4
  module SessionHandlers
    class FileHandler
      def initialize(options = {})
        @dir = options[:dir] || File.join(Dir.pwd, "sessions")
        @ttl = options[:ttl] || 86400
        FileUtils.mkdir_p(@dir)
      end

      def read(session_id)
        path = session_path(session_id)
        return nil unless File.exist?(path)

        # Check expiry
        if File.mtime(path) + @ttl < Time.now
          File.delete(path)
          return nil
        end

        data = File.read(path)
        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      def write(session_id, data)
        path = session_path(session_id)
        File.write(path, JSON.generate(data))
      end

      def destroy(session_id)
        path = session_path(session_id)
        File.delete(path) if File.exist?(path)
      end

      def cleanup
        return unless Dir.exist?(@dir)
        Dir.glob(File.join(@dir, "sess_*")).each do |file|
          File.delete(file) if File.mtime(file) + @ttl < Time.now
        end
      end

      private

      def session_path(session_id)
        safe_id = session_id.gsub(/[^a-zA-Z0-9_-]/, "")
        File.join(@dir, "sess_#{safe_id}.json")
      end
    end
  end
end
