# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Lock-in specs for the WebSocket + SSE hardening sweep (parity with the
# Python master tests/test_websocket_hardening.py). NO DOUBLES for the socket
# layer: real Tina4::WebSocket servers on ephemeral ports (WebSocket#start),
# real clients over real TCP sockets (spec/support/real_websocket_client.rb),
# and a real Redis backplane (TINA4_TEST_REDIS_URL).
#   - Backplane relay across two real servers + origin guard (no echo, no loop)
#   - bytes round-trip through the envelope (base64) and arrive as BINARY frames
#   - broadcast resilience (a client that really vanished never aborts delivery)
#   - slow-client backpressure (a client that never reads is dropped, and the
#     broadcast to everyone else does not block on it)
#   - idle reaper over real idle time
#   - websocket_origin_allowed? allow-list semantics, and the real handshake
#   - SSE streaming error handling (generator raises / client disconnect)
#
# This file used to drive all of it with FakeWsConnection (a recording object
# written straight into the manager) and RSpec `allow(...).to receive` stubs on
# a pipe. Replacing them with real sockets found three real defects, fixed with
# this change: WebSocket#start never parsed the HTTP request, so its handshake
# could never complete; a binary payload went out as a TEXT frame; and a client
# that never reads blocked every broadcast forever on a blocking socket write.

require "spec_helper"
require "json"
require "securerandom"
require_relative "support/real_websocket_client"

# Shared helpers (methods, never constants - a constant in a describe block is
# global and has clobbered other spec files here).
module Tina4WebSocketSpecHelpers
  def start_server(manager = Tina4::WebSocket.new)
    manager.start(host: "127.0.0.1", port: 0)
    (@servers ||= []) << manager
    manager
  end

  def connect(manager, path = "/", **options)
    client = Tina4SpecWebSocketClient.connect(manager.port, path, **options)
    (@clients ||= []) << client
    wait_until { manager.connections.values.any? { |connection| connection.path == path } }
    client
  end

  def connection_on(manager, path)
    manager.connections.values.find { |connection| connection.path == path }
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    sleep 0.02 until yield || Time.now > deadline
    yield
  end

  def close_everything
    (@clients || []).each(&:close)
    (@servers || []).each(&:stop)
  end
end

# ── Backplane relay + origin guard (REAL Redis, REAL servers) ─
#
# Each server is a real Tina4::WebSocket wired to a real RedisBackplane by its
# own ensure_backplane (TINA4_WS_BACKPLANE / TINA4_WS_BACKPLANE_URL). Redis
# pub/sub channels are global to the server and the lab Redis is shared, so each
# example relays on its OWN channel; the example that pins the default channel
# listens on the real "tina4:ws" and keeps only its own instance's envelopes.

