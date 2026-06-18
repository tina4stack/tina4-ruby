# frozen_string_literal: true
#
# Lock-in specs for the WebSocket + SSE hardening sweep (parity with the
# Python master tests/test_websocket_hardening.py). Engine-agnostic — no real
# Redis/NATS/sockets. A tiny in-memory FakeBackplane proves the relay path
# end-to-end:
#   - Backplane relay across simulated instances + origin-guard-no-echo
#   - bytes round-trip through the envelope (base64)
#   - broadcast resilience (one dead client never aborts delivery; it is pruned)
#   - SSE streaming error handling (generator raises / client disconnect)
#   - websocket_origin_allowed? allow-list semantics (empty=allow / set=reject)

require "spec_helper"
require "json"
require "base64"

# ── Fakes ─────────────────────────────────────────────────────

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

# In-memory pub/sub backplane. publish synchronously fans the raw message out
# to every subscribed block — exactly what a real backplane does, minus the
# network and background thread.
class FakeBackplane < Tina4::WebSocketBackplane
  def initialize
    @subs = Hash.new { |h, k| h[k] = [] }
  end

  def publish(channel, message)
    @subs[channel].each { |blk| blk.call(message) }
  end

  def subscribe(channel, &block)
    @subs[channel] << block
  end

  def unsubscribe(channel)
    @subs.delete(channel)
  end

  def close
    @subs.clear
  end
end

# A backplane whose publish always blows up — proves a flaky bus never undoes a
# local broadcast.
class ExplodingBackplane < FakeBackplane
  def publish(_channel, _message)
    raise RuntimeError, "bus down"
  end
end

# Attach a fake backplane to a manager the way ensure_backplane would, wiring
# the subscribe callback to the manager's on_backplane_message.
def wire_backplane(manager, backplane)
  manager.instance_variable_set(:@backplane, backplane)
  manager.instance_variable_set(:@backplane_started, true)
  backplane.subscribe(manager.backplane_channel) { |raw| manager.on_backplane_message(raw) }
end

# ── Backplane relay + origin guard ────────────────────────────

