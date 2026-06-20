# frozen_string_literal: true
#
# Lock-in specs for per-route WebSocket authentication (parity with the Python
# master tests/test_websocket_auth.py — see tina4_python/websocket/__init__.py
# ws_token / ws_authorized).
#
# Contract (mirrors GET):
#   - A WS route is PUBLIC by default — no token required, upgrade always
#     accepted (non-breaking).
#   - A SECURED route (declared via Tina4::Router.secure_websocket OR by chaining
#     .secure on Tina4::Router.websocket(...) — BOTH set auth_required) requires a
#     valid JWT on the upgrade. Missing/invalid → the handshake is REFUSED (401,
#     never 101 Switching Protocols).
#   - Token transports (all three): Authorization: Bearer <jwt> header; the
#     Sec-WebSocket-Protocol "bearer, <jwt>" subprotocol (browsers); ?token=<jwt>.
#   - When the client offered the "bearer" subprotocol, the handshake echoes
#     "bearer" back as the accepted subprotocol.
#   - The verified payload is exposed on connection.auth (nil on public routes).

require "spec_helper"
require "socket"

RSpec.describe "Per-route WebSocket authentication" do
  around(:each) do |example|
    saved_secret = ENV["TINA4_SECRET"]
    saved_origins = ENV["TINA4_WS_ALLOWED_ORIGINS"]
    saved_keys = ENV["TINA4_API_KEY"]
    ENV["TINA4_SECRET"] = "ws-auth-spec-secret-0123456789abcdef"
    ENV.delete("TINA4_WS_ALLOWED_ORIGINS") # origin allow-list off so it never interferes
    ENV.delete("TINA4_API_KEY")
    example.run
  ensure
    saved_secret.nil? ? ENV.delete("TINA4_SECRET") : ENV["TINA4_SECRET"] = saved_secret
    saved_origins.nil? ? ENV.delete("TINA4_WS_ALLOWED_ORIGINS") : ENV["TINA4_WS_ALLOWED_ORIGINS"] = saved_origins
    saved_keys.nil? ? ENV.delete("TINA4_API_KEY") : ENV["TINA4_API_KEY"] = saved_keys
  end

  let(:valid_token) { Tina4::Auth.get_token({ "user_id" => 42, "role" => "admin" }) }

  # A standard upgrade env. headers/query are extra rack-style keys to merge.
  def upgrade_env(extra = {})
    {
      "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
      "REQUEST_PATH" => "/ws"
    }.merge(extra)
  end

  # Drive WebSocket#handle_upgrade with a real socket pair and return the raw
  # bytes the server wrote back (the handshake response). When the upgrade is
  # accepted we stub the read side so the frame loop exits immediately without
  # blocking on a real client.
  def run_upgrade(env, auth_required:)
    read_io, write_io = IO.pipe
    # If accepted, the frame loop calls getbyte/read on the socket — feed it a
    # close frame (0x88, 0x00) then EOF so the background thread exits cleanly.
    allow(write_io).to receive(:getbyte).and_return(0x88, 0x00, nil)
    allow(write_io).to receive(:read).and_return("")
    real_write = write_io.method(:write)
    allow(write_io).to receive(:write) { |bytes| real_write.call(bytes) }
    allow(write_io).to receive(:close)

    ws = Tina4::WebSocket.new
    # Capture the connection at :open — the frame loop closes + unregisters it
    # almost immediately (we feed it a close frame), so reading ws.connections
    # after the fact races the teardown. The :open hook fires synchronously
    # while the connection is still live and carries connection.auth.
    opened = nil
    ws.on(:open) { |conn| opened = conn }

    ws.handle_upgrade(env, write_io, auth_required: auth_required)
    sleep 0.05 # let the (accepted) frame-loop thread spin up + exit

    output = begin
      read_io.read_nonblock(8192)
    rescue IO::WaitReadable, EOFError
      ""
    end
    [output, ws, opened]
  ensure
    read_io&.close
    write_io.close rescue nil
  end

  # ── ws_token: three transports ──────────────────────────────

  describe "Tina4.ws_token transports" do
    it "reads the Authorization: Bearer header" do
      expect(Tina4.ws_token("HTTP_AUTHORIZATION" => "Bearer #{valid_token}")).to eq(valid_token)
    end

    it "reads the bearer subprotocol (browser transport)" do
      expect(Tina4.ws_token("HTTP_SEC_WEBSOCKET_PROTOCOL" => "bearer, #{valid_token}")).to eq(valid_token)
    end

    it "reads the ?token= query param" do
      expect(Tina4.ws_token("QUERY_STRING" => "token=#{valid_token}&foo=bar")).to eq(valid_token)
    end

    it "accepts an explicit query_string argument" do
      expect(Tina4.ws_token({}, "token=#{valid_token}")).to eq(valid_token)
    end

    it "returns nil when no token is present" do
      expect(Tina4.ws_token({})).to be_nil
      expect(Tina4.ws_token("HTTP_SEC_WEBSOCKET_PROTOCOL" => "chat")).to be_nil
    end

    it "prefers the header over the subprotocol over the query" do
      env = {
        "HTTP_AUTHORIZATION" => "Bearer header-token",
        "HTTP_SEC_WEBSOCKET_PROTOCOL" => "bearer, subproto-token",
        "QUERY_STRING" => "token=query-token"
      }
      expect(Tina4.ws_token(env)).to eq("header-token")
    end
  end

  # ── ws_authorized: the gate ─────────────────────────────────

  describe "Tina4.ws_authorized" do
    it "passes a PUBLIC route with no token (payload nil, ok true)" do
      payload, ok = Tina4.ws_authorized(false, {})
      expect(ok).to be true
      expect(payload).to be_nil
    end

    it "REJECTS a secured route with no token" do
      payload, ok = Tina4.ws_authorized(true, {})
      expect(ok).to be false
      expect(payload).to be_nil
    end

    it "REJECTS a secured route with an invalid token" do
      payload, ok = Tina4.ws_authorized(true, "HTTP_AUTHORIZATION" => "Bearer not.a.real.jwt")
      expect(ok).to be false
      expect(payload).to be_nil
    end

    it "ACCEPTS a secured route with a valid header token (exposes payload)" do
      payload, ok = Tina4.ws_authorized(true, "HTTP_AUTHORIZATION" => "Bearer #{valid_token}")
      expect(ok).to be true
      expect(payload["user_id"]).to eq(42)
    end

    it "ACCEPTS a secured route with a valid bearer-subprotocol token" do
      payload, ok = Tina4.ws_authorized(true, "HTTP_SEC_WEBSOCKET_PROTOCOL" => "bearer, #{valid_token}")
      expect(ok).to be true
      expect(payload["role"]).to eq("admin")
    end

    it "ACCEPTS a secured route with a valid ?token= query token" do
      payload, ok = Tina4.ws_authorized(true, { "QUERY_STRING" => "token=#{valid_token}" })
      expect(ok).to be true
      expect(payload["user_id"]).to eq(42)
    end
  end

  # ── handle_upgrade: handshake REFUSED vs ACCEPTED ───────────

  describe "WebSocket#handle_upgrade enforces auth on the handshake" do
    it "ACCEPTS a public route handshake with no token" do
      output, ws = run_upgrade(upgrade_env, auth_required: false)
      expect(output).to include("101 Switching Protocols")
      expect(output).not_to include("401")
    end

    it "REFUSES (401, not 101) a secured handshake with no token" do
      output, ws = run_upgrade(upgrade_env, auth_required: true)
      expect(output).to include("401 Unauthorized")
      expect(output).not_to include("101 Switching Protocols")
      expect(ws.connections).to be_empty
    end

    it "REFUSES (401, not 101) a secured handshake with an invalid token" do
      env = upgrade_env("HTTP_AUTHORIZATION" => "Bearer garbage.token.here")
      output, ws = run_upgrade(env, auth_required: true)
      expect(output).to include("401 Unauthorized")
      expect(output).not_to include("101 Switching Protocols")
      expect(ws.connections).to be_empty
    end

    it "ACCEPTS a secured handshake with a valid Authorization header token" do
      env = upgrade_env("HTTP_AUTHORIZATION" => "Bearer #{valid_token}")
      output, ws = run_upgrade(env, auth_required: true)
      expect(output).to include("101 Switching Protocols")
    end

    it "ACCEPTS a secured handshake with a valid ?token= query token" do
      env = upgrade_env("QUERY_STRING" => "token=#{valid_token}")
      output, ws = run_upgrade(env, auth_required: true)
      expect(output).to include("101 Switching Protocols")
    end

    it "ACCEPTS a secured handshake with a valid bearer subprotocol and ECHOES 'bearer'" do
      env = upgrade_env("HTTP_SEC_WEBSOCKET_PROTOCOL" => "bearer, #{valid_token}")
      output, ws = run_upgrade(env, auth_required: true)
      expect(output).to include("101 Switching Protocols")
      # Browser transport: the accepted subprotocol must be echoed back.
      expect(output).to match(/Sec-WebSocket-Protocol:\s*bearer/i)
    end

    it "does NOT echo a subprotocol when none was offered" do
      env = upgrade_env("HTTP_AUTHORIZATION" => "Bearer #{valid_token}")
      output, ws = run_upgrade(env, auth_required: true)
      expect(output).not_to match(/Sec-WebSocket-Protocol/i)
    end

    it "exposes the verified payload on connection.auth (secured route)" do
      env = upgrade_env("HTTP_AUTHORIZATION" => "Bearer #{valid_token}")
      _output, _ws, conn = run_upgrade(env, auth_required: true)
      expect(conn).not_to be_nil
      expect(conn.auth).to be_a(Hash)
      expect(conn.auth["user_id"]).to eq(42)
    end

    it "leaves connection.auth nil on a public route" do
      _output, _ws, conn = run_upgrade(upgrade_env, auth_required: false)
      expect(conn).not_to be_nil
      expect(conn.auth).to be_nil
    end
  end

  # ── BOTH ways of declaring a secured WS route set the flag ──

  describe "declaring a secured WebSocket route" do
    before(:each) { Tina4::Router.ws_routes.clear }
    after(:each)  { Tina4::Router.ws_routes.clear }

    it "is PUBLIC by default (mirrors GET)" do
      route = Tina4::Router.websocket("/public-ws") { |_c, _e, _d| }
      expect(route.auth_required).to be false
    end

    it "sets auth_required via the declarative Tina4::Router.secure_websocket" do
      route = Tina4::Router.secure_websocket("/secret-ws") { |_c, _e, _d| }
      expect(route.auth_required).to be true
    end

    it "sets auth_required via the declarative secure: true keyword" do
      route = Tina4::Router.websocket("/secret-kw", secure: true) { |_c, _e, _d| }
      expect(route.auth_required).to be true
    end

    it "sets auth_required via the imperative .secure chain" do
      route = Tina4::Router.websocket("/chain-ws") { |_c, _e, _d| }.secure
      expect(route.auth_required).to be true
    end

    it "supports the Tina4.secure_websocket top-level helper" do
      route = Tina4.secure_websocket("/top-secret") { |_c, _e, _d| }
      expect(route.auth_required).to be true
    end

    it ".no_auth flips a secured route back to public" do
      route = Tina4::Router.secure_websocket("/toggle-ws") { |_c, _e, _d| }.no_auth
      expect(route.auth_required).to be false
    end

    it "Tina4::WebSocket.route can declare a secured route" do
      Tina4::WebSocket.route("/ws-route-secure", secure: true) { |_conn| }
      ws_route, = Tina4::Router.find_ws_route("/ws-route-secure")
      expect(ws_route.auth_required).to be true
    end
  end
end