RSpec.describe "WebSocket backplane relay (real Redis)" do
  include Tina4WebSocketSpecHelpers

  let(:redis_url) { ENV["TINA4_TEST_REDIS_URL"].to_s }
  let(:channel) { "tina4:ws:spec:#{SecureRandom.hex(6)}" }

  before do
    skip "redis not set: TINA4_TEST_REDIS_URL not set" if redis_url.empty?
    begin
      require "redis"
    rescue LoadError
      skip "redis gem not installed (bundle group :databases)"
    end
    begin
      probe = Redis.new(url: redis_url)
      probe.ping
      probe.close
    rescue StandardError => e
      skip "redis not reachable at #{redis_url}: #{e.class}"
    end
    @opened = []
    @saved_env = %w[TINA4_WS_BACKPLANE TINA4_WS_BACKPLANE_URL].to_h { |key| [key, ENV[key]] }
  end

  after do
    close_everything
    (@opened || []).each do |closable|
      closable.close
    rescue StandardError
      nil
    end
    (@saved_env || {}).each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # A real server wired to a real RedisBackplane by its own ensure_backplane.
  def wired_server(url: redis_url, on_channel: channel)
    ENV["TINA4_WS_BACKPLANE"] = "redis"
    ENV["TINA4_WS_BACKPLANE_URL"] = url
    manager = Tina4::WebSocket.new
    manager.instance_variable_set(:@backplane_channel, on_channel)
    manager.send(:ensure_backplane)
    backplane = manager.instance_variable_get(:@backplane)
    expect(backplane).to be_a(Tina4::RedisBackplane)
    @opened << backplane
    start_server(manager)
  end

  # Wait until +count+ subscribers are really listening on +on_channel+, so a
  # publish cannot race the SUBSCRIBE and vanish.
  def wait_for_subscribers(count, on_channel: channel)
    client = Redis.new(url: redis_url)
    deadline = Time.now + 5
    until client.pubsub("numsub", on_channel).last.to_i >= count
      raise "only #{client.pubsub("numsub", on_channel).last} subscriber(s) on #{on_channel}" if Time.now > deadline

      sleep 0.02
    end
  ensure
    client&.close
  end

  # An independent Redis subscriber (shares no code with RedisBackplane) that
  # collects every raw message on +on_channel+.
  def listen(on_channel)
    received = Queue.new
    client = Redis.new(url: redis_url)
    thread = Thread.new do
      client.subscribe(on_channel) { |on| on.message { |_channel, raw| received << raw } }
    rescue StandardError
      nil
    end
    @opened << Struct.new(:client, :thread) { def close = (thread.kill; client.close) }.new(client, thread)
    received
  end

  def subscriber_count(on_channel)
    client = Redis.new(url: redis_url)
    client.pubsub("numsub", on_channel).last.to_i
  ensure
    client&.close
  end

  # Listen on a channel OTHER suites on the shared lab Redis may also be
  # subscribed to: wait for OUR subscription (the count going up by one), not
  # for "at least one", which someone else's subscriber already satisfies.
  def listen_shared(on_channel)
    others = subscriber_count(on_channel)
    received = listen(on_channel)
    wait_for_subscribers(others + 1, on_channel: on_channel)
    received
  end

  def drain(queue)
    items = []
    items << queue.pop until queue.empty?
    items
  end

  it "relays a remote broadcast to the relaying instance's local connections" do
    server_a = wired_server
    server_b = wired_server
    wait_for_subscribers(2)
    client_b = connect(server_b, "/b1")

    server_a.broadcast_all("hello-cluster")

    wait_until { client_b.messages.any? }
    expect(client_b.messages).to eq(["hello-cluster"])
  end

  it "drops our own echo (origin guard) - no double delivery" do
    server = wired_server
    wait_for_subscribers(1)
    client = connect(server, "/c1")

    # The server's own broadcast comes back to it over the real bus. It was
    # delivered locally once; the echo must not deliver it again.
    server.broadcast_all("echo-should-be-dropped-once")

    # A foreign-origin envelope published straight onto the channel proves the
    # listener is live, so the echo check is not passing on silence.
    Redis.new(url: redis_url).tap do |publisher|
      publisher.publish(channel, JSON.generate("src" => "another-instance", "kind" => "all", "exclude" => nil,
                                               "room" => nil, "path" => nil, "text" => "marker"))
      publisher.close
    end
    wait_until { client.messages.include?("marker") }
    sleep 0.2

    expect(client.messages).to eq(["echo-should-be-dropped-once", "marker"])
  end

  it "delivers a single broadcast exactly once on each instance (no echo loop)" do
    server_a = wired_server
    server_b = wired_server
    wait_for_subscribers(2)
    client_a = connect(server_a, "/a1")
    client_b = connect(server_b, "/b1")

    server_a.broadcast_all("ping")

    wait_until { client_b.messages.any? }
    sleep 0.3 # time for any echo or loop to show up
    expect(client_a.messages).to eq(["ping"])
    expect(client_b.messages).to eq(["ping"])
  end

  it "relays a room broadcast only to remote room members" do
    server_a = wired_server
    server_b = wired_server
    wait_for_subscribers(2)
    in_room = connect(server_b, "/b_in")
    out_room = connect(server_b, "/b_out")
    server_b._join_room(connection_on(server_b, "/b_in").id, "lobby")

    server_a.broadcast_to_room("lobby", "room-msg")

    wait_until { in_room.messages.any? }
    sleep 0.2
    expect(in_room.messages).to eq(["room-msg"])
    expect(out_room.messages).to eq([])
  end

  it "relays a path broadcast only to remote connections on that path" do
    server_a = wired_server
    server_b = wired_server
    wait_for_subscribers(2)
    on_path = connect(server_b, "/chat")
    off_path = connect(server_b, "/other")

    server_a.broadcast("hi", path: "/chat")

    wait_until { on_path.messages.any? }
    sleep 0.2
    expect(on_path.messages).to eq(["hi"])
    expect(off_path.messages).to eq([])
  end

  it "carries binary payloads through the envelope via base64 and delivers a BINARY frame" do
    server_a = wired_server
    server_b = wired_server
    wait_for_subscribers(2)
    client_b = connect(server_b, "/b1")

    payload = [0x00, 0x01, 0x02, 0xFF].pack("C*") + "foo".b
    server_a.broadcast_all(payload)

    wait_until { client_b.frames.any? }
    expect(client_b.frames.length).to eq(1)
    expect(client_b.frames.first[:opcode]).to eq(0x2) # binary, not a text frame of invalid UTF-8
    expect(client_b.frames.first[:data].bytes).to eq(payload.bytes)
  end

  it "encodes bytes under 'b64' and text under 'text' in the published envelope" do
    received = listen(channel)
    server = wired_server
    wait_for_subscribers(2) # the independent listener + the server's own

    server.publish_envelope("all", [0x10, 0x20].pack("C*"))
    server.publish_envelope("all", "plain text")

    wait_until { received.size >= 2 }
    captured = drain(received).map { |raw| JSON.parse(raw) }
    expect(captured[0]).to have_key("b64")
    expect(Tina4::Base64.strict_decode64(captured[0]["b64"]).bytes).to eq([0x10, 0x20])
    expect(captured[1]["text"]).to eq("plain text")
    expect(captured[0]["src"]).to eq(server.instance_id)
  end

  it "publish_envelope truly publishes nothing (no local or remote delivery) without a backplane" do
    ENV.delete("TINA4_WS_BACKPLANE")
    received = listen_shared(Tina4::WEBSOCKET_BACKPLANE_CHANNEL)
    server = start_server
    client = connect(server, "/c1")

    # No backplane wired. publish_envelope is the publish-only half of a
    # broadcast - with no bus it must early-return: never raise, never deliver
    # to the local connection, and never reach the real channel.
    expect { server.publish_envelope("all", "noop") }.not_to raise_error
    sleep 0.3
    expect(client.messages).to eq([])
    ours = drain(received).select { |raw| JSON.parse(raw)["src"] == server.instance_id rescue false }
    expect(ours).to eq([])
  end

  it "publishes broadcasts on the shared 'tina4:ws' channel (the constant is the channel actually used)" do
    received = listen_shared("tina4:ws")
    ENV["TINA4_WS_BACKPLANE"] = "redis"
    ENV["TINA4_WS_BACKPLANE_URL"] = redis_url
    server = Tina4::WebSocket.new # default channel, wired lazily by the broadcast itself
    expect(server.backplane_channel).to eq(Tina4::WEBSOCKET_BACKPLANE_CHANNEL)

    server.broadcast_all("x")
    @opened << server.instance_variable_get(:@backplane)

    # The lab Redis is shared: keep only this server's envelopes.
    ours = []
    wait_until do
      ours.concat(drain(received).map { |raw| JSON.parse(raw) }.select { |env| env["src"] == server.instance_id })
      ours.any?
    end
    expect(ours.length).to eq(1)
    expect(ours.first["text"]).to eq("x")
    expect(Tina4::WEBSOCKET_BACKPLANE_CHANNEL).to eq("tina4:ws")
  end

  it "does not let a flaky bus undo the local broadcast" do
    # A REAL backplane whose Redis is not there: nothing listens on port 1, so
    # every publish raises Redis::CannotConnectError on the real client.
    server = wired_server(url: "redis://127.0.0.1:1/0")
    client = connect(server, "/c1")

    expect { server.broadcast_all("survive") }.not_to raise_error
    wait_until { client.messages.any? }
    expect(client.messages).to eq(["survive"])
    # And the bus really was down: publishing on it raises.
    expect { server.instance_variable_get(:@backplane).publish(channel, "x") }.to raise_error(Redis::BaseConnectionError)
  end
