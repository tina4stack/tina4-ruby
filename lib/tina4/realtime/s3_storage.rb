# frozen_string_literal: true

module Tina4
  module Realtime
    # S3-compatible store (AWS S3, MinIO, ...). Opt-in; needs the aws-sdk-s3 gem.
    #
    # Presigned GET URLs let clients fetch large blobs straight from object
    # storage instead of streaming through the app.
    class S3Storage < StorageBackend
      def initialize(endpoint: nil, key: nil, secret: nil, bucket: nil, region: nil)
        super()
        require "aws-sdk-s3" # optional dependency, loaded lazily

        @bucket = bucket || ENV["TINA4_STORAGE_BUCKET"]
        raise ArgumentError, "S3Storage requires TINA4_STORAGE_BUCKET" if @bucket.nil? || @bucket.empty?

        opts = {
          access_key_id: key || ENV["TINA4_STORAGE_KEY"],
          secret_access_key: secret || ENV["TINA4_STORAGE_SECRET"],
          region: region || ENV["TINA4_STORAGE_REGION"] || "us-east-1",
          force_path_style: true
        }
        ep = endpoint || ENV["TINA4_STORAGE_URL"]
        opts[:endpoint] = ep if ep && !ep.empty?
        @client = Aws::S3::Client.new(**opts)
      end

      def put(key, data, mime = "application/octet-stream")
        @client.put_object(bucket: @bucket, key: key, body: data, content_type: mime)
        nil
      end

      def get(key)
        @client.get_object(bucket: @bucket, key: key).body.read
      rescue StandardError
        nil
      end

      def url(key, ttl = 3600)
        Aws::S3::Presigner.new(client: @client)
                          .presigned_url(:get_object, bucket: @bucket, key: key, expires_in: ttl)
      end

      def delete(key)
        @client.delete_object(bucket: @bucket, key: key)
        nil
      rescue StandardError => e
        Tina4::Log.error("S3Storage delete failed for #{key}: #{e.message}")
        nil
      end

      def exists?(key)
        @client.head_object(bucket: @bucket, key: key)
        true
      rescue StandardError
        false
      end
    end
  end
end
