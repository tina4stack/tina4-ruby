# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "socket"
require "uri"
require "tina4/session_handlers/mongo_wire_client"

# The zero-dependency MongoDB wire client must decode every reply a real server
# sends, including replica-set replies.
#
# Python's and PHP's wire clients returned nil for ObjectId / Timestamp /
# BinData WITHOUT consuming the bytes, so every write against a replica-set
# member (7 AND 8 alike: electionId, opTime, $clusterTime, operationTime) came
# back as garbage. Ruby's client already decoded those types; these specs lock
# that in with the SAME captured bytes and the SAME live probe the other three
# frameworks now run.
#
# No mocks: the live spec talks to the real server at TINA4_TEST_MONGO_URI; the
# others feed the decoder real bytes captured from a mongo:8.3.11 replica-set
# member - a pure function over its input.
RSpec.describe Tina4::SessionHandlers::MongoWireClient do
  # Body document of a real OP_MSG reply to an upsert, captured byte for byte.
  replica_set_upsert_reply = [
    "12010000106e000100000007656c656374696f6e4964007fffffff0000000000000001",
    "036f7054696d65001c00000011747300020000009be4b46a12740001000000000000",
    "000004757073657274656400280000000330002000000010696e646578000000000002",
    "5f69640007000000736573732d31000000106e4d6f6469666965640000000000016f6b",
    "00000000000000f03f0324636c757374657254696d65005800000011636c7573746572",
    "54696d6500020000009be4b46a037369676e61747572650033000000056861736800",
    "14000000000000000000000000000000000000000000000000126b65794964000000",
    "0000000000000000116f7065726174696f6e54696d6500020000009be4b46a00"
  ].join
  # Timestamp(1790239899, 2): seconds in the high 32 bits, increment low.
  captured_timestamp = (1_790_239_899 << 32) | 2

  mongo_uri = URI(ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017"))

  let(:client) do
    described_class.new(host: mongo_uri.host, port: mongo_uri.port || 27_017,
                        database: "tina4_wire_types", collection: "wire")
  end

  def decode(client, bytes)
    client.send(:decode_document, bytes.b, [0])
  end

  it "decodes every field of a replica-set write reply" do
    reply = decode(client, [replica_set_upsert_reply].pack("H*"))

    expect(reply["n"]).to eq(1)
    expect(reply["ok"]).to eq(1.0)
    expect(reply["nModified"]).to eq(0)
    expect(reply["upserted"]).to eq([{ "index" => 0, "_id" => "sess-1" }])
    expect(reply["electionId"]).to eq("7fffffff0000000000000001")
    expect(reply["opTime"]).to eq({ "ts" => captured_timestamp, "t" => 1 })
    expect(reply["operationTime"]).to eq(captured_timestamp)
    expect(reply["$clusterTime"]["clusterTime"]).to eq(captured_timestamp)
    expect(reply["$clusterTime"]["signature"]).to eq({ "hash" => ("\x00" * 20).b, "keyId" => 0 })
  end

  it "skips an unknown type without corrupting the fields after it" do
    # {"inner": {"weird": <type 0x13 decimal128, 16 bytes>}, "ok": 1.0}
    weird = "\x13weird\x00".b + (0..15).map(&:chr).join.b
    inner = [weird.bytesize + 5].pack("V") + weird + "\x00".b
    body = "\x03inner\x00".b + inner + "\x01ok\x00".b + [1.0].pack("E")
    document = [body.bytesize + 5].pack("V") + body + "\x00".b

    decoded = decode(client, document)

    expect(decoded["ok"]).to eq(1.0)
    expect(decoded.keys).to eq(%w[inner ok])
  end

  # Every mongod - standalone or replica set, 7 or 8 - answers `hello` with an
  # ObjectId (topologyVersion.processId) and a UTC datetime (localTime) BEFORE
  # maxBsonObjectSize. A decoder that mis-sizes either never reaches it intact.
  it "decodes a real hello reply through the wire client's own command path" do
    begin
      Socket.tcp(mongo_uri.host, mongo_uri.port || 27_017, connect_timeout: 2).close
    rescue StandardError
      skip "mongo not reachable at #{mongo_uri.host}:#{mongo_uri.port} (set TINA4_TEST_MONGO_URI)"
    end

    reply = begin
      client.send(:command, { "hello" => 1, "$db" => "admin" })
    ensure
      client.close
    end

    expect(reply["ok"]).to eq(1.0)
    expect(reply["maxBsonObjectSize"]).to eq(16 * 1024 * 1024)
    expect(reply["localTime"]).to be_a(Time)
    expect((reply["localTime"] - Time.now).abs).to be < 600
    expect(reply["topologyVersion"]["processId"]).to match(/\A[0-9a-f]{24}\z/)
  end
end
