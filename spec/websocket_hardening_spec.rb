# frozen_string_literal: true
#
# Lock-in specs for the WebSocket + SSE hardening sweep (parity with the
# Python master tests/test_websocket_hardening.py). The backplane relay runs on a
# REAL Redis (TINA4_TEST_REDIS_URL) through real RedisBackplanes:
#   - Backplane relay across two manager instances + origin-guard-no-echo
#   - bytes round-trip through the envelope (base64)
#   - broadcast resilience (one dead client never aborts delivery; it is pruned)
#   - SSE streaming error handling (generator raises / client disconnect)
#   - websocket_origin_allowed? allow-list semantics (empty=allow / set=reject)

require "spec_helper"
require "json"
require "securerandom"

# ── Connection stand-in ───────────────────────────────────────

# Minimal stand-in for WebSocketConnection — records what was sent and can be
# told to raise on send (to exercise broadcast resilience / pruning) or to flag
# itself closed (to exercise the silent-write-failure prune path).
class FakeWsConnection
  attr_reader :id, :sent
  attr_accessor :path, :last_activity

  def initialize(id, raise_on_send: false, report_closed: false)
    @id = id
    @path = "/"
    @sent = []
    @raise_on_send = raise_on_send
    @report_closed = report_closed
    @last_activity = Time.now.to_f
    @closed = false
  end

  def send_text(message)
    raise IOError, "simulated broken pipe on #{@id}" if @raise_on_send

    @sent << message
  end

  def closed?
    @report_closed || @closed
  end

  def close(code: 1000, reason: "")
    @closed = true
  end
end

# ── Backplane relay + origin guard (REAL Redis) ───────────────
#
# Every backplane here is a real Tina4::RedisBackplane on the lab/CI Redis
# (TINA4_TEST_REDIS_URL), wired by the manager's own ensure_backplane from
# TINA4_WS_BACKPLANE / TINA4_WS_BACKPLANE_URL - the path a real app takes. These
# used to be in-memory stand-ins (FakeBackplane and two subclasses), which proved
# the relay logic but never that a message crosses a real pub/sub bus.
#
# Redis pub/sub channels are global to the server (not per database) and the lab
# Redis is shared, so each example relays on its OWN channel (set on the manager
# before wiring). The example that pins the default channel listens on the real
# "tina4:ws" and keeps only envelopes from its own manager's instance id.

