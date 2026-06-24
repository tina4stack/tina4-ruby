# frozen_string_literal: true

require "spec_helper"
require "socket"
require "openssl"

RSpec.describe Tina4::API do
  describe "#initialize" do
    it "stores base URL and default headers" do
      api = Tina4::API.new("https://api.example.com")
      expect(api.base_url).to eq("https://api.example.com")
      expect(api.headers).to include("Content-Type" => "application/json")
      expect(api.headers).to include("Accept" => "application/json")
    end

    it "strips trailing slash from base URL" do
      api = Tina4::API.new("https://api.example.com/")
      expect(api.base_url).to eq("https://api.example.com")
    end

    it "merges custom headers over the defaults" do
      api = Tina4::API.new("https://api.example.com", headers: { "X-Custom" => "value" })
      expect(api.headers["X-Custom"]).to eq("value")
      expect(api.headers["Content-Type"]).to eq("application/json")
    end

    it "lets custom headers override a default header" do
      api = Tina4::API.new("https://api.example.com", headers: { "Accept" => "text/plain" })
      expect(api.headers["Accept"]).to eq("text/plain")
    end

    it "applies a bearer token kwarg as an Authorization header" do
      api = Tina4::API.new("https://api.example.com", bearer_token: "sk-abc")
      expect(api.headers["Authorization"]).to eq("Bearer sk-abc")
    end

    it "applies username/password kwargs as a basic-auth header" do
      api = Tina4::API.new("https://api.example.com", username: "u", password: "p")
      expected = "Basic #{Base64.strict_encode64('u:p')}"
      expect(api.headers["Authorization"]).to eq(expected)
    end

    it "prefers a bearer token over basic auth when both are passed" do
      api = Tina4::API.new("https://api.example.com",
                           bearer_token: "sk-abc", username: "u", password: "p")
      expect(api.headers["Authorization"]).to eq("Bearer sk-abc")
    end

    it "sets no Authorization header when no auth kwargs are passed" do
      api = Tina4::API.new("https://api.example.com")
      expect(api.headers).not_to have_key("Authorization")
    end
  end

  describe "auth setters" do
    it "set_bearer_token sets the header and returns self (fluent)" do
      api = Tina4::API.new("https://api.example.com")
      expect(api.set_bearer_token("tok")).to equal(api)
      expect(api.headers["Authorization"]).to eq("Bearer tok")
    end

    it "set_basic_auth sets the header and returns self (fluent)" do
      api = Tina4::API.new("https://api.example.com")
      expect(api.set_basic_auth("u", "p")).to equal(api)
      expect(api.headers["Authorization"]).to eq("Basic #{Base64.strict_encode64('u:p')}")
    end

    it "add_headers merges in new headers and returns self (fluent)" do
      api = Tina4::API.new("https://api.example.com")
      expect(api.add_headers("X-Tenant" => "acme")).to equal(api)
      expect(api.headers["X-Tenant"]).to eq("acme")
    end
  end

  # ── verify_ssl proof (the 3.13.39 dead-kwarg fix) ───────────────────────
  #
  # Driven against a REAL self-signed HTTPS loopback server (a TCPServer
  # wrapped in OpenSSL::SSL::SSLServer, bound to 127.0.0.1 on an ephemeral
  # port — see TlsLoopbackServer below). This is the real TLS round-trip
  # proof of the kwarg, NOT a Net::HTTP double:
  #
  #   - verify_ssl: false  => verification is disabled, the TLS handshake to a
  #     self-signed cert SUCCEEDS, the client gets a real 200 over the socket.
  #   - default / verify_ssl: true => the secure VERIFY_PEER default is kept,
  #     so the handshake to a self-signed cert FAILS with "certificate verify
  #     failed" and #attempt_request returns the status-0 transport-error
  #     sentinel (error message preserved).
  #
  # A single real socket exercise proves both the positive (kwarg works) and
  # the negative (we never silently downgrade) far more strongly than the old
  # instance_double-on-verify_mode= probe could.
  describe "verify_ssl handling" do
    # Real in-process HTTPS server with a self-signed certificate. Accepts a
    # genuine TLS connection on 127.0.0.1 and returns a canned 200. Connecting
    # to it with peer verification ON fails the handshake (self-signed); with
    # verification OFF it succeeds — exactly the contract under test.
    class TlsLoopbackServer
      attr_reader :port

      def initialize
        @tcp = TCPServer.new("127.0.0.1", 0)
        @port = @tcp.addr[1]
        @ctx = build_ssl_context
        @ssl_server = OpenSSL::SSL::SSLServer.new(@tcp, @ctx)
        @running = true
        @thread = Thread.new { serve_loop }
      end

      def stop
        @running = false
        begin
          @ssl_server.close unless @tcp.closed?
        rescue StandardError
          nil
        end
        @thread.join(1) if @thread&.alive?
        @thread.kill if @thread&.alive?
      end

      private

      def build_ssl_context
        key = OpenSSL::PKey::RSA.new(2048)
        name = OpenSSL::X509::Name.parse("CN=localhost")
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = name
        cert.issuer = name
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate = cert
        cert.add_extension(ef.create_extension("subjectAltName", "IP:127.0.0.1,DNS:localhost", false))
        cert.sign(key, OpenSSL::Digest::SHA256.new)

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.cert = cert
        ctx.key = key
        ctx
      end

      def serve_loop
        while @running
          conn = begin
            @ssl_server.accept
          rescue StandardError
            # A failed handshake (peer verification rejecting our self-signed
            # cert) raises here — that is the negative path under test, not a
            # server fault. Keep accepting.
            nil
          end
          next if conn.nil?

          handle(conn)
        end
      end

      def handle(conn)
        while (line = conn.gets)
          break if line == "\r\n"
        end
        body = "{}"
        conn.write(
          "HTTP/1.1 200 OK\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n" \
          "\r\n#{body}"
        )
      rescue StandardError
        nil
      ensure
        begin
          conn.close
        rescue StandardError
          nil
        end
      end
    end

    around(:each) do |example|
      @tls_server = TlsLoopbackServer.new
      @tls_base = "https://127.0.0.1:#{@tls_server.port}"
      begin
        example.run
      ensure
        @tls_server.stop
      end
    end

    it "completes the TLS round-trip to a self-signed server when verify_ssl: false (positive)" do
      api = Tina4::API.new(@tls_base, verify_ssl: false)
      resp = api.get("/")
      # Verification disabled => the handshake succeeds and we get a real 200.
      expect(resp.status).to eq(200)
      expect(resp.error).to be_nil
    end

    it "keeps the secure VERIFY_PEER default by default (rejects the self-signed cert)" do
      api = Tina4::API.new(@tls_base)
      resp = api.get("/")
      # Secure default kept => the self-signed handshake fails => status-0
      # transport sentinel with the real verification error preserved.
      expect(resp.status).to eq(0)
      expect(resp.error).to match(/certificate verify failed/i)
    end

    it "does NOT disable verification when verify_ssl: true (negative)" do
      api = Tina4::API.new(@tls_base, verify_ssl: true)
      resp = api.get("/")
      expect(resp.status).to eq(0)
      expect(resp.error).to match(/certificate verify failed/i)
    end
  end

  # ── opt-in retry / backoff (3.13.39) ────────────────────────────────────
  #
  # A tiny local TCP server scripts HTTP responses (503 for the first N hits,
  # then 200) and counts the hits it actually received. retry_backoff is kept
  # tiny so the suite stays fast.
  describe "retry / backoff" do
    # Scriptable single-thread HTTP stub. `statuses` is the sequence of status
    # codes to return; after the list is exhausted it keeps returning the last.
    class ScriptedServer
      attr_reader :hits

      def initialize(statuses)
        @statuses = statuses
        @hits = 0
        @server = TCPServer.new("127.0.0.1", 0)
        @thread = Thread.new { serve_loop }
      end

      def port
        @server.addr[1]
      end

      def stop
        @running = false
        @thread.kill if @thread&.alive?
        @server.close unless @server.closed?
      end

      private

      def serve_loop
        @running = true
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
        # Drain the request line + headers (no body for these GETs).
        while (line = client.gets)
          break if line == "\r\n"
        end
        idx = [@hits, @statuses.length - 1].min
        status = @statuses[idx]
        @hits += 1
        # A `:close` entry drops the connection WITHOUT writing a response —
        # a real transport error (the client sees a premature EOF on a real
        # socket and #attempt_request returns its status-0 sentinel). This is
        # how we reproduce a transport failure for real instead of scripting a
        # seam, then recover on the next (200) entry.
        if status == :close
          client.close
          return
        end
        body = %({"hit":#{@hits}})
        client.write(
          "HTTP/1.1 #{status} X\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n" \
          "\r\n#{body}"
        )
        client.close
      rescue StandardError
        client.close rescue nil
      end
    end

    def with_server(statuses)
      server = ScriptedServer.new(statuses)
      begin
        yield server
      ensure
        server.stop
      end
    end

    it "makes exactly ONE attempt by default (max_retries: 0) even on a 503" do
      with_server([503]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}")
        resp = api.get("/")
        expect(resp.status).to eq(503)
        expect(server.hits).to eq(1)
      end
    end

    it "retries a 503 then recovers on a 200 (2 attempts)" do
      with_server([503, 200]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 3, retry_backoff: 0.01)
        resp = api.get("/")
        expect(resp.status).to eq(200)
        expect(server.hits).to eq(2)
      end
    end

    it "recovers after a transport error then a 200" do
      # The real loopback server drops the FIRST connection without a response
      # (a genuine transport error over the socket -> status 0), then serves a
      # real 200 on the retry. No seam stubbing — the recovery is driven end to
      # end through Net::HTTP against a real server.
      with_server([:close, 200]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 2, retry_backoff: 0.01)
        resp = api.get("/")
        expect(resp.status).to eq(200)
        expect(server.hits).to eq(2)
      end
    end

    it "exhausts retries and returns the last 503" do
      with_server([503]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 2, retry_backoff: 0.01)
        resp = api.get("/")
        expect(resp.status).to eq(503)
        # 1 initial + 2 retries = 3 attempts
        expect(server.hits).to eq(3)
      end
    end

    it "does NOT retry a non-retryable status (404)" do
      with_server([404, 200]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 3, retry_backoff: 0.01)
        resp = api.get("/")
        expect(resp.status).to eq(404)
        expect(server.hits).to eq(1)
      end
    end

    it "does NOT retry a successful 200 (single attempt)" do
      with_server([200]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 3, retry_backoff: 0.01)
        resp = api.get("/")
        expect(resp.status).to eq(200)
        expect(server.hits).to eq(1)
      end
    end

    it "clamps a negative max_retries to 0 (one attempt)" do
      with_server([503]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: -5, retry_backoff: 0.01)
        resp = api.get("/")
        expect(resp.status).to eq(503)
        expect(server.hits).to eq(1)
      end
    end

    it "sleeps with exponential backoff between attempts" do
      # Two 503s force two real backoff sleeps before the recovering 200.
      # We measure REAL elapsed wall-clock time against a real server rather
      # than stubbing sleep: attempt 0 backoff = base * 2**0, attempt 1 backoff
      # = base * 2**1, so the run must take at least base * (1 + 2) of real
      # sleeping. A larger base keeps the lower bound comfortably above timing
      # jitter while staying fast (0.15s total).
      base = 0.05
      elapsed = nil
      with_server([503, 503, 200]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 3, retry_backoff: base)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        resp = api.get("/")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(resp.status).to eq(200)
        expect(server.hits).to eq(3)
      end
      # Exponential backoff: base * 2**0 + base * 2**1 = base * 3 of real sleep.
      expect(elapsed).to be >= base * 3
    end
  end
end

RSpec.describe Tina4::APIResponse do
  describe "#success?" do
    it "returns true for 2xx status" do
      resp = Tina4::APIResponse.new(status: 200, body: "{}", headers: {})
      expect(resp.success?).to be true
    end

    it "returns true for 201 status" do
      resp = Tina4::APIResponse.new(status: 201, body: "{}", headers: {})
      expect(resp.success?).to be true
    end

    it "returns false for 4xx status" do
      resp = Tina4::APIResponse.new(status: 404, body: "", headers: {})
      expect(resp.success?).to be false
    end

    it "returns false for 0 status (connection error)" do
      resp = Tina4::APIResponse.new(status: 0, body: "", headers: {}, error: "Connection refused")
      expect(resp.success?).to be false
    end
  end

  describe "#json" do
    it "parses JSON body" do
      resp = Tina4::APIResponse.new(status: 200, body: '{"key":"value"}', headers: {})
      expect(resp.json).to eq({ "key" => "value" })
    end

    it "returns empty hash for invalid JSON" do
      resp = Tina4::APIResponse.new(status: 200, body: "not json", headers: {})
      expect(resp.json).to eq({})
    end
  end

  describe "#to_s" do
    it "returns a string representation" do
      resp = Tina4::APIResponse.new(status: 200, body: "", headers: {})
      expect(resp.to_s).to eq("APIResponse(status=200)")
    end
  end
end
