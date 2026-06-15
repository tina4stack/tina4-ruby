# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require_relative "base_backend"

module Tina4
  module CacheBackends
    # File-based cache — stores entries as JSON files in data/cache/ (parity
    # with Python _FileBackend). Always available; used as the graceful-degrade
    # target when a configured network backend is unreachable.
    class FileBackend < BaseBackend
      def initialize(cache_dir: "data/cache", max_entries: 1000)
        @dir = cache_dir
        @max_entries = max_entries
        @mutex = Mutex.new
        @hits = 0
        @misses = 0
        FileUtils.mkdir_p(@dir)
      end

      def get(key)
        path = key_path(key)
        @mutex.synchronize do
          unless File.exist?(path)
            @misses += 1
            return nil
          end
          begin
            data = JSON.parse(File.read(path))
            expires_at = data["expires_at"]
            if expires_at && Time.now.to_f > expires_at
              File.delete(path) rescue nil
              @misses += 1
              return nil
            end
            @hits += 1
            data["value"]
          rescue JSON::ParserError, SystemCallError
            @misses += 1
            nil
          end
        end
      end

      def set(key, value, ttl)
        expires_at = ttl > 0 ? Time.now.to_f + ttl : nil
        entry = { "key" => key, "value" => value, "expires_at" => expires_at }
        @mutex.synchronize do
          FileUtils.mkdir_p(@dir)
          begin
            files = Dir.glob(File.join(@dir, "*.json")).sort_by { |f| File.mtime(f) }
            while files.size >= @max_entries
              File.delete(files.shift) rescue nil
            end
          rescue SystemCallError
          end
          begin
            File.write(key_path(key), JSON.generate(entry))
          rescue SystemCallError
          end
        end
      end

      def delete(key)
        path = key_path(key)
        @mutex.synchronize do
          if File.exist?(path)
            File.delete(path) rescue nil
            true
          else
            false
          end
        end
      end

      def clear
        @mutex.synchronize do
          @hits = 0
          @misses = 0
          Dir.glob(File.join(@dir, "*.json")).each { |f| File.delete(f) rescue nil }
        end
      end

      def stats
        @mutex.synchronize do
          now = Time.now.to_f
          count = 0
          Dir.glob(File.join(@dir, "*.json")).each do |f|
            begin
              data = JSON.parse(File.read(f))
              exp = data["expires_at"]
              if exp && now > exp
                File.delete(f) rescue nil
              else
                count += 1
              end
            rescue JSON::ParserError, SystemCallError
            end
          end
          { hits: @hits, misses: @misses, size: count, backend: "file" }
        end
      end

      def name
        "file"
      end

      # Actively delete expired entries and return the number removed.
      # (The file backend is the only one that supports an explicit sweep —
      # network/db backends expire lazily via TTL.)
      #
      # @return [Integer]
      def sweep
        removed = 0
        now = Time.now.to_f
        @mutex.synchronize do
          Dir.glob(File.join(@dir, "*.json")).each do |f|
            begin
              data = JSON.parse(File.read(f))
              if data["expires_at"] && now > data["expires_at"]
                File.delete(f) rescue nil
                removed += 1
              end
            rescue JSON::ParserError, SystemCallError
            end
          end
        end
        removed
      end

      private

      def key_path(key)
        File.join(@dir, "#{Digest::SHA256.hexdigest(key)}.json")
      end
    end
  end
end
