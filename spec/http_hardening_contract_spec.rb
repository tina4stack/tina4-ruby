# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# ADR-0068 contract runner (tina4-documentation/plan/v3/fixtures/http_hardening_contract.json).
#
# Two rules, the same in all four frameworks:
#
#   1. A response header name that is not an HTTP token, or a header value,
#      redirect location or cookie name / attribute carrying CR, LF or NUL (and
#      ';' for a cookie attribute), is REFUSED at the call site with the exact
#      ADR message - never stripped. Ruby percent-encodes cookie VALUES, so it
#      keeps encoding them (the ADR's stated exception); names and attributes
#      are refused. The built-in server checks again before writing and answers
#      500 {"error":"Invalid response header"} instead of writing any of it.
#   2. The built-in server enforces TINA4_MAX_REQUEST_HEADER (431),
#      TINA4_MAX_UPLOAD_SIZE on the declared length BEFORE reading and on a
#      running count while reading (413), framing (400) and
#      TINA4_REQUEST_TIMEOUT (408), every rejection in one shape.
#
# NO MOCKS: the response cases use the real Tina4::Response; the server cases
# boot the real Tina4::WebServer as a child process and speak raw bytes over a
# real loopback socket, with resident memory read from the operating system.
# Case names are the fixture's, verbatim.

require "spec_helper"
require "socket"
require_relative "support/shutdown_probe"

