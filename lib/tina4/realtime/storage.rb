# frozen_string_literal: true

require "securerandom"

module Tina4
  module Realtime
    # Storage backend selection + key generation for the realtime "files"
    # feature. Mirrors the cache/session/queue backend pattern:
    # TINA4_STORAGE_BACKEND (local default | s3) plus per-backend env vars, with
    # a graceful fallback to local if an s3 backend cannot be built (missing gem
    # or incomplete config) - a real persistent store, never a silent no-op.
    module Storage
      UNSAFE = /[^A-Za-z0-9]/

      # Generate an opaque, collision-free storage key, preserving the extension.
      # The key carries no user-controlled path segment, so it can never traverse
      # outside the storage root.
      def self.key(filename = "")
        ext = ""
        if filename && filename.include?(".")
          raw = filename.rpartition(".").last
          clean = raw.gsub(UNSAFE, "")[0, 12]
          ext = ".#{clean}" unless clean.nil? || clean.empty?
        end
        "#{SecureRandom.hex(16)}#{ext}"
      end

      # Resolve the storage backend from an explicit instance or the environment.
      def self.select(storage = nil)
        return storage unless storage.nil?

        name = (ENV["TINA4_STORAGE_BACKEND"] || "local").downcase
        if name == "s3"
          begin
            return S3Storage.new
          # LoadError (missing aws-sdk-s3 gem) is a ScriptError, NOT a
          # StandardError, so it must be rescued explicitly or the "graceful
          # fallback when the driver is absent" contract breaks (the whole mount
          # would crash instead of degrading to local).
          rescue StandardError, LoadError => e
            Tina4::Log.warning(
              "realtime files: S3 storage unavailable (#{e.message}); " \
              "falling back to local filesystem storage."
            )
            return LocalStorage.new
          end
        end
        LocalStorage.new
      end
    end
  end
end