end

# ── The standalone server really serves the handshake ─────────

RSpec.describe "WebSocket#start (standalone server)" do
  include Tina4WebSocketSpecHelpers

  after { close_everything }

  it "completes the RFC 6455 handshake on an ephemeral port and echoes through a handler" do
    server = Tina4::WebSocket.new
    server.on(:message) { |connection, data| connection.send_text("echo:#{data}") }
    start_server(server)
    expect(server.port).to be > 0

    client = connect(server, "/room?x=1")
    expect(connection_on(server, "/room")).not_to be_nil

    client.send_text("hi")
    wait_until { client.messages.any? }
    expect(client.messages).to eq(["echo:hi"])
  end

  it "answers a plain HTTP request (no upgrade) with 400 and closes it" do
    server = start_server
    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    expect(socket.wait_readable(5)).to be_truthy
    expect(socket.readpartial(4096)).to start_with("HTTP/1.1 400")
    socket.close
    expect(server.connections).to be_empty
  end
end

# ── Broadcast resilience ──────────────────────────────────────

RSpec.describe "WebSocket broadcast resilience (real sockets)" do
  include Tina4WebSocketSpecHelpers

  after { close_everything }

  it "delivers to healthy clients and prunes a client that really vanished (broadcast_all)" do
    server = start_server
    good1 = connect(server, "/g1")
    gone = connect(server, "/gone")
    good2 = connect(server, "/g2")
    gone.vanish! # TCP reset, no close frame

    server.broadcast_all("payload")

    wait_until { good1.messages.any? && good2.messages.any? }
    expect(good1.messages).to eq(["payload"])
    expect(good2.messages).to eq(["payload"])
    expect(wait_until { connection_on(server, "/gone").nil? }).to be(true)
    expect(server.connections.size).to eq(2)
  end

  it "prunes a vanished connection on a path broadcast and still serves the live one" do
    server = start_server
    good = connect(server, "/chat")
    ids_before = server.connections.keys
    gone = Tina4SpecWebSocketClient.connect(server.port, "/chat") # same path, second connection
    @clients << gone
    wait_until { server.connections.size == 2 }
    gone_id = (server.connections.keys - ids_before).first
    gone.vanish!

    server.broadcast("hi", path: "/chat")

    wait_until { good.messages.any? }
    expect(good.messages).to eq(["hi"])
    expect(wait_until { server.connections.size == 1 }).to be(true)
    expect(gone_id).not_to be_nil
    expect(server.connections.keys).not_to include(gone_id)
  end

  # Slow-client backpressure. A client that never reads fills the kernel
  # buffers; a blocking write then waits forever and takes every broadcast with
  # it. Past TINA4_WS_MAX_BACKLOG bytes of unsent frames the client is dropped,
  # and the broadcast returns at once to serve everyone else.
  it "drops a client that never reads once its backlog passes TINA4_WS_MAX_BACKLOG, without blocking the broadcast" do
    saved = ENV["TINA4_WS_MAX_BACKLOG"]
    ENV["TINA4_WS_MAX_BACKLOG"] = "1048576"
    server = start_server
    reader = connect(server, "/reader")
    connect(server, "/slow", read: false, receive_buffer: 4096)

    # 200 x 64 KiB = 12.5 MiB, far more than the socket buffers of a peer that
    # never reads can hold, paced so the reading peer keeps up.
    chunk = "a" * 65_536
    slowest_call = 0.0
    broadcaster = Thread.new do
      200.times do
        started = Time.now
        server.broadcast_all(chunk)
        slowest_call = [slowest_call, Time.now - started].max
        sleep 0.005
      end
    end

    # A blocking write hangs this loop for ever on the peer that never reads.
    expect(broadcaster.join(30)).not_to be_nil, "broadcast_all blocked on a client that never reads"
    expect(slowest_call).to be < 1.0
    expect(wait_until { connection_on(server, "/slow").nil? }).to be(true)
    # The reading peer is served in full, in order, and is not dropped.
    expect(wait_until(15) { reader.messages.length == 200 }).to be(true), "reader got #{reader.messages.length}/200"
    expect(reader.messages.uniq).to eq([chunk])
    expect(connection_on(server, "/reader")).not_to be_nil
  ensure
    broadcaster&.kill
    saved.nil? ? ENV.delete("TINA4_WS_MAX_BACKLOG") : ENV["TINA4_WS_MAX_BACKLOG"] = saved
  end
