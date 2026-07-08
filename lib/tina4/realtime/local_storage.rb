# frozen_string_literal: true

require "fileutils"

module Tina4
  module Realtime
    # Zero-dependency filesystem store. The default backend.
    class LocalStorage < StorageBackend
      def initialize(directory = nil)
        super()
        @directory = File.expand_path(directory || ENV["TINA4_STORAGE_DIR"] || "data/rt_storage")
        FileUtils.mkdir_p(@directory)
      end

      def put(key, data, _mime = "application/octet-stream")
        File.binwrite(path_for(key), data)
        nil
      end

      def get(key)
        File.binread(path_for(key))
      rescue Errno::ENOENT, ArgumentError
        nil
      end

      # No direct URL: the permissioned app download route serves local files.
      def url(_key, _ttl = 3600)
        nil
      end

      def delete(key)
        File.delete(path_for(key))
        nil
      rescue Errno::ENOENT, ArgumentError
        nil
      end

      def exists?(key)
        File.file?(path_for(key))
      rescue ArgumentError
        false
      end

      private

      # Resolve inside the root and reject any traversal attempt.
      def path_for(key)
        target = File.expand_path(File.join(@directory, key.to_s))
        unless target == @directory || target.start_with?(@directory + File::SEPARATOR)
          raise ArgumentError, "unsafe storage key: #{key.inspect}"
        end

        target
      end
    end
  end
end
