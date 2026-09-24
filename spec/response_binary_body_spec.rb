# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "net/http"

# A binary body sent with an EXPLICIT content type arrives byte for byte.
#
# The bug class (found in tina4-nodejs, checked here at parity): a byte body
# given with a content type is re-encoded as text on the way out, so an image
# or download route sends a broken file. Ruby adds its own trap: File.read
# without "rb" hands back PNG bytes TAGGED as UTF-8, so the pipeline must never
# treat the tag as a promise that the bytes are text.
#
# NO MOCKS. A REAL Tina4::WebServer on a REAL TCP port, driven with Net::HTTP;
# each route sends all 256 byte values (0x00-0xFF) and the spec compares the
# raw bytes received.
RSpec.describe "Binary response body" do
  ALL_BYTES = (0..255).to_a.pack("C*").freeze

  before(:all) do
    @port = free_port
    @server = Tina4::WebServer.new(Tina4::RackApp.new(root_dir: Dir.pwd), host: "127.0.0.1", port: @port)
    @previous_override = ENV["TINA4_OVERRIDE_CLIENT"]
    @previous_no_ai = ENV["TINA4_NO_AI_PORT"]
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    @thread = Thread.new { @server.start }
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", @port).close
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise "server never came up on port #{@port}" if Time.now > deadline

      sleep 0.05
      retry
    end
  end

  after(:all) do
    @server.stop
    @thread.join(5)
    if @previous_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = @previous_override end
    if @previous_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = @previous_no_ai end
  end

  # spec_helper clears the router before every example, so routes are declared per example.
  before(:each) do
    Tina4::Router.get("/bin/call") { |_request, response| response.call(ALL_BYTES, 200, "image/png") }
    Tina4::Router.get("/bin/send") { |_request, response| response.send(ALL_BYTES, status_code: 200, content_type: "application/octet-stream") }
    Tina4::Router.get("/bin/utf8-tagged") { |_request, response| response.call(ALL_BYTES.dup.force_encoding("UTF-8"), 200, "image/png") }
    Tina4::Router.get("/bin/text") { |_request, response| response.call("héllo", 200, "text/plain; charset=utf-8") }
    Tina4::Router.get("/bin/json") { |_request, response| response.call({ "a" => 1 }, 200, "application/vnd.api+json") }
  end

  def free_port
    socket = TCPServer.new("127.0.0.1", 0)
    socket.addr[1]
  ensure
    socket&.close
  end

  def fetch(path)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      reply = http.get(path, { "Accept-Encoding" => "identity" })
      [reply.code.to_i, reply["content-type"], (reply.body || "").b]
    end
  end

  {
    "/bin/call" => "image/png",
    "/bin/send" => "application/octet-stream",
    "/bin/utf8-tagged" => "image/png"
  }.each do |path, content_type|
    it "#{path}: the 256 bytes 0x00-0xFF arrive identical with content type #{content_type}" do
      status, received_type, body = fetch(path)
      expect(status).to eq(200)
      expect(received_type).to eq(content_type)
      expect(body.bytesize).to eq(256)
      expect(body).to eq(ALL_BYTES)
    end
  end

  it "a string with an explicit type is still sent as UTF-8 text" do
    _, _, body = fetch("/bin/text")
    expect(body).to eq("héllo".b)
  end

  it "a hash with an explicit type is still JSON" do
    _, received_type, body = fetch("/bin/json")
    expect(received_type).to eq("application/vnd.api+json")
    expect(body).to eq('{"a":1}')
  end
end
