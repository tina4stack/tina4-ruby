# frozen_string_literal: true

# Feature 128 -- dual development/test port (the "AI port" at base + 1000).
#
# While a developer edits code, the main dev port hot-reloads. In debug mode
# Tina4 also opens a SECOND listener at base + 1000 serving the identical app
# with the reload signal turned off -- a stable connection for an AI agent, a
# test runner, or an MCP session. See
# tina4-documentation/plan/v3/features/128-dual-test-port.md and
# tina4-documentation/plan/v3/OWNER-DECISIONS.md (DUALPORT-DEC-01/02).
#
# DUALPORT-DEC-01 (DUALPORT-TEST-GAP): before this suite, the bound
# base + 1000 port had NO real test in Ruby -- 8 existing specs each force
# TINA4_NO_AI_PORT=true in their own boot env (compression_etag_contract_spec,
# test_client_pipeline_spec, dev_reload_ws_spec, dev_admin_queue_store_spec,
# graceful_shutdown_spec, dev_admin_run_chips_spec, scaffold_tina4js_wiring_spec,
# server_parity_spec) -- none of them is touched here; this is a NEW spec that
# simply never sets that var. Node's test/aiPortRange.test.ts was the only real
# dual-port test in any of the four frameworks. This suite ports that shape:
# boot a REAL child server (Tina4::WebServer -- the same WEBrick path
# Tina4.run!/`tina4ruby serve` take in debug mode) with TINA4_DEBUG=true and
# assert, over REAL sockets:
#
#   1. base + 1000 accepts a connection and serves the SAME app (a known
#      route -- /health, auto-registered by Tina4.initialize! -- returns its
#      real body).
#   2. a reload-WebSocket UPGRADE on base + 1000 is REFUSED (404, not 101).
#   3. TINA4_NO_AI_PORT=true leaves ONLY the base port listening.
#   4. a BUSY base + 1000 (pre-bound by this spec, before the child even
#      starts) yields "Test Port: SKIPPED" and the base port still serves --
#      non-fatal skip, deliberately the OPPOSITE of the main port's takeover
#      (feature 129).
#
# DUALPORT-STABLE-SEMANTICS: "stable" means the CONNECTION and the reload
# SIGNAL are stable, not a pinned code version -- a hot-reload via
# /__dev/api/reload is reflected on base + 1000 too, on the very next request
# there.
#
# NO MOCKS: a real spawned `ruby app.rb` process in its own process group
# (spec/support/shutdown_probe.rb -- the same harness the graceful-shutdown
# specs use), real TCP sockets, and a real raw RFC 6455 upgrade handshake.
#
# Case names (shared with Python/PHP/Node --
# tina4-documentation/plan/v3/fixtures/dual_port_contract.json):
#   - debug_mode_opens_the_ai_port_at_base_plus_1000
#   - the_ai_port_refuses_a_reload_websocket_upgrade
#   - no_ai_port_env_leaves_only_the_base_port
#   - a_busy_ai_port_is_skipped_without_failing_the_base_port
#
# Mutation-proved (2026-08-13, macOS + the Linux lab): temporarily changing
# WebServer#start's gate from `is_debug && !no_ai_port` to `is_debug` (ignoring
# TINA4_NO_AI_PORT) turns "no_ai_port_env_leaves_only_the_base_port" RED -- the
# AI port opens anyway. Reverted.

require "spec_helper"
require "socket"
require "net/http"
require "timeout"
require "fileutils"
require "securerandom"
require_relative "support/shutdown_probe"

