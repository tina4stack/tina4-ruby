# frozen_string_literal: true
require "json"
require "fileutils"
require "digest"

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

      # Garbage-collect expired sessions. Matches the Python interface.
      # @param max_age [Integer] maximum session age in seconds
      def gc(max_age)
        return unless Dir.exist?(@dir)
        now = Time.now
        Dir.glob(File.join(@dir, "sess_*")).each do |file|
          File.delete(file) if File.mtime(file) + max_age < now
        rescue StandardError
          # Corrupt or locked file — skip
        end
      end

      private

      # SHA-256 of the id. A session id can therefore never become a path
      # component, AND two distinct ids can never collide.
      #
      # The previous gsub(/[^a-zA-Z0-9_-]/, "") was traversal-safe but LOSSY: it
      # collapsed "a/b" and "ab" onto the same sess_ab.json, so two different
      # sessions shared one record and one user's data surfaced under another
      # user's id. Parity with the Python master's FileSessionHandler._file
      # (hashlib.sha256(session_id.encode()).hexdigest()).
      #
      # The sess_ prefix is kept deliberately so #cleanup and #gc keep matching
      # with their Dir.glob("sess_*").
      def session_path(session_id)
        File.join(@dir, "sess_#{Digest::SHA256.hexdigest(session_id.to_s)}.json")
      end
    end
  end
end
