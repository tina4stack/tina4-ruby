# frozen_string_literal: true

# Locks in the 503-retry in Tina4::AI.fetch_bytes (lib/tina4/ai.rb) --
# mirrors tina4-python's tests/test_ai_fetch_retry.py and the equivalent
# PHP/Node specs. install_skills fetches ~30 files from
# raw.githubusercontent.com per install, which 503s intermittently under
# load (a freshly cut release tag is "cold" on GitHub's CDN until it warms)
# -- a single transient blip must not abort the whole install.
#
# NO MOCKS: a REAL TCPServer answers a scripted sequence over a real socket,
# in a background thread -- no monkeypatched Net::HTTP, no stubbed #sleep.
# fetch_bytes is a PUBLIC class method (Tina4::AI.fetch_bytes), so it is
# called directly, the same way ai_installer_spec.rb exercises AI's other
# class methods.
#
# Mirrors the ScriptedServer/with_server pattern spec/api_spec.rb already
# uses to drive Tina4::API's own opt-in retry/backoff over real sockets.

require "spec_helper"
require "socket"

RSpec.describe "Tina4::AI.fetch_bytes retry (3.13.100)" do
  # Scriptable single-thread HTTP stub, routed by PATH (unlike api_spec.rb's
  # flat by-request-order ScriptedServer, fetch_bytes needs two independent
  # scripted paths in the SAME server: one that recovers after two transient
  # 503s, one that is a permanent 404). Each path's hit counter is exact and
  # observed from the SERVER's own point of view.
  class AiFetchScriptedServer
    def initialize
      @hits = Hash.new(0)
      @server = TCPServer.new("127.0.0.1", 0)
      @running = true
      @thread = Thread.new { serve_loop }
    end

    def port
      @server.addr[1]
    end

    def hits(path)
      @hits[path]
    end

    def stop
      @running = false
      @thread.kill if @thread&.alive?
      @server.close unless @server.closed?
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
      return client.close if request_line.nil?

      while (line = client.gets)
        break if line == "\r\n"
      end

      path = request_line.split(" ")[1].to_s.split("?").first
      @hits[path] += 1
      n = @hits[path]

      status, body =
        case path
        when "/skill"
          n < 3 ? [503, "down"] : [200, "skill body"]
        when "/missing"
          [404, "not found"]
        else
          [404, "no such route: #{path}"]
        end

      client.write(
        "HTTP/1.1 #{status} X\r\n" \
        "Content-Type: application/octet-stream\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n#{body}"
      )
      client.close
    rescue StandardError
      begin
        client.close
      rescue StandardError
        nil
      end
    end
  end

  def with_server
    server = AiFetchScriptedServer.new
    begin
      yield server
    ensure
      server.stop
    end
  end

  it "POSITIVE: rides through two transient 503s and returns the real body" do
    with_server do |server|
      data = Tina4::AI.fetch_bytes("http://127.0.0.1:#{server.port}/skill")

      expect(data).to eq("skill body")
      # 1 initial + 2 retries = 3 attempts -- proves it actually retried
      # twice, not just once.
      expect(server.hits("/skill")).to eq(3)
    end
  end

  it "NEGATIVE: a persistent 404 returns nil on the FIRST attempt, no retry, no backoff sleep" do
    with_server do |server|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      data = Tina4::AI.fetch_bytes("http://127.0.0.1:#{server.port}/missing")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(data).to be_nil
      expect(server.hits("/missing")).to eq(1) # NEGATIVE: no retry on a permanent 404
      # fast -- well under fetch_and_retry's fixed 0.5s backoff sleep. If the
      # loop wrongly retried a 404 this would take at least 0.5s (one sleep)
      # and hit the server more than once.
      expect(elapsed).to be < 0.3
    end
  end
end