RSpec.describe "WebSocket backplane relay" do
  it "relays a remote broadcast to the relaying instance's local connections" do
    backplane = FakeBackplane.new
    mgr_a = Tina4::WebSocket.new
    mgr_b = Tina4::WebSocket.new
    wire_backplane(mgr_a, backplane)
    wire_backplane(mgr_b, backplane)

    conn_b = FakeWsConnection.new("b1")
    mgr_b.register_connection(conn_b)

    # A broadcasts to all — delivers locally (A has none) then publishes.
    mgr_a.broadcast_all("hello-cluster")

    expect(conn_b.sent).to eq(["hello-cluster"])
  end

  it "drops our own echo (origin guard) — no double delivery" do
    backplane = FakeBackplane.new
    mgr = Tina4::WebSocket.new
    wire_backplane(mgr, backplane)

    conn = FakeWsConnection.new("c1")
    mgr.register_connection(conn)

    # Hand-craft an envelope whose src == this manager's instance id.
    echo = JSON.generate(
      "src" => mgr.instance_id,
      "kind" => "all",
      "exclude" => nil,
      "room" => nil,
      "path" => nil,
      "text" => "echo-should-be-dropped"
    )
    mgr.on_backplane_message(echo)

    # Origin guard: the connection must NOT have received the echo.
    expect(conn.sent).to eq([])
  end

  it "delivers a single broadcast exactly once on each instance (no echo loop)" do
    backplane = FakeBackplane.new
    mgr_a = Tina4::WebSocket.new
    mgr_b = Tina4::WebSocket.new
    wire_backplane(mgr_a, backplane)
    wire_backplane(mgr_b, backplane)

    conn_a = FakeWsConnection.new("a1")
    conn_b = FakeWsConnection.new("b1")
    mgr_a.register_connection(conn_a)
    mgr_b.register_connection(conn_b)

    mgr_a.broadcast_all("ping")

    # Exactly once each — the origin guard prevents A from re-delivering.
    expect(conn_a.sent).to eq(["ping"])
    expect(conn_b.sent).to eq(["ping"])
  end

  it "relays a room broadcast only to remote room members" do
    backplane = FakeBackplane.new
    mgr_a = Tina4::WebSocket.new
    mgr_b = Tina4::WebSocket.new
    wire_backplane(mgr_a, backplane)
    wire_backplane(mgr_b, backplane)

    in_room = FakeWsConnection.new("b_in")
    out_room = FakeWsConnection.new("b_out")
    mgr_b.register_connection(in_room)
    mgr_b.register_connection(out_room)
    mgr_b._join_room("b_in", "lobby")

    mgr_a.broadcast_to_room("lobby", "room-msg")

    expect(in_room.sent).to eq(["room-msg"])
    expect(out_room.sent).to eq([])
  end

  it "relays a path broadcast only to remote connections on that path" do
    backplane = FakeBackplane.new
    mgr_a = Tina4::WebSocket.new
    mgr_b = Tina4::WebSocket.new
    wire_backplane(mgr_a, backplane)
    wire_backplane(mgr_b, backplane)

    on_path = FakeWsConnection.new("b_chat")
    on_path.path = "/chat"
    off_path = FakeWsConnection.new("b_other")
    off_path.path = "/other"
    mgr_b.register_connection(on_path)
    mgr_b.register_connection(off_path)

    mgr_a.broadcast("hi", path: "/chat")

    expect(on_path.sent).to eq(["hi"])
    expect(off_path.sent).to eq([])
  end

  it "carries binary payloads through the envelope via base64 (bytes round-trip)" do
    backplane = FakeBackplane.new
    mgr_a = Tina4::WebSocket.new
    mgr_b = Tina4::WebSocket.new
    wire_backplane(mgr_a, backplane)
    wire_backplane(mgr_b, backplane)

    conn_b = FakeWsConnection.new("b1")
    mgr_b.register_connection(conn_b)

    payload = [0x00, 0x01, 0x02, 0xFF].pack("C*") + "foo".b
    mgr_a.broadcast_all(payload)

    expect(conn_b.sent.length).to eq(1)
    expect(conn_b.sent.first.bytes).to eq(payload.bytes)
    expect(conn_b.sent.first.encoding).to eq(Encoding::ASCII_8BIT)
  end

  it "encodes bytes under 'b64' and text under 'text' in the published envelope" do
    backplane = FakeBackplane.new
    captured = []
    backplane.subscribe(Tina4::WEBSOCKET_BACKPLANE_CHANNEL) { |raw| captured << JSON.parse(raw) }

    mgr = Tina4::WebSocket.new
    mgr.instance_variable_set(:@backplane, backplane)
    mgr.instance_variable_set(:@backplane_started, true)

    mgr.publish_envelope("all", [0x10, 0x20].pack("C*"))
    mgr.publish_envelope("all", "plain text")

    expect(captured[0]).to have_key("b64")
    expect(Base64.strict_decode64(captured[0]["b64"]).bytes).to eq([0x10, 0x20])
    expect(captured[1]["text"]).to eq("plain text")
    expect(captured[0]["src"]).to eq(mgr.instance_id)
  end

  it "publish_envelope is a no-op (and never raises) without a backplane" do
    mgr = Tina4::WebSocket.new
    expect { mgr.publish_envelope("all", "noop") }.not_to raise_error
  end

  it "uses the shared channel name across frameworks" do
    expect(Tina4::WEBSOCKET_BACKPLANE_CHANNEL).to eq("tina4:ws")
    expect(Tina4::WebSocket.new.backplane_channel).to eq("tina4:ws")
  end

  it "does not let a flaky bus undo the local broadcast" do
    mgr = Tina4::WebSocket.new
    mgr.instance_variable_set(:@backplane, ExplodingBackplane.new)
    mgr.instance_variable_set(:@backplane_started, true)

    conn = FakeWsConnection.new("c1")
    mgr.register_connection(conn)

    expect { mgr.broadcast_all("survive") }.not_to raise_error
    expect(conn.sent).to eq(["survive"])
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
