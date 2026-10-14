# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "openssl"
require "digest"

# Unit proof of the zero-dependency SigV4 client's signing math — no service,
# no mocks. The signature is checked against AWS's OWN published reference
# ("get-vanilla" from the SigV4 test suite); the live-server round-trip (real
# PUT/GET/presigned/DELETE against MinIO/Garage) lives in realtime_spec.rb.
RSpec.describe Tina4::Realtime::S3Client do
  it "signs the AWS get-vanilla test vector exactly" do
    secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    date_stamp = "20150830"
    region = "us-east-1"
    service = "service"
    amz_date = "20150830T123600Z"

    canonical_request = [
      "GET", "/", "",
      "host:example.amazonaws.com\nx-amz-date:20150830T123600Z\n",
      "host;x-amz-date",
      Digest::SHA256.hexdigest("")
    ].join("\n")
    string_to_sign = [
      "AWS4-HMAC-SHA256", amz_date,
      "#{date_stamp}/#{region}/#{service}/aws4_request",
      Digest::SHA256.hexdigest(canonical_request)
    ].join("\n")
    k = OpenSSL::HMAC.digest("SHA256", "AWS4#{secret}", date_stamp)
    k = OpenSSL::HMAC.digest("SHA256", k, region)
    k = OpenSSL::HMAC.digest("SHA256", k, service)
    k = OpenSSL::HMAC.digest("SHA256", k, "aws4_request")
    signature = OpenSSL::HMAC.hexdigest("SHA256", k, string_to_sign)

    expect(signature).to eq("5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
  end

  it "canonical-encodes keeping / in a path and encoding it in a query" do
    expect(described_class.uri_encode("a/b c~d", true)).to eq("a/b%20c~d")
    expect(described_class.uri_encode("a/b c~d", false)).to eq("a%2Fb%20c~d")
  end

  it "builds a presigned URL carrying the SigV4 query params" do
    client = described_class.new(
      endpoint: "http://localhost:9100", access_key: "AKID", secret_key: "secret", region: "us-east-1"
    )
    url = client.presigned_get_url("bucket", "obj.png", expires: 120)
    expect(url).to start_with("http://localhost:9100/bucket/obj.png?")
    ["X-Amz-Algorithm=AWS4-HMAC-SHA256", "X-Amz-Credential=", "X-Amz-Date=",
     "X-Amz-Expires=120", "X-Amz-SignedHeaders=host", "X-Amz-Signature="].each do |param|
      expect(url).to include(param)
    end
  end
end
