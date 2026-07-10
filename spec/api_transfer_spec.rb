# frozen_string_literal: true

# Real, no-mock tests for the Tina4::API transfer features (v3):
#   - multipart upload()  (from disk AND in-memory bytes)
#   - streaming download()
#   - the injectable transport seam
#   - the opt-in cookie jar
#   - the cross-origin Authorization/Cookie strip on redirects (regression)
#
# Every test drives a REAL loopback TCP server (raw TCPServer bound to
# 127.0.0.1:0, same technique as spec/api_spec.rb) and makes REAL socket
# round-trips. Nothing is mocked, stubbed, or faked: the server records exactly
# what it received off the wire so the assertions are on real bytes, not on
# "was a method called".
#
# The transport-seam test deliberately injects a REAL alternate transport (a raw
# TCPSocket HTTP client — a genuinely different code path from Net::HTTP) that
# performs a real round-trip to the local server. Never a canned/fake transport,
# so the framework suite stays free of mocks per the no-mock rule. The
# canned-fake pattern is for APPLICATION code, not here.

require "spec_helper"
require "socket"
require "tmpdir"
require "uri"

# ──────────────────────────────────────────────────────────────────────────
# Local recording server. Records method, path, headers and the raw body of
# every request; serves scripted responses (default 200 {"ok":true}). One
# request per connection (Connection: close), matching spec/api_spec.rb.
# ──────────────────────────────────────────────────────────────────────────
class RecordingServer
  attr_reader :requests, :routes

  def initialize
    @routes = {}
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @running = true
    @thread = Thread.new { serve_loop }
  end

  def port
    @server.addr[1]
  end

  def base_url
    "http://127.0.0.1:#{port}"
  end

  # Register a scripted response: route(method, path) => [status, headers, body]
  def route(method, path, status, headers, body)
    @routes[[method, path]] = [status, headers, body]
  end

  def stop
    @running = false
    begin
      @server.close unless @server.closed?
    rescue StandardError
      nil
    end
    @thread.join(1) if @thread&.alive?
    @thread.kill if @thread&.alive?
  end

  private

  def serve_loop
    while @running
      client = begin
        @server.accept
      rescue StandardError
        nil
      end
      break if client.nil?

      handle(client)
    end
  end

  def handle(client)
    request_line = client.gets
    return if request_line.nil?

    method, path, = request_line.split(" ")
    headers = {}
    while (line = client.gets)
      break if line == "\r\n" || line == "\n"

      key, _sep, value = line.partition(":")
      headers[key.strip.downcase] = value.strip
    end

    length = (headers["content-length"] || "0").to_i
    body = length.positive? ? client.read(length) : "".b

    @requests << {
      method: method,
      path: path,
      content_type: headers["content-type"],
      headers: headers,
      body: body
    }

    status, resp_headers, payload = @routes.fetch(
      [method, path.split("?", 2).first],
      [200, { "Content-Type" => "application/json" }, %({"ok":true})]
    )
    payload = payload.to_s

    out = +"HTTP/1.1 #{status} X\r\n"
    (resp_headers || {}).each { |key, value| out << "#{key}: #{value}\r\n" }
    out << "Content-Length: #{payload.bytesize}\r\n"
    out << "Connection: close\r\n\r\n"
    client.write(out.b)
    client.write(payload.b) unless payload.empty?
  rescue StandardError
    nil
  ensure
    begin
      client.close
    rescue StandardError
      nil
    end
  end
end