module HardeningProbe
  UPLOAD_CAP = 65_536
  HEADER_CAP = 8192

  module_function

  def write_app(dir)
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      #{ShutdownProbe.load_guard}
      PROJECT_DIR = #{dir.inspect}
      Tina4.initialize!(PROJECT_DIR)

      Tina4.get("/ping") { |_request, response| response.json({ pong: true }) }

      Tina4::Router.post("/echo") do |request, response|
        response.json({ bytes: request.body_raw.bytesize, body: request.body_raw })
      end.no_auth

      Tina4.get("/cookies") do |_request, response|
        response.cookie("first", "1")
        response.cookie("second", "2")
        response.json({ ok: true })
      end

      # Appended to the header hash DIRECTLY, bypassing Response#header's
      # call-site check - only the server's writer stands between this and
      # the wire.
      Tina4.get("/direct-append") do |_request, response|
        response.headers["x-evil"] = "safe\\r\\nX-Injected: yes"
        response.json({ ok: true })
      end

      application = Tina4::RackApp.new(root_dir: PROJECT_DIR)
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot
    dir = SpecTmpdir.create("tina4-http-hardening")
    port = ShutdownProbe.free_port
    log_path = File.join(dir, "server.log")
    child_env = ShutdownProbe.base_env(
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_SUPPRESS" => "true", "PROBE_PORT" => port.to_s,
      "TINA4_MAX_UPLOAD_SIZE" => UPLOAD_CAP.to_s, "TINA4_MAX_REQUEST_HEADER" => HEADER_CAP.to_s,
      "TINA4_REQUEST_TIMEOUT" => "2", "TINA4_CSP" => "default-src 'self'"
    )
    pid = spawn(child_env, RbConfig.ruby, write_app(dir),
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/ping")
  end

  # Send raw bytes, read the whole answer until the server closes (every
  # transport rejection closes) or the timeout passes.
  def exchange(port, request, timeout: 5)
    sock = Socket.tcp("127.0.0.1", port, connect_timeout: 5)
    begin
      sock.write(request)
    rescue Errno::EPIPE, Errno::ECONNRESET
      # the server may answer and close before the whole request is written
    end
    read_all(sock, timeout)
  ensure
    sock&.close
  end

  def read_all(sock, timeout)
    raw = +"".b
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || !sock.wait_readable(remaining)

      raw << sock.readpartial(65_536)
    end
    raw
  rescue EOFError, Errno::ECONNRESET
    raw
  end

  def parse(raw)
    head, body = raw.split("\r\n\r\n", 2)
    lines = head.to_s.split("\r\n")
    headers = lines.drop(1).map { |line| line.split(":", 2).map(&:strip) }
    { status: lines.first.to_s.split(" ")[1].to_i, headers: headers, body: body.to_s, head: head.to_s }
  end

  def header(response, name)
    response[:headers].find { |key, _| key.casecmp?(name) }&.last
  end

  def rss_kb(pid)
    Integer(`ps -o rss= -p #{pid}`.strip)
  end
end

RSpec.describe "HTTP hardening contract (ADR-0068)" do
  def refusal(&block)
    expect(&block).to raise_error(ArgumentError)
    begin
      block.call
    rescue ArgumentError => e
      e.message
    end
  end

  # ── response-header-refuses-crlf-nul ─────────────────────────────────────

  describe "call-site refusal" do
    let(:response) { Tina4::Response.new }

    it "a header value containing cr lf or nul is refused" do
      ["a\rb", "a\nb", "a\r\nX-Injected: 1", "a\0b"].each do |value|
        expect(refusal { response.header("X-Test", value) }).to eq('Invalid character in header content ["X-Test"]')
        expect(refusal { response.add_header("X-Test", value) }).to eq('Invalid character in header content ["X-Test"]')
      end
      expect(refusal { response.call("x", 200, "text/html\r\nX-A: 1") })
        .to eq('Invalid character in header content ["Content-Type"]')
      expect(refusal { response.csv("a,b", filename: "x\r\n.csv") })
        .to eq('Invalid character in header content ["Content-Disposition"]')
      expect(response.headers.keys).not_to include("X-Test")
    end

    it "a header name that is not a token is refused" do
      ["Bad Name", "X-A:", "X\r\nY", "", "X-é"].each do |name|
        expect(refusal { response.header(name, "v") })
          .to eq("Header name must be a valid HTTP token [#{JSON.generate(name)}]")
      end
    end

    it "a redirect location containing cr or lf is refused" do
      expect(refusal { response.redirect("/next\r\nSet-Cookie: stolen=1") })
        .to eq('Invalid character in header content ["Location"]')
      expect(refusal { response.redirect("/next\nX: 1") }).to eq('Invalid character in header content ["Location"]')
      expect(response.headers).not_to have_key("location")
    end

    it "normal headers and redirects still work" do
      response.header("X-Trace", "abc; def=1, ghi \t tab")
      response.add_header("X-Other", 42)
      expect(response.headers["X-Trace"]).to eq("abc; def=1, ghi \t tab")
      expect(response.headers["X-Other"]).to eq(42)
      response.redirect("/dashboard?tab=1&x=%20")
      expect(response.headers["location"]).to eq("/dashboard?tab=1&x=%20")
      expect(response.status_code).to eq(302)
    end
  end

  # ── cookie-refuses-injection ─────────────────────────────────────────────

  describe "cookies" do
    let(:response) { Tina4::Response.new }

    it "a cookie name value or attribute that could inject is refused" do
      ["bad name", "a;b", "a\r\nb", "a=b"].each do |name|
        expect(refusal { response.cookie(name, "v") })
          .to eq("Cookie name must be a valid HTTP token [#{JSON.generate(name)}]")
      end
      [{ path: "/;Domain=evil.test" }, { path: "/\r\nX: 1" }, { same_site: "Lax\0" }, { max_age: "1;Secure" }].each do |opts|
        expect(refusal { response.cookie("sid", "v", opts) }).to eq('Invalid character in cookie content ["sid"]')
      end
      # The VALUE is percent-encoded (the ADR's stated exception), so it can
      # never reach the wire raw.
      response.cookie("sid", "a;b\r\nX-Injected: 1")
      line = response.cookies.last
      expect(line).to start_with("sid=a%3Bb%0D%0AX-Injected%3A+1;")
      expect(line).not_to match(/[\r\n\0]/)
    end

    it "multiple set cookie headers all reach the client", :slow do
      server = HardeningProbe.boot
      raw = HardeningProbe.exchange(server.port, "GET /cookies HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      response = HardeningProbe.parse(raw)
      cookies = response[:headers].select { |name, _| name.casecmp?("set-cookie") }.map { |_, value| value.split(";").first }
      expect(cookies).to contain_exactly("first=1", "second=2")
      expect(response[:headers].find { |name, _| name.casecmp?("set-cookie") }.last).to include("HttpOnly")
    ensure
      server&.destroy!
    end
  end

  # ── the built-in server ──────────────────────────────────────────────────

  describe "built-in server", :slow do
    before(:all) { @server = HardeningProbe.boot }
    after(:all) { @server&.destroy! }

    let(:port) { @server.port }

    def request(raw, timeout: 5)
      HardeningProbe.parse(HardeningProbe.exchange(port, raw, timeout: timeout))
    end

    def expect_rejection(response, status, body)
      expect(response[:status]).to eq(status), response[:head]
      expect(response[:body]).to eq(body)
    end

    def upload_body(bytes)
      "{\"error\":\"Request body (#{bytes} bytes) exceeds TINA4_MAX_UPLOAD_SIZE (#{HardeningProbe::UPLOAD_CAP} bytes)\"}"
    end

    # builtin-server-refuses-unsafe-header
    it "the built in server refuses to write an unsafe header" do
      response = request("GET /direct-append HTTP/1.1\r\nHost: x\r\n\r\n")
      expect_rejection(response, 500, '{"error":"Invalid response header"}')
      expect(response[:head]).not_to include("X-Injected")
      expect(response[:head]).not_to include("x-evil")
      expect(@server.log).to match(/Refused to write response header .{0,2}"x-evil.{0,2}"/)
    end

    # builtin-server-body-cap-before-read
    it "a declared content length over the cap is refused before the body is read" do
      sock = Socket.tcp("127.0.0.1", port, connect_timeout: 5)
      sock.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: 70000\r\n\r\n")
      # Not one body byte is sent: the answer must come from the head alone.
      response = HardeningProbe.parse(HardeningProbe.read_all(sock, 3))
      expect_rejection(response, 413, upload_body(70_000))
    ensure
      sock&.close
    end

    it "an oversized declared body does not grow server memory" do
      # Warm the process first so the baseline is a serving server, not a cold one.
      3.times { request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nConnection: close\r\n\r\nwarm") }
      before_kb = HardeningProbe.rss_kb(@server.pid)
      sock = Socket.tcp("127.0.0.1", port, connect_timeout: 5)
      sock.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: 536870912\r\n\r\n")
      chunk = "m" * 1_048_576
      sent = 0
      begin
        32.times do
          sock.write(chunk)
          sent += chunk.bytesize
        end
      rescue Errno::EPIPE, Errno::ECONNRESET
        # refused and closed while we were still sending - the point
      end
      response = HardeningProbe.parse(HardeningProbe.read_all(sock, 4))
      grown_mb = (HardeningProbe.rss_kb(@server.pid) - before_kb) / 1024.0
      expect(response[:status]).to eq(413)
      expect(grown_mb).to be < 16,
                          "RSS grew #{grown_mb.round(1)}MB while a client declared 512MB and sent #{sent / 1_048_576}MB"
    ensure
      sock&.close
    end

    it "a chunked body over the cap is refused as it arrives" do
      sock = Socket.tcp("127.0.0.1", port, connect_timeout: 5)
      sock.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n")
      chunk = "z" * 16_384
      begin
        # Five chunks pass the 64KiB cap; the stream never ends on its own.
        5.times { sock.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n") }
      rescue Errno::EPIPE, Errno::ECONNRESET
        # answered and closed mid-stream
      end
      response = HardeningProbe.parse(HardeningProbe.read_all(sock, 4))
      expect_rejection(response, 413, upload_body(5 * 16_384))
    ensure
      sock&.close
    end

    it "a chunked body under the cap is decoded and served" do
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\n" \
                         "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" \
                         "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n")
      expect(response[:status]).to eq(200)
      expect(JSON.parse(response[:body])).to eq("bytes" => 11, "body" => "hello world")
    end

    it "a body under the cap is still served" do
      body = "b" * (HardeningProbe::UPLOAD_CAP - 1)
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\n" \
                         "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      expect(response[:status]).to eq(200)
      expect(JSON.parse(response[:body])["bytes"]).to eq(body.bytesize)
    end

    # builtin-server-malformed-framing
    it "an invalid content length answers 400" do
      ["abc", "-1", "1.5", "5, 5", ""].each do |value|
        response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: #{value}\r\n\r\nhello")
        expect_rejection(response, 400, '{"error":"Invalid Content-Length"}')
      end
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!")
      expect_rejection(response, 400, '{"error":"Invalid Content-Length"}')
    end

    it "two content length headers answer 400 even when they agree" do
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello")
      expect_rejection(response, 400, '{"error":"Invalid Content-Length"}')
    end

    it "conflicting content length and transfer encoding answer 400" do
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n" \
                         "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
      expect_rejection(response, 400, '{"error":"Invalid Transfer-Encoding"}')
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n")
      expect_rejection(response, 400, '{"error":"Invalid Transfer-Encoding"}')
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
      expect_rejection(response, 400, '{"error":"Invalid Transfer-Encoding"}')
    end

    it "a request head with a bare line feed answers 400" do
      ["GET /ping HTTP/1.1\r\nHost: x\r\nX-A: one\nX-B: two\r\n\r\n",
       "GET /ping HTTP/1.1\r\nHost: x\r\nX-A: one\rX-B: two\r\n\r\n",
       "GET /ping HTTP/1.1\r\nHost: x\r\nX-A: one\0\r\n\r\n",
       "GET /ping HTTP/1.1\nHost: x\r\n\r\n"].each do |raw|
        expect_rejection(request(raw), 400, '{"error":"Malformed request head"}')
      end
    end

    it "an oversized header block answers 431" do
      limit_body = "{\"error\":\"Request header fields exceed TINA4_MAX_REQUEST_HEADER (#{HardeningProbe::HEADER_CAP} bytes)\"}"
      response = request("GET /ping HTTP/1.1\r\nHost: x\r\nX-Big: #{'a' * 10_000}\r\n\r\n")
      expect_rejection(response, 431, limit_body)
      # A head that never ends is refused on what has arrived so far.
      response = request("GET /ping HTTP/1.1\r\nHost: x\r\nX-Endless: #{'a' * 12_000}", timeout: 1.5)
      expect_rejection(response, 431, limit_body)
    end

    it "a stalled partial request answers 408" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = request("GET /ping HTTP/1.1\r\nHost: x\r\n", timeout: 6)
      expect_rejection(response, 408, '{"error":"Request timed out before it was complete"}')
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      # A stalled BODY too.
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc", timeout: 6)
      expect_rejection(response, 408, '{"error":"Request timed out before it was complete"}')
    end

    it "the server keeps serving after every rejection" do
      ["GET /ping HTTP/1.1\r\nHost: x\r\nContent-Length: nope\r\n\r\n",
       "GET /ping HTTP/1.1\r\nHost: x\r\nX-A: a\nb\r\n\r\n",
       "GET /ping HTTP/1.1\r\nHost: x\r\nX-Big: #{'a' * 10_000}\r\n\r\n",
       "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n",
       "GET /direct-append HTTP/1.1\r\nHost: x\r\n\r\n"].each do |raw|
        expect(request(raw)[:status]).to be >= 400
        response = request("GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        expect(response[:status]).to eq(200), "the server stopped serving after #{raw[0, 60].inspect}"
      end
      expect(@server.exited?).to be(false)
    end

    # transport-rejection-shape
    it "a transport rejection carries the json body and security headers" do
      response = request("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n")
      expect(response[:status]).to eq(400)
      h = ->(name) { HardeningProbe.header(response, name) }
      expect(h.call("Content-Type")).to eq("application/json")
      expect(h.call("Content-Length")).to eq(response[:body].bytesize.to_s)
      expect(h.call("Connection")).to eq("close")
      expect(h.call("X-Frame-Options")).to eq("SAMEORIGIN")
      expect(h.call("X-Content-Type-Options")).to eq("nosniff")
      expect(h.call("Content-Security-Policy")).to eq("default-src 'self'")
      expect(h.call("Referrer-Policy")).to eq("strict-origin-when-cross-origin")
      expect(h.call("X-XSS-Protection")).to eq("0")
      expect(h.call("Permissions-Policy")).to eq("camera=(), microphone=(), geolocation=()")
      expect(h.call("Strict-Transport-Security")).to be_nil
    end
  end
end