module DualPortProbe
  Server = ShutdownProbe::Server

  module_function

  def free_port
    ShutdownProbe.free_port
  end

  # A free base port whose derived AI port (base + 1000) is still legal.
  def free_base_with_headroom
    20.times do
      candidate = free_port
      return candidate if candidate + 1000 <= 65_535
    end
    raise "could not find a free base port with room for +1000"
  end

  # The child app: the framework's OWN Tina4::WebServer (WEBrick), which is
  # what wires the AI dual-port logic to the live listening socket -- the
  # SAME path Tina4.run!/`tina4ruby serve` take in debug mode. No custom
  # routes are registered: /health is auto-registered by Tina4.initialize!,
  # which is enough to prove "the AI port serves the SAME real app".
  def write_app(dir)
    lib = ShutdownProbe.worktree_lib
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"

      loaded_from = $LOADED_FEATURES.find { |feature| feature.end_with?("/tina4.rb") }
      unless loaded_from.to_s.start_with?(#{lib.inspect})
        abort("loaded the WRONG tina4: \#{loaded_from} (expected #{lib})")
      end

      Tina4.initialize!(#{dir.inspect})
      application = Tina4::RackApp.new(root_dir: #{dir.inspect})
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot(port: nil, ai_port: true)
    dir = SpecTmpdir.create("tina4-dual-port")
    port ||= free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env(
      "TINA4_DEBUG" => "true",
      "TINA4_OVERRIDE_CLIENT" => "true",
      "TINA4_NO_AI_PORT" => ai_port ? nil : "true",
      "PROBE_PORT" => port.to_s
    )

    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    Server.new(pid, port, dir, log_path).wait_until_serving!("/health")
  end

  # Real RFC 6455 upgrade request; returns the response's first status line.
  # Never completes the handshake -- the whole point is proving a refusal.
  def ws_upgrade_status_line(host, port, path, timeout: 5)
    sock = Socket.tcp(host, port, connect_timeout: timeout)
    key = [SecureRandom.random_bytes(16)].pack("m0")
    request = "GET #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    sock.write(request)

    raw = +""
    begin
      Timeout.timeout(timeout) { raw << sock.readpartial(4096) while raw.empty? }
    rescue EOFError, Timeout::Error
      # whatever we got is the answer
    end
    sock.close
    raw.lines.first.to_s.strip
  end
end

require "securerandom"

RSpec.describe "Dual development/test port (feature 128)", :slow do
  after(:each) { @server&.destroy! }

  it "debug mode opens the ai port at base plus 1000" do
    @server = DualPortProbe.boot(ai_port: true)

    status, body = @server.get("/health")
    expect(status).to eq(200), "AI port not reachable via main-port probe: #{@server.log}"

    uri = URI("http://127.0.0.1:#{@server.port + 1000}/health")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) { |http| http.get(uri.path) }
    expect(response.code.to_i).to eq(200), "AI port /health -> #{response.code}\n#{@server.log}"
    expect(response.body).to include("tina4-ruby"), "AI port must serve the SAME real app: #{response.body}"
  end

  it "the ai port refuses a reload websocket upgrade" do
    # Two REAL, DIFFERENT mechanisms both refuse, and this proves both:
    #
    # 1. Tina4::WebServer is WEBrick, which offers NO rack.hijack at all
    #    (Ruby CLAUDE.md: "WS upgrades need a hijack-capable server (Puma);
    #    under WEBrick the upgrade is rejected"). A REAL RFC 6455 upgrade
    #    request to /__dev_reload is matched as a WS ROUTE first (it IS
    #    registered in debug mode) and handle_websocket_upgrade refuses with
    #    426 for lack of rack.hijack -- on BOTH ports alike, main included.
    #    It never reaches 101 on the AI port, which is the literal claim.
    #
    # 2. The AI-port-SPECIFIC gate (RackApp::DispatchPipeline#dev_routes) is
    #    real and separately provable with a PLAIN (non-upgrade) GET, which
    #    Router.find_ws_route does not intercept: the AI port answers 404
    #    "Not available on AI port" while the SAME request on the MAIN port
    #    gets the app's ordinary 404 page -- proving the AI-port suppression
    #    is a real, wired, AI-port-SPECIFIC branch, not the blanket WEBrick
    #    hijack refusal in disguise.
    @server = DualPortProbe.boot(ai_port: true)

    status_line = DualPortProbe.ws_upgrade_status_line("127.0.0.1", @server.port + 1000, "/__dev_reload")
    expect(status_line).not_to include("101"), "AI port must NOT upgrade the reload WebSocket: #{status_line}"

    ai_plain = Net::HTTP.start("127.0.0.1", @server.port + 1000, open_timeout: 5, read_timeout: 5) do |http|
      http.get("/__dev_reload")
    end
    expect(ai_plain.code.to_i).to eq(404)
    expect(ai_plain.body).to include("Not available on AI port"),
                             "the AI-port gate must answer distinctly: #{ai_plain.body}"

    main_plain = Net::HTTP.start("127.0.0.1", @server.port, open_timeout: 5, read_timeout: 5) do |http|
      http.get("/__dev_reload")
    end
    expect(main_plain.body).not_to include("Not available on AI port"),
                                    "the MAIN port must not be tagged as the AI port"
  end

  it "no ai port env leaves only the base port" do
    @server = DualPortProbe.boot(ai_port: false)

    status, = @server.get("/health")
    expect(status).to eq(200), "base port must serve: #{@server.log}"

    probe = begin
      Socket.tcp("127.0.0.1", @server.port + 1000, connect_timeout: 1)
    rescue StandardError
      nil
    end
    expect(probe).to be_nil, "TINA4_NO_AI_PORT=true must leave NOTHING listening on base + 1000"
    probe&.close
  end

  it "a busy ai port is skipped without failing the base port" do
    base = DualPortProbe.free_base_with_headroom
    blocker = TCPServer.new("127.0.0.1", base + 1000)

    begin
      @server = DualPortProbe.boot(port: base, ai_port: true)

      status, = @server.get("/health")
      expect(status).to eq(200), "base port must still serve when the AI port is busy: #{@server.log}"

      log = @server.log
      expect(log).to include((base + 1000).to_s), "warning must name the busy port; log: #{log}"
      expect(log.downcase).to match(/skip/), "a busy AI port must warn + skip, never fail the base port; log: #{log}"
      expect(log.downcase).to match(/in use/), "log: #{log}"

      # Our own blocker is still the one holding the port -- the server never
      # touched it.
      probe = Socket.tcp("127.0.0.1", base + 1000, connect_timeout: 1)
      probe.close
    ensure
      blocker.close
    end
  end
end