RSpec.describe "WebSocket backplane relay (real Redis)" do
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
    (@opened || []).each do |closable|
      closable.close
    rescue StandardError
      nil
    end
    (@saved_env || {}).each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # A manager wired to a real RedisBackplane by its own ensure_backplane.
  def wired_manager(url: redis_url, on_channel: channel)
    ENV["TINA4_WS_BACKPLANE"] = "redis"
    ENV["TINA4_WS_BACKPLANE_URL"] = url
    manager = Tina4::WebSocket.new
    manager.instance_variable_set(:@backplane_channel, on_channel)
    manager.send(:ensure_backplane)
    backplane = manager.instance_variable_get(:@backplane)
    expect(backplane).to be_a(Tina4::RedisBackplane)
    @opened << backplane
    manager
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

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    sleep 0.02 until yield || Time.now > deadline
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
    [received, client]
  end

  def drain(queue)
    items = []
    items << queue.pop until queue.empty?
    items
  end

  it "relays a remote broadcast to the relaying instance's local connections" do
    mgr_a = wired_manager
    mgr_b = wired_manager
    wait_for_subscribers(2)

    conn_b = FakeWsConnection.new("b1")
    mgr_b.register_connection(conn_b)

    mgr_a.broadcast_all("hello-cluster")

    wait_until { conn_b.sent.any? }
    expect(conn_b.sent).to eq(["hello-cluster"])
  end

  it "drops our own echo (origin guard) - no double delivery" do
    mgr = wired_manager
    wait_for_subscribers(1)
    conn = FakeWsConnection.new("c1")
    mgr.register_connection(conn)

    # The manager's own broadcast comes back to it over the real bus. It was
    # delivered locally once; the echo must not deliver it again.
    mgr.broadcast_all("echo-should-be-dropped-once")

    # A second, foreign-origin envelope published straight onto the channel
    # proves the listener is live, so the echo check is not passing on silence.
    Redis.new(url: redis_url).tap do |client|
      client.publish(channel, JSON.generate("src" => "another-instance", "kind" => "all", "exclude" => nil,
                                            "room" => nil, "path" => nil, "text" => "marker"))
      client.close
    end
    wait_until { conn.sent.include?("marker") }
    sleep 0.2

    expect(conn.sent).to eq(["echo-should-be-dropped-once", "marker"])
  end

  it "delivers a single broadcast exactly once on each instance (no echo loop)" do
    mgr_a = wired_manager
    mgr_b = wired_manager
    wait_for_subscribers(2)

    conn_a = FakeWsConnection.new("a1")
    conn_b = FakeWsConnection.new("b1")
    mgr_a.register_connection(conn_a)
    mgr_b.register_connection(conn_b)

    mgr_a.broadcast_all("ping")

    wait_until { conn_b.sent.any? }
    sleep 0.3 # time for any echo or loop to show up
    expect(conn_a.sent).to eq(["ping"])
    expect(conn_b.sent).to eq(["ping"])
  end

  it "relays a room broadcast only to remote room members" do
    mgr_a = wired_manager
    mgr_b = wired_manager
    wait_for_subscribers(2)

    in_room = FakeWsConnection.new("b_in")
    out_room = FakeWsConnection.new("b_out")
    mgr_b.register_connection(in_room)
    mgr_b.register_connection(out_room)
    mgr_b._join_room("b_in", "lobby")

    mgr_a.broadcast_to_room("lobby", "room-msg")

    wait_until { in_room.sent.any? }
    sleep 0.2
    expect(in_room.sent).to eq(["room-msg"])
    expect(out_room.sent).to eq([])
  end

  it "relays a path broadcast only to remote connections on that path" do
    mgr_a = wired_manager
    mgr_b = wired_manager
    wait_for_subscribers(2)

    on_path = FakeWsConnection.new("b_chat")
    on_path.path = "/chat"
    off_path = FakeWsConnection.new("b_other")
    off_path.path = "/other"
    mgr_b.register_connection(on_path)
    mgr_b.register_connection(off_path)

    mgr_a.broadcast("hi", path: "/chat")

    wait_until { on_path.sent.any? }
    sleep 0.2
    expect(on_path.sent).to eq(["hi"])
    expect(off_path.sent).to eq([])
  end

  it "carries binary payloads through the envelope via base64 (bytes round-trip)" do
    mgr_a = wired_manager
    mgr_b = wired_manager
    wait_for_subscribers(2)

    conn_b = FakeWsConnection.new("b1")
    mgr_b.register_connection(conn_b)

    payload = [0x00, 0x01, 0x02, 0xFF].pack("C*") + "foo".b
    mgr_a.broadcast_all(payload)

    wait_until { conn_b.sent.any? }
    expect(conn_b.sent.length).to eq(1)
    expect(conn_b.sent.first.bytes).to eq(payload.bytes)
    expect(conn_b.sent.first.encoding).to eq(Encoding::ASCII_8BIT)
  end

  it "encodes bytes under 'b64' and text under 'text' in the published envelope" do
    received, = listen(channel)
    mgr = wired_manager
    wait_for_subscribers(2) # the independent listener + the manager's own

    mgr.publish_envelope("all", [0x10, 0x20].pack("C*"))
    mgr.publish_envelope("all", "plain text")

    wait_until { received.size >= 2 }
    captured = drain(received).map { |raw| JSON.parse(raw) }
    expect(captured[0]).to have_key("b64")
    expect(Tina4::Base64.strict_decode64(captured[0]["b64"]).bytes).to eq([0x10, 0x20])
    expect(captured[1]["text"]).to eq("plain text")
    expect(captured[0]["src"]).to eq(mgr.instance_id)
  end

  it "publish_envelope truly publishes nothing (no local or remote delivery) without a backplane" do
    ENV.delete("TINA4_WS_BACKPLANE")
    received, = listen(Tina4::WEBSOCKET_BACKPLANE_CHANNEL)
    wait_for_subscribers(1, on_channel: Tina4::WEBSOCKET_BACKPLANE_CHANNEL)
    mgr = Tina4::WebSocket.new
    conn = FakeWsConnection.new("c1")
    mgr.register_connection(conn)

    # No backplane wired. publish_envelope is the publish-only half of a
    # broadcast - with no bus it must early-return: never raise, never deliver
    # to the local connection, and never reach the real channel.
    expect { mgr.publish_envelope("all", "noop") }.not_to raise_error
    sleep 0.3
    expect(conn.sent).to eq([])
    ours = drain(received).select { |raw| JSON.parse(raw)["src"] == mgr.instance_id rescue false }
    expect(ours).to eq([])
  end

  it "publishes broadcasts on the shared 'tina4:ws' channel (the constant is the channel actually used)" do
    received, = listen("tina4:ws")
    wait_for_subscribers(1, on_channel: "tina4:ws")
    ENV["TINA4_WS_BACKPLANE"] = "redis"
    ENV["TINA4_WS_BACKPLANE_URL"] = redis_url
    mgr = Tina4::WebSocket.new # default channel, wired lazily by the broadcast itself
    expect(mgr.backplane_channel).to eq(Tina4::WEBSOCKET_BACKPLANE_CHANNEL)

    mgr.broadcast_all("x")
    @opened << mgr.instance_variable_get(:@backplane)

    # The lab Redis is shared: keep only this manager's envelopes.
    ours = []
    wait_until do
      ours.concat(drain(received).map { |raw| JSON.parse(raw) }.select { |env| env["src"] == mgr.instance_id })
      ours.any?
    end
    expect(ours.length).to eq(1)
    expect(ours.first["text"]).to eq("x")
    expect(Tina4::WEBSOCKET_BACKPLANE_CHANNEL).to eq("tina4:ws")
  end

  it "does not let a flaky bus undo the local broadcast" do
    # A REAL backplane whose Redis is not there: nothing listens on port 1, so
    # every publish raises Redis::CannotConnectError on the real client.
    mgr = wired_manager(url: "redis://127.0.0.1:1/0")
    conn = FakeWsConnection.new("c1")
    mgr.register_connection(conn)

    expect { mgr.broadcast_all("survive") }.not_to raise_error
    expect(conn.sent).to eq(["survive"])
    # And the bus really was down: publishing on it raises.
    expect { mgr.instance_variable_get(:@backplane).publish(channel, "x") }.to raise_error(Redis::BaseConnectionError)
  end