# A small, explicit multipart/form-data parser so the test can assert the EXACT
# bytes and fields the server received. Mirrors the hand-rolled parser in the
# Python suite (tests/test_api_transfer.py) so parity is provable.
module MultipartHelpers
  module_function

  def disposition_param(disposition, key)
    token = %(#{key}=")
    start = disposition.index(token)
    return nil if start.nil?

    start += token.length
    finish = disposition.index('"', start)
    disposition[start...finish]
  end

  def parse_multipart(content_type, body)
    boundary = content_type.split("boundary=", 2)[1].strip
    marker = "--#{boundary}".b
    fields = {}
    files = {}

    body.split(marker).each do |segment|
      next if ["", "\r\n", "--", "--\r\n"].include?(segment)

      seg = segment.dup
      seg = seg[2..] if seg.start_with?("\r\n")
      seg = seg[0..-3] if seg.end_with?("\r\n")
      header_blob, separator, content = seg.partition("\r\n\r\n")
      next if separator.empty?

      headers = {}
      header_blob.split("\r\n").each do |line|
        next unless line.include?(":")

        key, _sep, value = line.partition(":")
        headers[key.strip.downcase] = value.strip
      end

      disposition = headers["content-disposition"] || ""
      name = disposition_param(disposition, "name")
      filename = disposition_param(disposition, "filename")
      if filename
        files[name] = { filename: filename, content: content, content_type: headers["content-type"] }
      else
        fields[name] = content
      end
    end

    [fields, files]
  end
end

RSpec.describe "Tina4::API transfer features" do
  around(:each) do |example|
    @server = RecordingServer.new
    begin
      example.run
    ensure
      @server.stop
    end
  end

  # ── upload() — multipart/form-data, from disk and from in-memory bytes ────
  describe "#upload" do
    it "sends exact bytes and fields for a file on disk" do
      payload = (0..255).to_a.pack("C*") * 4   # 1 KB of every byte value (incl. CRLF, NUL, 0xFF)
      @server.route("POST", "/files", 201, { "Content-Type" => "application/json" }, %({"stored":true}))

      Dir.mktmpdir do |dir|
        src = File.join(dir, "report.bin")
        File.binwrite(src, payload)

        api = Tina4::API.new(@server.base_url)
        result = api.upload("/files", file_path: src,
                            extra_fields: { "user_id" => "42", "kind" => "report" })

        expect(result.status).to eq(201)
        expect(result.json).to eq({ "stored" => true })
        expect(result.error).to be_nil

        rec = @server.requests.last
        expect(rec[:method]).to eq("POST")
        expect(rec[:content_type]).to start_with("multipart/form-data; boundary=----Tina4Boundary")
        fields, files = MultipartHelpers.parse_multipart(rec[:content_type], rec[:body])
        expect(fields).to eq({ "user_id" => "42", "kind" => "report" })
        expect(files["file"][:content]).to eq(payload)          # exact bytes on the wire
        expect(files["file"][:filename]).to eq("report.bin")
      end
    end

    it "sends an in-memory bytes payload and guesses the part Content-Type from the filename" do
      payload = "in-memory-\x89PNG-ish-\x00\xFFdata".b
      api = Tina4::API.new(@server.base_url)
      result = api.upload("/files", file_bytes: payload, filename: "avatar.png",
                          field_name: "avatar", extra_fields: { "scope" => "profile" })

      expect(result.status).to eq(200)
      rec = @server.requests.last
      fields, files = MultipartHelpers.parse_multipart(rec[:content_type], rec[:body])
      expect(fields).to eq({ "scope" => "profile" })
      expect(files["avatar"][:content]).to eq(payload)
      expect(files["avatar"][:filename]).to eq("avatar.png")
      # THE FIX: Content-Type is now GUESSED (was hard-coded application/octet-stream).
      expect(files["avatar"][:content_type]).to eq("image/png")
    end

    it "falls back to application/octet-stream for an unknown extension" do
      api = Tina4::API.new(@server.base_url)
      api.upload("/files", file_bytes: "data", filename: "blob.unknownext")
      rec = @server.requests.last
      _fields, files = MultipartHelpers.parse_multipart(rec[:content_type], rec[:body])
      expect(files["file"][:content_type]).to eq("application/octet-stream")
    end

    it "sends a per-call header on the upload request" do
      api = Tina4::API.new(@server.base_url)
      api.upload("/files", file_bytes: "x", filename: "x.txt",
                 headers: { "X-Upload-Token" => "abc" })
      rec = @server.requests.last
      expect(rec[:headers]["x-upload-token"]).to eq("abc")
    end

    it "sends the client Authorization header on the upload (parity fix vs the old upload)" do
      api = Tina4::API.new(@server.base_url, bearer_token: "sk-live")
      api.upload("/files", file_bytes: "x", filename: "x.txt")
      rec = @server.requests.last
      expect(rec[:headers]["authorization"]).to eq("Bearer sk-live")
    end

    # ── negative cases ──────────────────────────────────────────────────
    it "returns a clean error and sends nothing when the file is missing" do
      Dir.mktmpdir do |dir|
        api = Tina4::API.new(@server.base_url)
        result = api.upload("/files", file_path: File.join(dir, "does-not-exist.bin"))
        expect(result.status).to eq(0)
        expect(result.error).to include("not found")
        expect(@server.requests).to be_empty          # nothing was ever sent
      end
    end

    it "returns a clean error and sends nothing when no source is given" do
      api = Tina4::API.new(@server.base_url)
      result = api.upload("/files")
      expect(result.status).to eq(0)
      expect(result.error).not_to be_nil
      expect(@server.requests).to be_empty
    end
  end

  # ── download() — chunked streaming to a destination file ──────────────────
  describe "#download" do
    it "streams a multi-MB body to disk byte-for-byte with no in-memory body" do
      big = SecureRandom.random_bytes((3 * 1024 * 1024) + 777)   # 3 MB + change (not chunk-aligned)
      @server.route("GET", "/blob", 200, { "Content-Type" => "application/octet-stream" }, big)

      Dir.mktmpdir do |dir|
        dest = File.join(dir, "downloaded.bin")
        api = Tina4::API.new(@server.base_url)
        result = api.download("/blob", dest_path: dest)

        expect(result.status).to eq(200)
        expect(result.error).to be_nil
        expect(result.path).to eq(dest)
        expect(result.body).to be_nil                # body went to disk, not memory
        expect(File.binread(dest)).to eq(big)        # exact bytes
        expect(File.size(dest)).to eq(big.bytesize)
      end
    end

    it "appends a query string from params" do
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "q.json")
        api = Tina4::API.new(@server.base_url)
        api.download("/data", dest_path: dest, params: { "format" => "raw" })
        rec = @server.requests.last
        expect(rec[:path]).to start_with("/data?")
        expect(rec[:path]).to include("format=raw")
      end
    end

    # ── negative cases ──────────────────────────────────────────────────
    it "returns an error when dest_path is missing (nothing streamed)" do
      api = Tina4::API.new(@server.base_url)
      result = api.download("/blob")
      expect(result.path).to be_nil
      expect(result.error).not_to be_nil
      expect(result.status).to eq(0)
      expect(@server.requests).to be_empty
    end

    it "writes no file on an HTTP error status" do
      @server.route("GET", "/missing", 404, { "Content-Type" => "application/json" }, %({"error":"nope"}))
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "should-not-exist.bin")
        api = Tina4::API.new(@server.base_url)
        result = api.download("/missing", dest_path: dest)
        expect(result.status).to eq(404)
        expect(result.path).to be_nil
        expect(result.error).not_to be_nil
        expect(File.exist?(dest)).to be(false)       # no partial/garbage file on error
      end
    end

    it "returns an error on a transport failure (connection refused, no mock)" do
      Dir.mktmpdir do |dir|
        api = Tina4::API.new("http://127.0.0.1:1", timeout: 2)
        result = api.download("/blob", dest_path: File.join(dir, "x.bin"))
        expect(result.status).to eq(0)
        expect(result.path).to be_nil
        expect(result.error).not_to be_nil
      end
    end
  end

  # ── Transport seam — REAL alternate transport (raw TCPSocket), no mock ────
  describe "transport seam" do
    it "uses an injected real transport in place of the default Net::HTTP path" do
      @server.route("GET", "/seam", 200, { "Content-Type" => "application/json" }, %({"via":"transport"}))
      calls = []

      # A genuine network client through a DIFFERENT code path (raw TCPSocket),
      # proving the seam replaces the built-in Net::HTTP path. No canned data —
      # it really talks to the local server over a socket.
      real_transport = lambda do |method, url, headers, body, _timeout|
        calls << [method, url]
        uri = URI.parse(url)
        socket = TCPSocket.new(uri.host, uri.port)
        socket.write("#{method} #{uri.request_uri} HTTP/1.1\r\n")
        socket.write("Host: #{uri.host}:#{uri.port}\r\n")
        socket.write("Connection: close\r\n")
        headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
        if body
          socket.write("Content-Length: #{body.bytesize}\r\n")
          socket.write("\r\n")
          socket.write(body)
        else
          socket.write("\r\n")
        end
        raw = socket.read
        socket.close
        _head, _sep, resp_body = raw.partition("\r\n\r\n")
        code = raw.lines.first.split(" ")[1].to_i
        { http_code: code, body: resp_body, headers: {}, error: nil }
      end

      api = Tina4::API.new(@server.base_url, transport: real_transport)
      result = api.get("/seam")

      expect(calls).not_to be_empty                       # the seam was used
      expect(calls.first.first).to eq("GET")
      expect(result.status).to eq(200)
      expect(result.json).to eq({ "via" => "transport" }) # its result flows out
      expect(@server.requests.last[:path]).to eq("/seam") # the server really got hit
    end

    it "defaults transport to nil and uses the real network path" do
      api = Tina4::API.new(@server.base_url)
      expect(api.instance_variable_get(:@transport)).to be_nil
      result = api.get("/anything")
      expect(result.status).to eq(200)
      expect(@server.requests.last[:path]).to eq("/anything")
    end

    it "rejects a non-callable transport at construction" do
      expect { Tina4::API.new(@server.base_url, transport: "not-callable") }
        .to raise_error(ArgumentError)
    end
  end

  # ── Cookie jar — opt-in (off by default), in-memory, per-client ───────────
  describe "cookie jar" do
    it "captures Set-Cookie and sends it on the next request" do
      @server.route("GET", "/login", 200,
                     { "Set-Cookie" => "session=abc123; Path=/; HttpOnly" }, "ok")

      api = Tina4::API.new(@server.base_url, cookies: true)
      api.get("/login")           # response sets the cookie
      api.get("/dashboard")       # next request must carry it

      rec = @server.requests.last
      expect(rec[:path]).to eq("/dashboard")
      expect(rec[:headers]["cookie"]).to eq("session=abc123")
    end

    it "accumulates cookies across responses" do
      @server.route("GET", "/login", 200, { "Set-Cookie" => "session=abc123; Path=/" }, "ok")
      @server.route("GET", "/prefs", 200, { "Set-Cookie" => "theme=dark; Path=/" }, "ok")

      api = Tina4::API.new(@server.base_url, cookies: true)
      api.get("/login")
      api.get("/prefs")
      api.get("/account")

      cookie = @server.requests.last[:headers]["cookie"]
      expect(cookie).to include("session=abc123")
      expect(cookie).to include("theme=dark")
    end

    # ── negative: off by default ────────────────────────────────────────
    it "sends no Cookie header when the jar is off (default)" do
      @server.route("GET", "/login", 200, { "Set-Cookie" => "session=abc123; Path=/" }, "ok")

      api = Tina4::API.new(@server.base_url)   # cookies default false
      api.get("/login")
      api.get("/dashboard")

      rec = @server.requests.last
      expect(rec[:headers]).not_to have_key("cookie")
    end
  end

  # ── Redirect security regression — cross-origin Authorization/Cookie strip ─
  describe "redirect following + cross-origin auth strip" do
    it "strips Authorization AND Cookie on a cross-origin redirect" do
      target = RecordingServer.new
      begin
        location = "#{target.base_url}/steal"
        @server.route("GET", "/setcookie", 200,
                      { "Set-Cookie" => "session=SECRET-SESSION; Path=/" }, "ok")
        @server.route("GET", "/login", 302, { "Location" => location }, "")

        api = Tina4::API.new(@server.base_url, cookies: true)
        api.set_bearer_token("SECRET-TOKEN")
        api.get("/setcookie")                # seed the jar for real (same origin)
        result = api.get("/login")           # 302 -> cross-origin target

        expect(result.status).to eq(200)
        target_rec = target.requests.last
        expect(target_rec[:path]).to eq("/steal")
        expect(target_rec[:headers]).not_to have_key("authorization")  # bearer NOT leaked cross-origin
        expect(target_rec[:headers]).not_to have_key("cookie")         # cookie NOT leaked cross-origin

        # ...and the first hop (same origin) DID carry them, proving the strip is
        # cross-origin-only, not a blanket drop.
        login_rec = @server.requests.find { |r| r[:path] == "/login" }
        expect(login_rec[:headers]["authorization"]).to eq("Bearer SECRET-TOKEN")
        expect(login_rec[:headers]["cookie"]).to eq("session=SECRET-SESSION")
      ensure
        target.stop
      end
    end

    it "keeps Authorization AND Cookie on a same-origin redirect" do
      @server.route("GET", "/setcookie", 200,
                    { "Set-Cookie" => "session=KEEP-ME; Path=/" }, "ok")
      @server.route("GET", "/login", 302, { "Location" => "/dashboard" }, "")

      api = Tina4::API.new(@server.base_url, cookies: true)
      api.set_bearer_token("SECRET-TOKEN")
      api.get("/setcookie")
      result = api.get("/login")             # 302 -> /dashboard (same origin)

      expect(result.status).to eq(200)
      dash_rec = @server.requests.last
      expect(dash_rec[:path]).to eq("/dashboard")
      expect(dash_rec[:headers]["authorization"]).to eq("Bearer SECRET-TOKEN")
      expect(dash_rec[:headers]["cookie"]).to eq("session=KEEP-ME")
    end
  end
end
