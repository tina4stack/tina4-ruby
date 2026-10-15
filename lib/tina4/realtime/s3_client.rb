# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "net/http"
require "uri"
require "openssl"
require "digest"
require "time"

module Tina4
  module Realtime
    # An S3 request returned a non-2xx status; +status+ holds the HTTP code.
    class S3Error < StandardError
      attr_reader :status

      def initialize(status, message)
        super(message)
        @status = status
      end
    end

    # Zero-dependency S3 client (AWS Signature Version 4) on the Ruby standard
    # library. Covers exactly what the realtime {S3Storage} backend needs — PUT,
    # GET, DELETE, HEAD, and a presigned GET URL — so the +s3+ backend no longer
    # needs the aws-sdk-s3 gem.
    #
    # Path-style addressing (<endpoint>/<bucket>/<key>), which S3-compatible
    # servers (MinIO, Garage) require and AWS accepts; with no endpoint it
    # targets https://s3.<region>.amazonaws.com. SigV4 is HMAC-SHA256 canonical
    # signing — the same primitive Tina4's JWT already uses (stdlib OpenSSL);
    # nothing here is reinvented crypto. Mirrors the Python master, proven
    # against AWS's published SigV4 test vector.
    class S3Client
      ALGORITHM = "AWS4-HMAC-SHA256"
      SERVICE = "s3"

      def initialize(endpoint: nil, access_key: "", secret_key: "", region: "us-east-1", timeout: 30)
        @region = region && !region.empty? ? region : "us-east-1"
        @access_key = access_key || ""
        @secret_key = secret_key || ""
        @timeout = timeout
        base = endpoint && !endpoint.empty? ? endpoint : "https://s3.#{@region}.amazonaws.com"
        base = base.delete_suffix("/") while base.end_with?("/") # strip trailing slashes without a regex
        @scheme = base[%r{\A([a-z][a-z0-9+.\-]*)://}i, 1] || "https"
        @host = base.sub(%r{\A[a-z][a-z0-9+.\-]*://}i, "") # authority (host[:port]) — matches the Host header
      end

      # -- public API (the subset S3Storage uses) ------------------------------

      def put_object(bucket, key, data, content_type = "application/octet-stream")
        request("PUT", canonical_uri(bucket, key), data, { "content-type" => content_type })
      end

      def get_object(bucket, key)
        request("GET", canonical_uri(bucket, key), "")[1]
      end

      def delete_object(bucket, key)
        request("DELETE", canonical_uri(bucket, key), "")
        nil
      end

      def head_object(bucket, key)
        request("HEAD", canonical_uri(bucket, key), "")
        nil
      end

      # Create the bucket (path-style PUT /<bucket>); an already-owned bucket (409) is success.
      def create_bucket(bucket)
        request("PUT", "/#{self.class.uri_encode(bucket, true)}", "")
        nil
      rescue S3Error => e
        raise unless e.status == 409
      end

      # A URL that fetches the object directly, signed via SigV4 query params.
      def presigned_get_url(bucket, key, expires: 3600)
        now = Time.now.utc
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        datestamp = now.strftime("%Y%m%d")
        uri = canonical_uri(bucket, key)
        scope = "#{datestamp}/#{@region}/#{SERVICE}/aws4_request"
        query = {
          "X-Amz-Algorithm" => ALGORITHM,
          "X-Amz-Credential" => "#{@access_key}/#{scope}",
          "X-Amz-Date" => amz_date,
          "X-Amz-Expires" => expires.to_s,
          "X-Amz-SignedHeaders" => "host"
        }
        canonical_qs = canonical_query(query)
        canonical_request = ["GET", uri, canonical_qs, "host:#{@host}\n", "host", "UNSIGNED-PAYLOAD"].join("\n")
        signature = sign(canonical_request, amz_date, datestamp, scope)
        "#{@scheme}://#{@host}#{uri}?#{canonical_qs}&X-Amz-Signature=#{signature}"
      end

      # SigV4 canonical encoding: keep the RFC 3986 unreserved set literal; keep
      # "/" in a path, percent-encode it in a query; space -> %20.
      def self.uri_encode(value, is_path)
        value.to_s.b.each_byte.map do |byte|
          ch = byte.chr
          if ch.match?(/[A-Za-z0-9\-_.~]/) || (is_path && ch == "/")
            ch
          else
            format("%%%02X", byte)
          end
        end.join
      end

      private

      def canonical_uri(bucket, key)
        "/#{self.class.uri_encode(bucket, true)}/#{self.class.uri_encode(key, true)}"
      end

      def canonical_query(query)
        query.sort.map { |k, v| "#{self.class.uri_encode(k, false)}=#{self.class.uri_encode(v, false)}" }.join("&")
      end

      def signing_key(datestamp)
        k_date = OpenSSL::HMAC.digest("SHA256", "AWS4#{@secret_key}", datestamp)
        k_region = OpenSSL::HMAC.digest("SHA256", k_date, @region)
        k_service = OpenSSL::HMAC.digest("SHA256", k_region, SERVICE)
        OpenSSL::HMAC.digest("SHA256", k_service, "aws4_request")
      end

      def sign(canonical_request, amz_date, datestamp, scope)
        string_to_sign = [ALGORITHM, amz_date, scope, Digest::SHA256.hexdigest(canonical_request)].join("\n")
        OpenSSL::HMAC.hexdigest("SHA256", signing_key(datestamp), string_to_sign)
      end

      def request(method, canonical_uri, body, extra_headers = {})
        now = Time.now.utc
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        datestamp = now.strftime("%Y%m%d")
        payload_hash = Digest::SHA256.hexdigest(body || "")

        signed = { "host" => @host, "x-amz-content-sha256" => payload_hash, "x-amz-date" => amz_date }
        canonical_headers = signed.sort.map { |k, v| "#{k}:#{v}\n" }.join
        signed_headers = signed.keys.sort.join(";")
        canonical_request = [method, canonical_uri, "", canonical_headers, signed_headers, payload_hash].join("\n")
        scope = "#{datestamp}/#{@region}/#{SERVICE}/aws4_request"
        signature = sign(canonical_request, amz_date, datestamp, scope)
        authorization = "#{ALGORITHM} Credential=#{@access_key}/#{scope}, " \
                        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

        uri = URI("#{@scheme}://#{@host}#{canonical_uri}")
        klass = { "PUT" => Net::HTTP::Put, "GET" => Net::HTTP::Get,
                  "DELETE" => Net::HTTP::Delete, "HEAD" => Net::HTTP::Head }.fetch(method)
        req = klass.new(uri)
        req["Authorization"] = authorization
        req["x-amz-content-sha256"] = payload_hash
        req["x-amz-date"] = amz_date
        extra_headers.each { |name, value| req[name] = value }
        req.body = body if %w[PUT POST].include?(method)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        response = http.request(req)
        status = response.code.to_i
        raise S3Error.new(status, "#{method} #{canonical_uri}: HTTP #{status}") if status < 200 || status >= 300

        [status, response.body || ""]
      end
    end
  end
end