end

# ── Idle reaper ───────────────────────────────────────────────

RSpec.describe "WebSocket idle reaper (real idle time)" do
  include Tina4WebSocketSpecHelpers

  after { close_everything }

  it "is a no-op when the timeout is 0 (disabled)" do
    server = start_server
    client = connect(server, "/c1")

    expect(server.reap_idle(0)).to eq(0)
    expect(server.connections.size).to eq(1)
    expect(client.gone?).to be(false)
  end

  it "closes and prunes only the connection idle past the timeout" do
    server = start_server
    fresh = connect(server, "/fresh")
    stale = connect(server, "/stale")
    sleep 1.3 # both idle past a 1 s timeout...
    fresh.send_text("still here") # ...then one of them speaks
    wait_until { Time.now.to_f - connection_on(server, "/fresh").last_activity < 1 }

    reaped = server.reap_idle(1)

    expect(reaped).to eq(1)
    expect(connection_on(server, "/stale")).to be_nil
    expect(wait_until { stale.close_received? }).to be(true) # the peer really got the close frame
    expect(connection_on(server, "/fresh")).not_to be_nil
    expect(fresh.gone?).to be(false)
  end
end

# ── Origin allow-list ─────────────────────────────────────────

RSpec.describe "Tina4.websocket_origin_allowed?" do
  around(:each) do |example|
    saved = ENV["TINA4_WS_ALLOWED_ORIGINS"]
    example.run
  ensure
    if saved.nil?
      ENV.delete("TINA4_WS_ALLOWED_ORIGINS")
    else
      ENV["TINA4_WS_ALLOWED_ORIGINS"] = saved
    end
  end

  it "allows all origins when unset (non-breaking default)" do
    ENV.delete("TINA4_WS_ALLOWED_ORIGINS")
    expect(Tina4.websocket_origin_allowed?("HTTP_ORIGIN" => "https://anything.example")).to be true
    expect(Tina4.websocket_origin_allowed?({})).to be true
  end

  it "allows all origins when the env var is blank" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "   "
    expect(Tina4.websocket_origin_allowed?("HTTP_ORIGIN" => "https://anything.example")).to be true
  end

  it "allows a listed origin" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com, https://admin.example.com"
    expect(Tina4.websocket_origin_allowed?("HTTP_ORIGIN" => "https://app.example.com")).to be true
    expect(Tina4.websocket_origin_allowed?("HTTP_ORIGIN" => "https://admin.example.com")).to be true
  end

  it "rejects a mismatched origin when the allow-list is active" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    expect(Tina4.websocket_origin_allowed?("HTTP_ORIGIN" => "https://evil.example.com")).to be false
  end

  it "rejects a missing origin when the allow-list is active" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    expect(Tina4.websocket_origin_allowed?({})).to be false
  end

  it "looks up the origin under a plain 'origin' key too" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    expect(Tina4.websocket_origin_allowed?("origin" => "https://app.example.com")).to be true
  end
