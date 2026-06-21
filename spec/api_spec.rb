# frozen_string_literal: true

require "spec_helper"
require "socket"

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
  # We capture the Net::HTTP instance the client builds and inspect the
  # verify_mode it configures. Positive AND negative: verify_ssl: false must
  # set VERIFY_NONE; the default (and explicit true) must leave VERIFY_PEER.
  describe "verify_ssl handling" do
    # Build a fake Net::HTTP that records verify_mode and short-circuits the
    # actual network call with a canned 200 so #execute returns cleanly.
    def stub_https_and_capture(api)
      captured = nil
      fake_http = instance_double(Net::HTTP)
      allow(fake_http).to receive(:use_ssl=)
      allow(fake_http).to receive(:open_timeout=)
      allow(fake_http).to receive(:read_timeout=)
      allow(fake_http).to receive(:verify_mode=) { |mode| captured = mode }
      fake_response = instance_double(Net::HTTPResponse, code: "200", body: "{}", to_hash: {})
      allow(fake_http).to receive(:request).and_return(fake_response)
      allow(Net::HTTP).to receive(:new).and_return(fake_http)
      api.get("/")
      captured
    end

    it "sets verify_mode to VERIFY_NONE when verify_ssl: false (positive)" do
      api = Tina4::API.new("https://self-signed.local", verify_ssl: false)
      expect(stub_https_and_capture(api)).to eq(OpenSSL::SSL::VERIFY_NONE)
    end

    it "does NOT touch verify_mode by default (keeps the secure VERIFY_PEER default)" do
      api = Tina4::API.new("https://api.example.com")
      # nil verify_ssl => verify_mode= is never called => stays the Net::HTTP default
      expect(stub_https_and_capture(api)).to be_nil
    end

    it "does NOT disable verification when verify_ssl: true (negative)" do
      api = Tina4::API.new("https://api.example.com", verify_ssl: true)
      expect(stub_https_and_capture(api)).to be_nil
    end

    it "leaves a real https Net::HTTP object at the secure default by default" do
      # End-to-end on the configured object: build a real Net::HTTP via the
      # client's seam and confirm the client never forces VERIFY_NONE when
      # verify_ssl is unset (Net::HTTP applies its secure VERIFY_PEER default
      # lazily on connect, so verify_mode is nil until then — the contract is
      # simply that we did NOT downgrade it).
      api = Tina4::API.new("https://api.example.com")
      built = nil
      allow(Net::HTTP).to receive(:new).and_wrap_original do |orig, *args|
        built = orig.call(*args)
        # Avoid a real network hop — raise so #attempt_request returns status 0.
        allow(built).to receive(:request).and_raise(StandardError, "no network")
        built
      end
      api.get("/")
      expect(built.use_ssl?).to be true
      expect(built.verify_mode).not_to eq(OpenSSL::SSL::VERIFY_NONE)
    end

    it "configures VERIFY_NONE on a real https Net::HTTP object when verify_ssl: false" do
      api = Tina4::API.new("https://api.example.com", verify_ssl: false)
      built = nil
      allow(Net::HTTP).to receive(:new).and_wrap_original do |orig, *args|
        built = orig.call(*args)
        allow(built).to receive(:request).and_raise(StandardError, "no network")
        built
      end
      api.get("/")
      expect(built.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
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
      # First "server" is dead (connection refused -> status 0), so we point the
      # client at a port nobody is listening on, then bring a real server up on a
      # second client call. Simpler: script the seam to error once, then 200.
      api = Tina4::API.new("http://127.0.0.1:1", max_retries: 2, retry_backoff: 0.01)
      good = Tina4::APIResponse.new(status: 200, body: "{}", headers: {})
      bad  = Tina4::APIResponse.new(status: 0, body: "", headers: {}, error: "refused")
      call = 0
      allow(api).to receive(:attempt_request) do
        call += 1
        call == 1 ? bad : good
      end
      resp = api.get("/")
      expect(resp.status).to eq(200)
      expect(call).to eq(2)
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
      slept = []
      with_server([503, 503, 200]) do |server|
        api = Tina4::API.new("http://127.0.0.1:#{server.port}",
                             max_retries: 3, retry_backoff: 0.01)
        allow(api).to receive(:sleep) { |n| slept << n }
        resp = api.get("/")
        expect(resp.status).to eq(200)
      end
      # attempt 0 -> 0.01 * 2**0, attempt 1 -> 0.01 * 2**1
      expect(slept).to eq([0.01, 0.02])
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
