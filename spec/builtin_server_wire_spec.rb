# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# The built-in server ON THE WIRE (zero-dependency step 5).
#
# Tina4::WebServer is the framework's own HTTP/1.1 server on stdlib `socket`,
# replacing WEBrick in development AND Puma in production (Puma is opt-in: it
# is used only when the application bundles it - ADR-0067). The references are
# PHP's Tina4/Server.php and Python's built-in asyncio server, under ADR-0068's
# limits (TINA4_MAX_REQUEST_HEADER, TINA4_MAX_UPLOAD_SIZE, TINA4_REQUEST_TIMEOUT;
# spec/http_hardening_contract_spec.rb is that contract's runner).
#
# NO MOCKS. Every example talks raw bytes over a real TCP socket to a real
# server in its own process group, so what is asserted is exactly what a
# client, a proxy or an attacker sees.

require "spec_helper"
require "socket"
require "securerandom"
require "digest/sha1"
require_relative "support/shutdown_probe"

module BuiltinWireProbe
  Server = ShutdownProbe::Server

  module_function

  def write_app(dir)
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      #{ShutdownProbe.load_guard}
      PROJECT_DIR = #{dir.inspect}
      Tina4.initialize!(PROJECT_DIR)

      Tina4.get("/ping") { |_request, response| response.json({ pong: true }) }

      Tina4.get("/peer") do |request, response|
        response.json({ remote_addr: request.env["REMOTE_ADDR"], remote_ip: request.remote_ip })
      end

      Tina4.get("/path/{name}") do |request, response|
        response.json({ path_info: request.env["PATH_INFO"], name: request.params["name"] })
      end

      Tina4::Router.post("/echo") do |request, response|
        response.json({ bytes: request.body_raw.bytesize, body: request.body_raw,
                        content_length: request.env["CONTENT_LENGTH"] })
      end.no_auth

      Tina4::Router.post("/form") do |request, response|
        files = request.files.transform_values do |file|
          Array(file.is_a?(Array) ? file : [file]).map { |f| { filename: f["filename"], type: f["type"], content: f["content"] } }
        end
        response.json({ fields: request.body, files: files })
      end.no_auth

      Tina4.get("/sse") do |_request, response|
        response.stream(content_type: "text/event-stream") do |out|
          out << "data: first\\n\\n"
          sleep 1.5
          out << "data: second\\n\\n"
        end
      end

      Tina4.get("/large") { |_request, response| response.text("x" * 3_000_000) }

      Tina4::Router.websocket("/ws") do |connection, event, data|
        connection.send("echo:" + data.to_s) if event == :message
      end

      application = Tina4::RackApp.new(root_dir: PROJECT_DIR)
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot(env = {})
    dir = SpecTmpdir.create("tina4-builtin-wire")
    port = ShutdownProbe.free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")
    child_env = ShutdownProbe.base_env(
      { "TINA4_OVERRIDE_CLIENT" => "true", "PROBE_PORT" => port.to_s,
        "TINA4_SUPPRESS" => "true" }.merge(env)
    )
    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    Server.new(pid, port, dir, log_path).wait_until_serving!("/ping")
  end

  def connect(port)
    Socket.tcp("127.0.0.1", port, connect_timeout: 5)
  end

  # Read ONE complete response off a (possibly kept-alive) socket: status line,
  # headers, then exactly Content-Length body bytes (or to EOF when there is no
  # length). Returns { status:, headers: [[name, value]...], body:, raw_head: }.
  def read_response(sock, timeout: 5, head_request: false)
    buffer = +"".b
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    fill = lambda do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Timeout::Error, "no response within #{timeout}s (got #{buffer.inspect})" if remaining <= 0
      raise Timeout::Error, "no response within #{timeout}s (got #{buffer.inspect})" unless sock.wait_readable(remaining)

      buffer << sock.readpartial(65_536)
    end
    fill.call until buffer.include?("\r\n\r\n")
    head, rest = buffer.split("\r\n\r\n", 2)
    lines = head.split("\r\n")
    status = lines.first.split(" ")[1].to_i
    headers = lines.drop(1).map { |line| line.split(":", 2).map(&:strip) }
    length = headers.find { |name, _| name.casecmp?("content-length") }&.last
    body = rest.to_s
    if head_request
      # A HEAD response states the GET's length but carries no body.
      sock.ungetc(body) unless body.empty?
      body = +""
    elsif length
      fill_more = lambda do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error, "body truncated" if remaining <= 0 || !sock.wait_readable(remaining)

        body << sock.readpartial(65_536)
      end
      fill_more.call while body.bytesize < length.to_i
    else
      begin
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0 || !sock.wait_readable(remaining)

          body << sock.readpartial(65_536)
        end
      rescue EOFError, Errno::ECONNRESET
        # EOF delimits the body
      end
    end
    { status: status, headers: headers, body: body, raw_head: head }
  end

  def header(response, name)
    response[:headers].find { |key, _| key.casecmp?(name) }&.last
  end

  # true when the server closed its end (EOF / reset) within the timeout.
  def closed_by_server?(sock, timeout: 3)
    return false unless sock.wait_readable(timeout)

    sock.readpartial(1)
    false
  rescue EOFError, Errno::ECONNRESET, IOError
    true
  end

  def ws_frame(text)
    payload = text.b
    mask = SecureRandom.random_bytes(4).bytes
    masked = payload.bytes.each_with_index.map { |byte, i| byte ^ mask[i % 4] }.pack("C*")
    [0x81, 0x80 | payload.bytesize].pack("CC") + mask.pack("C*") + masked
  end
