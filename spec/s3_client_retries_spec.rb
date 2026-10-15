# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "socket"

# #229 parity: the S3 client fails loud on missing credentials, retries a
# transient failure (429 / any 5xx / a dropped connection) twice at most
# honouring Retry-After, does NOT retry a final 4xx, and keeps an endpoint's
# path prefix in front of every request. Proven against a REAL local socket
# server that records what the client sends and answers with chosen statuses -
# nothing in the client is replaced (no mocks). Mirrors the Python master.
RSpec.describe "Tina4::Realtime::S3Client #229 parity" do
  # A real HTTP/1.1 server on a thread. Each request pops the next entry from
  # +statuses+: an Integer is answered with that code (Retry-After on 429/503);
  # :drop closes the socket mid-request (a dropped connection). Records methods.
  class RecordingServer
    attr_reader :seen
    attr_accessor :statuses

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @seen = []
      @statuses = []
      @thread = Thread.new { serve }
    end

    def port = @server.addr[1]

    def stop
      @thread.kill
      @server.close
    rescue StandardError
      nil
    end

    private

    def serve
      loop do
        conn = @server.accept
        handle(conn)
      rescue StandardError
        next
      end
    end

    def handle(conn)
      line = conn.gets or return conn.close
      method, path, = line.split
      length = 0
      while (h = conn.gets) && h != "\r\n"
        length = h.split(":", 2)[1].to_i if h =~ /\Acontent-length:/i
      end
      conn.read(length) if length.positive?
      @seen << { method: method, path: path }
      nxt = @statuses.shift
      if nxt == :drop
        conn.close # dropped connection: no answer
        return
      end
      status = nxt.is_a?(Integer) ? nxt : 200
      body = status.between?(200, 299) ? "ok" : "err"
      headers = +"HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\n"
      headers << "Retry-After: 0\r\n" if [429, 503].include?(status)
      conn.write("#{headers}Connection: close\r\n\r\n#{body}")
      conn.close
    end
  end

  let(:server) { RecordingServer.new }
  after { server.stop }

  def client(endpoint: nil)
    Tina4::Realtime::S3Client.new(
      endpoint: endpoint || "http://127.0.0.1:#{server.port}",
      access_key: "AKID", secret_key: "SECRET", region: "us-east-1", timeout: 5
    )
  end

  it "raises S3ConfigError on missing credentials and sends nothing" do
    c = Tina4::Realtime::S3Client.new(endpoint: "http://127.0.0.1:#{server.port}", access_key: "", secret_key: "")
    expect { c.put_object("b", "k", "x") }.to raise_error(Tina4::Realtime::S3ConfigError, /TINA4_STORAGE_KEY and TINA4_STORAGE_SECRET/)
    expect(server.seen).to be_empty
  end

  it "refuses half a credential too" do
    [["", "S"], ["A", ""]].each do |ak, sk|
      c = Tina4::Realtime::S3Client.new(endpoint: "http://127.0.0.1:#{server.port}", access_key: ak, secret_key: sk)
      expect { c.put_object("b", "k", "x") }.to raise_error(Tina4::Realtime::S3ConfigError)
    end
  end

  [429, 500, 502, 503, 504, :drop].each do |transient|
    it "retries a transient #{transient} then succeeds" do
      server.statuses = [transient, 200]
      client.put_object("bucket", "key", "x")
      expect(server.seen.length).to eq(2)
    end
  end

  it "gives up after two retries (503)" do
    server.statuses = [503, 503, 503, 503]
    expect { client.put_object("bucket", "key", "x") }
      .to raise_error(Tina4::Realtime::S3Error) { |e| expect(e.status).to eq(503) }
    expect(server.seen.length).to eq(3)
  end

  [400, 403, 404].each do |code|
    it "does not retry a final #{code}" do
      server.statuses = [code, 200]
      expect { client.get_object("bucket", "key") }
        .to raise_error(Tina4::Realtime::S3Error) { |e| expect(e.status).to eq(code) }
      expect(server.seen.length).to eq(1)
    end
  end

  it "keeps an endpoint path prefix in front of the request path" do
    server.statuses = [200]
    client(endpoint: "http://127.0.0.1:#{server.port}/s3pfx").put_object("bucket", "obj.png", "x")
    expect(server.seen.first[:path]).to eq("/s3pfx/bucket/obj.png")
  end

  it "keeps the endpoint path prefix in a presigned URL" do
    url = client(endpoint: "http://127.0.0.1:#{server.port}/s3pfx").presigned_get_url("bucket", "obj.png")
    expect(url).to include(":#{server.port}/s3pfx/bucket/obj.png?")
  end
end