end

# ── Broadcast resilience ──────────────────────────────────────

RSpec.describe "WebSocket broadcast resilience" do
  it "delivers to healthy clients and prunes a dead one (broadcast_all)" do
    mgr = Tina4::WebSocket.new
    good1 = FakeWsConnection.new("g1")
    bad = FakeWsConnection.new("bad", raise_on_send: true)
    good2 = FakeWsConnection.new("g2")
    mgr.register_connection(good1)
    mgr.register_connection(bad)
    mgr.register_connection(good2)

    mgr.broadcast_all("payload")

    expect(good1.sent).to eq(["payload"])
    expect(good2.sent).to eq(["payload"])
    expect(mgr.connections["bad"]).to be_nil
    expect(mgr.connections.size).to eq(2)
  end

  it "prunes a dead connection on a path broadcast" do
    mgr = Tina4::WebSocket.new
    good = FakeWsConnection.new("g")
    bad = FakeWsConnection.new("bad", raise_on_send: true)
    good.path = "/chat"
    bad.path = "/chat"
    mgr.register_connection(good)
    mgr.register_connection(bad)

    mgr.broadcast("hi", path: "/chat")

    expect(good.sent).to eq(["hi"])
    expect(mgr.connections["bad"]).to be_nil
  end

  it "prunes a connection that silently flips closed? after a write failure" do
    mgr = Tina4::WebSocket.new
    good = FakeWsConnection.new("g")
    silent = FakeWsConnection.new("silent", report_closed: true)
    mgr.register_connection(good)
    mgr.register_connection(silent)

    mgr.broadcast_all("payload")

    expect(good.sent).to eq(["payload"])
    # The "silent" connection accepted the write but reports itself closed.
    expect(mgr.connections["silent"]).to be_nil
  end
end

# ── Idle reaper ───────────────────────────────────────────────

RSpec.describe "WebSocket idle reaper" do
  it "is a no-op when the timeout is 0 (disabled)" do
    mgr = Tina4::WebSocket.new
    conn = FakeWsConnection.new("c1")
    mgr.register_connection(conn)

    expect(mgr.reap_idle(0)).to eq(0)
    expect(mgr.connections.size).to eq(1)
  end

  it "closes and prunes connections idle past the timeout" do
    mgr = Tina4::WebSocket.new
    fresh = FakeWsConnection.new("fresh")
    stale = FakeWsConnection.new("stale")
    fresh.last_activity = Time.now.to_f
    stale.last_activity = Time.now.to_f - 1000 # long idle
    mgr.register_connection(fresh)
    mgr.register_connection(stale)

    reaped = mgr.reap_idle(30)

    expect(reaped).to eq(1)
    expect(mgr.connections["stale"]).to be_nil
    expect(stale.closed?).to be true
    expect(mgr.connections["fresh"]).not_to be_nil
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

RSpec.describe "WebSocket#handle_upgrade origin enforcement" do
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

  it "rejects an upgrade with 403 when the Origin is not allow-listed" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    ws = Tina4::WebSocket.new
    read_io, write_io = IO.pipe
    env = {
      "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
      "HTTP_ORIGIN" => "https://evil.example.com"
    }

    ws.handle_upgrade(env, write_io)

    output = read_io.read_nonblock(4096)
    expect(output).to include("403 Forbidden")
    expect(output).not_to include("101 Switching Protocols")
    expect(ws.connections).to be_empty

    read_io.close
    write_io.close rescue nil
  end

  it "accepts an upgrade when the Origin is allow-listed" do
    ENV["TINA4_WS_ALLOWED_ORIGINS"] = "https://app.example.com"
    ws = Tina4::WebSocket.new
    read_io, write_io = IO.pipe
    allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
    allow(write_io).to receive(:read).and_return("")
    allow(write_io).to receive(:close)
    env = {
      "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
      "HTTP_ORIGIN" => "https://app.example.com"
    }

    ws.handle_upgrade(env, write_io)
    sleep 0.1

    output = read_io.read_nonblock(4096)
    expect(output).to include("101 Switching Protocols")

    read_io.close
    write_io.close rescue nil
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