end

RSpec.describe "Built-in server on the wire", :slow do
  before(:all) do
    @server = BuiltinWireProbe.boot(
      "TINA4_MAX_REQUEST_HEADER" => "8192",
      "TINA4_MAX_UPLOAD_SIZE" => "65536",
      "TINA4_REQUEST_TIMEOUT" => "2"
    )
  end

  after(:all) { @server&.destroy! }

  let(:port) { @server.port }

  def roundtrip(request, timeout: 5)
    sock = BuiltinWireProbe.connect(port)
    sock.write(request)
    BuiltinWireProbe.read_response(sock, timeout: timeout)
  ensure
    sock&.close
  end

  def h(response, name)
    BuiltinWireProbe.header(response, name)
  end

  describe "routing basics" do
    it "answers a real GET with 200 and a Content-Length" do
      response = roundtrip("GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      expect(response[:status]).to eq(200)
      expect(JSON.parse(response[:body])).to eq("pong" => true)
      expect(h(response, "content-length").to_i).to eq(response[:body].bytesize)
    end

    it "answers an unknown path with 404" do
      response = roundtrip("GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      expect(response[:status]).to eq(404)
    end

    it "answers a wrong method with 405 and an Allow header" do
      response = roundtrip("DELETE /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      expect(response[:status]).to eq(405)
      expect(h(response, "allow")).to include("GET")
    end

    it "sends HEAD headers with the GET length but no body" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("HEAD /ping HTTP/1.1\r\nHost: x\r\n\r\nGET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      head = BuiltinWireProbe.read_response(sock, head_request: true)
      # The next bytes on the SAME connection must be the GET's status line:
      # any HEAD body would be read here as garbage instead.
      get = BuiltinWireProbe.read_response(sock)
      expect(head[:status]).to eq(200)
      expect(h(head, "content-length").to_i).to eq(get[:body].bytesize)
      expect(get[:status]).to eq(200)
      expect(JSON.parse(get[:body])).to eq("pong" => true)
    ensure
      sock&.close
    end

    it "answers a bare OPTIONS with an Allow header" do
      response = roundtrip("OPTIONS /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      expect([200, 204]).to include(response[:status])
      expect(h(response, "allow")).to include("GET")
    end

    it "decodes PATH_INFO the way the previous built-in server (and PHP) did" do
      response = roundtrip("GET /path/a%20b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      expect(response[:status]).to eq(200)
      expect(JSON.parse(response[:body])["name"]).to eq("a b")
    end

    it "passes the raw socket peer as REMOTE_ADDR, never empty" do
      response = roundtrip("GET /peer HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 6.6.6.6\r\nConnection: close\r\n\r\n")
      payload = JSON.parse(response[:body])
      expect(payload["remote_addr"]).to eq("127.0.0.1")
      expect(payload["remote_ip"]).to eq("127.0.0.1")
    end

    it "serves a body larger than the socket send buffer in full" do
      response = roundtrip("GET /large HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", timeout: 15)
      expect(response[:status]).to eq(200)
      expect(response[:body].bytesize).to eq(3_000_000)
    end
  end

  describe "keep-alive" do
    it "serves several requests on one HTTP/1.1 connection" do
      sock = BuiltinWireProbe.connect(port)
      3.times do
        sock.write("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n")
        response = BuiltinWireProbe.read_response(sock)
        expect(response[:status]).to eq(200)
      end
    ensure
      sock&.close
    end

    it "closes after the response when the client sends Connection: close" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      response = BuiltinWireProbe.read_response(sock)
      expect(h(response, "connection")).to eq("close")
      # Well inside TINA4_REQUEST_TIMEOUT=2, so the idle reaper cannot be what closed it.
      expect(BuiltinWireProbe.closed_by_server?(sock, timeout: 1)).to be(true)
    ensure
      sock&.close
    end

    it "closes an HTTP/1.0 connection that did not ask for keep-alive" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("GET /ping HTTP/1.0\r\n\r\n")
      BuiltinWireProbe.read_response(sock)
      # Well inside TINA4_REQUEST_TIMEOUT=2, so the idle reaper cannot be what closed it.
      expect(BuiltinWireProbe.closed_by_server?(sock, timeout: 1)).to be(true)
    ensure
      sock&.close
    end
  end

  # The ADR-0068 limits (431 / 413 / 400 / 408 and the rejection shape) are
  # the contract runner's: spec/http_hardening_contract_spec.rb. What stays
  # here is the rest of the wire behaviour.
  describe "request limits" do
    it "does not 431 a header block under the limit" do
      response = roundtrip("GET /ping HTTP/1.1\r\nHost: x\r\nX-Big: #{'a' * 4_000}\r\nConnection: close\r\n\r\n")
      expect(response[:status]).to eq(200)
    end

    it "sends 100 Continue before reading an Expect: 100-continue body" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n" \
                 "Expect: 100-continue\r\nConnection: close\r\n\r\n")
      expect(sock.wait_readable(3)).to be_truthy, "no 100 Continue: the server is waiting for the body"
      interim = sock.readpartial(4096)
      expect(interim).to start_with("HTTP/1.1 100 Continue\r\n\r\n")
      sock.write("ping")
      response = BuiltinWireProbe.read_response(sock)
      expect(JSON.parse(response[:body])["body"]).to eq("ping")
    ensure
      sock&.close
    end
  end

  describe "slow-loris (TINA4_REQUEST_TIMEOUT)" do
    it "does not let a client dribbling one header byte at a time hold the slot" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("GET /ping HTTP/1.1\r\nHost: x\r\nX-Slow: ")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      closed = false
      8.times do
        begin
          sock.write("a")
        rescue Errno::EPIPE, Errno::ECONNRESET
          closed = true
          break
        end
        if sock.wait_readable(0.5)
          closed = true
          break
        end
      end
      expect(closed).to be(true), "a byte every 0.5s kept the request alive past TINA4_REQUEST_TIMEOUT=2"
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 4
    ensure
      sock&.close
    end

    it "closes an idle keep-alive connection silently" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n")
      BuiltinWireProbe.read_response(sock)
      expect(sock.wait_readable(6)).to be_truthy
      expect { sock.readpartial(1) }.to raise_error(EOFError)
    ensure
      sock&.close
    end
  end

  describe "malformed heads are refused with 400 Malformed request head" do
    it "rejects a header name that is not a token" do
      response = roundtrip("GET /ping HTTP/1.1\r\nHost: x\r\nBad Name: v\r\n\r\n")
      expect(response[:status]).to eq(400)
      expect(response[:body]).to eq('{"error":"Malformed request head"}')
    end

    it "rejects obsolete line folding" do
      response = roundtrip("GET /ping HTTP/1.1\r\nHost: x\r\nX-A: one\r\n two\r\n\r\n")
      expect(response[:status]).to eq(400)
      expect(response[:body]).to eq('{"error":"Malformed request head"}')
    end

    it "rejects a garbage request line" do
      response = roundtrip("THIS IS NOT HTTP\r\n\r\n")
      expect(response[:status]).to eq(400)
      expect(response[:body]).to eq('{"error":"Malformed request head"}')
    end
  end

  describe "streaming" do
    it "flushes the first SSE event before the stream has finished" do
      sock = BuiltinWireProbe.connect(port)
      sock.write("GET /sse HTTP/1.1\r\nHost: x\r\n\r\n")
      received = +"".b
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
      until received.include?("data: first") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        received << sock.readpartial(4096) if sock.wait_readable(0.1)
      end
      expect(received).to include("text/event-stream")
      expect(received).to include("data: first"), "first event not flushed within 1s: #{received.inspect}"
      expect(received).not_to include("data: second")
      # The rest of the stream, delimited by the server closing the connection.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      begin
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          received << sock.readpartial(4096) if sock.wait_readable(0.2)
        end
      rescue EOFError, IOError
        # end of stream - the server closed it, as a stream of unknown length requires
      end
      expect(received).to end_with("data: second\n\n")
    ensure
      sock&.close
    end
  end

  describe "WebSocket upgrade (rack.hijack)" do
    it "upgrades with 101 and echoes a frame" do
      sock = BuiltinWireProbe.connect(port)
      key = [SecureRandom.random_bytes(16)].pack("m0")
      sock.write("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
      head = +"".b
      head << sock.readpartial(1) until head.end_with?("\r\n\r\n")
      expect(head).to start_with("HTTP/1.1 101")
      accept = [Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")].pack("m0")
      expect(head).to include("Sec-WebSocket-Accept: #{accept}")

      sock.write(BuiltinWireProbe.ws_frame("hello"))
      expect(sock.wait_readable(3)).to be_truthy
      frame = sock.readpartial(4096)
      expect(frame.getbyte(0)).to eq(0x81)
      length = frame.getbyte(1) & 0x7f
      expect(frame.byteslice(2, length)).to eq("echo:hello")
    ensure
      sock&.close
    end
  end

  describe "multipart through the live server" do
    it "parses nested fields, repeated fields and files from real bytes" do
      boundary = "----tina4wire#{SecureRandom.hex(4)}"
      part = lambda do |name, value, filename: nil, type: nil|
        disposition = "Content-Disposition: form-data; name=\"#{name}\""
        disposition += "; filename=\"#{filename}\"" if filename
        headers = [disposition]
        headers << "Content-Type: #{type}" if type
        "--#{boundary}\r\n#{headers.join("\r\n")}\r\n\r\n#{value}\r\n"
      end
      body = part.call("user[name]", "Ada") + part.call("user[role]", "admin") +
             part.call("tags[]", "a") + part.call("tags[]", "b") + part.call("plain", "last") +
             part.call("doc", "file-bytes", filename: "a.txt", type: "text/plain") +
             part.call("empty", "", filename: "", type: "application/octet-stream") +
             "--#{boundary}--\r\n"
      response = roundtrip("POST /form HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" \
                           "Content-Type: multipart/form-data; boundary=#{boundary}\r\n" \
                           "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      expect(response[:status]).to eq(200), response[:body]
      payload = JSON.parse(response[:body])
      expect(payload["fields"]).to eq("user" => { "name" => "Ada", "role" => "admin" },
                                      "tags" => %w[a b], "plain" => "last")
      expect(payload["files"]["doc"]).to eq([{ "filename" => "a.txt", "type" => "text/plain", "content" => "file-bytes" }])
      expect(payload["files"]["empty"]).to eq([{ "filename" => "", "type" => "application/octet-stream", "content" => "" }])
    end
  end
end

RSpec.describe "Built-in server dual port and reload WebSocket", :slow do
  after(:each) { @server&.destroy! }

  def upgrade_status(port, path)
    sock = Socket.tcp("127.0.0.1", port, connect_timeout: 5)
    key = [SecureRandom.random_bytes(16)].pack("m0")
    sock.write("GET #{path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
               "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    return "" unless sock.wait_readable(5)

    sock.readpartial(4096).lines.first.to_s.strip
  ensure
    sock&.close
  end

  it "upgrades /__dev_reload on the main port but refuses it on the AI port" do
    @server = BuiltinWireProbe.boot("TINA4_DEBUG" => "true", "TINA4_NO_AI_PORT" => nil)
    expect(upgrade_status(@server.port, "/__dev_reload")).to start_with("HTTP/1.1 101")
    expect(upgrade_status(@server.port + 1000, "/__dev_reload")).to start_with("HTTP/1.1 404")
  end
end
