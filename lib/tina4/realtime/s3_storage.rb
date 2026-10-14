# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


module Tina4
  module Realtime
    # S3-compatible store (AWS S3, MinIO, Garage, ...). Opt-in, zero dependencies.
    #
    # Talks to S3 through Tina4's own stdlib SigV4 client ({S3Client}) — no
    # aws-sdk-s3 gem. Presigned GET URLs let clients fetch large blobs straight
    # from object storage instead of streaming through the app.
    class S3Storage < StorageBackend
      def initialize(endpoint: nil, key: nil, secret: nil, bucket: nil, region: nil)
        super()
        @bucket = bucket || ENV["TINA4_STORAGE_BUCKET"]
        raise ArgumentError, "S3Storage requires TINA4_STORAGE_BUCKET" if @bucket.nil? || @bucket.empty?

        @client = S3Client.new(
          endpoint: endpoint || ENV["TINA4_STORAGE_URL"],
          access_key: key || ENV["TINA4_STORAGE_KEY"] || "",
          secret_key: secret || ENV["TINA4_STORAGE_SECRET"] || "",
          region: region || ENV["TINA4_STORAGE_REGION"] || "us-east-1"
        )
      end

      def put(key, data, mime = "application/octet-stream")
        @client.put_object(@bucket, key, data, mime)
        nil
      end

      def get(key)
        @client.get_object(@bucket, key)
      rescue StandardError
        nil
      end

      def url(key, ttl = 3600)
        @client.presigned_get_url(@bucket, key, expires: ttl)
      end

      def delete(key)
        @client.delete_object(@bucket, key)
        nil
      rescue StandardError => e
        Tina4::Log.error("S3Storage delete failed for #{key}: #{e.message}")
        nil
      end

      def exists?(key)
        @client.head_object(@bucket, key)
        true
      rescue StandardError
        false
      end
    end
  end
end