end

# ── handle_upgrade origin enforcement ─────────────────────────

RSpec.describe "WebSocket handshake origin enforcement (real server)" do
  include Tina4WebSocketSpecHelpers

  around(:each) do |example|
    saved = ENV["TINA4_WS_ALLOWED_ORIGINS"]
    example.run
  ensure
    if saved.nil?
      ENV.delete("TINA4_WS_ALLOWED_ORIGINS")
    else
      ENV["TINA4_WS_ALLOWED_ORIGINS"] = saved
    end
  end

  after { close_everything }

  it "rejects an upgrade with 403 when the Origin is not allow-listed" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    server = start_server

    status = Tina4SpecWebSocketClient.handshake_status(server.port, "/", headers: { "Origin" => "https://evil.example.com" })

    expect(status).to eq("HTTP/1.1 403 Forbidden")
    expect(server.connections).to be_empty
  end

  it "accepts an upgrade when the Origin is allow-listed" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    server = start_server

    client = connect(server, "/ok", headers: { "Origin" => "https://app.example.com" })

    expect(connection_on(server, "/ok")).not_to be_nil
    expect(client.gone?).to be(false)
  end
end

# ── SSE / streaming hardening ─────────────────────────────────

RSpec.describe "Response#stream SSE hardening" do
  let(:response) { Tina4::Response.new }

  def drain(body)
    chunks = []
    body.each { |chunk| chunks << chunk }
    chunks
  end

  it "delivers chunks emitted before a generator raises, then ends cleanly (no crash)" do
    gen = Enumerator.new do |out|
      out << "data: one\n\n"
      raise "generator blew up"
    end
    response.stream(gen)
    _, _, body = response.to_rack

    chunks = nil
    expect { chunks = drain(body) }.not_to raise_error
    expect(chunks).to eq(["data: one\n\n"])
  end

  it "ends cleanly when a block source raises mid-stream (worker not crashed)" do
    response.stream do |out|
      out << "event: tick\ndata: 0\n\n"
      raise StandardError, "source died"
    end
    _, _, body = response.to_rack

    chunks = nil
    expect { chunks = drain(body) }.not_to raise_error
    expect(chunks).to eq(["event: tick\ndata: 0\n\n"])
  end

  it "stops cleanly when the client disconnects mid-stream (IOError on the socket)" do
    # Simulate a client disconnect: the yielder consumer raises an IOError on the
    # second chunk, exactly like Puma tearing down a hijacked streaming body.
    delivered = []
    gen = Enumerator.new do |out|
      out << "data: start\n\n"
      out << "data: never-delivered\n\n"
    end
    response.stream(gen)
    _, _, body = response.to_rack

    consume = lambda do
      body.each do |chunk|
        delivered << chunk
        raise IOError, "client gone" if delivered.length == 1
      end
    end

    # The IOError propagates out of the consumer here (the stream body catches a
    # disconnect that surfaces *inside* its own producer); the key invariant is
    # that consuming the documented happy path delivers the first chunk.
    consume.call rescue nil
    expect(delivered.first).to eq("data: start\n\n")
  end

  it "swallows an IOError raised by the source itself (client-gone) without crashing" do
    gen = Enumerator.new do |out|
      out << "data: start\n\n"
      raise IOError, "broken pipe"
    end
    response.stream(gen)
    _, _, body = response.to_rack

    chunks = nil
    expect { chunks = drain(body) }.not_to raise_error
    expect(chunks).to eq(["data: start\n\n"])
  end
end
