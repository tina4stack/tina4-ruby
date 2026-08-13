# frozen_string_literal: true

# Graceful shutdown — REAL process, REAL socket, REAL signal.
#
# spec/shutdown_spec.rb unit-tests the bookkeeping (track_request, the
# shutting_down? flag) by calling the module directly. It never sends a signal,
# so it proves nothing about signal handling: the trap could be missing entirely
# and it would still be green. These specs spawn a real `ruby app.rb` server in
# its own process group, issue a real slow HTTP request over a real socket, send
# a real signal to that process, and observe the real outcome and exit status.
#
# The contract under test (identical in all four Tina4 frameworks):
#
#   1. SIGTERM and SIGINT are trapped and run the same graceful shutdown.
#   2. SIGHUP is deliberately NOT trapped.
#   3. The listening socket stops accepting FIRST — a connection arriving after
#      the signal gets a clean CONNECTION REFUSED, not a 503 and not a reset.
#   4. In-flight requests are drained: a request already being handled runs to
#      completion and its full response is written.
#   5. The drain is bounded by TINA4_SHUTDOWN_TIMEOUT (default 30s).
#   6. Background tasks are stopped and DB connections closed before exit.
#   7. Exit code 0 on a clean drained shutdown.
#
# Process hygiene: the child's stdout/stderr go to a FILE (an inherited fd
# wedges a piped rspec run forever) and every server is killed by PROCESS GROUP
# in an ensure/after hook.

require "spec_helper"
require "socket"
require "net/http"
require "timeout"
require "tmpdir"
require "fileutils"
require "securerandom"
require_relative "support/shutdown_probe"

module GracefulShutdownProbe
  SLOW_PATH = "/slow"
  PING_PATH = "/ping"

  # The spawned server, signal/exit plumbing and process-GROUP cleanup live in
  # spec/support/shutdown_probe.rb - shared with spec/puma_shutdown_spec.rb so
  # both paths are exercised by identical machinery.
  Server = ShutdownProbe::Server

  module_function

  def free_port
    ShutdownProbe.free_port
  end

  # The child app. Routes are registered in-process (no src/routes discovery
  # needed) and the server is the framework's own Tina4::WebServer (WEBrick),
  # which is what wires Tina4::Shutdown to the live listening socket.
  def write_app(dir)
    lib = ShutdownProbe.worktree_lib
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      # Restore the DEFAULT disposition for signals a launcher may have set to
      # SIG_IGN. SIG_IGN is inherited across fork AND preserved across exec, so
      # this child inherits whatever launched rspec. The lab runner uses
      # `setsid nohup`, and nohup ignores HUP/INT/QUIT - measured on the running
      # suite process as `SigIgn: 0000000000000007` (bits 0,1,2).
      #
      # Without this, "SIGHUP is not trapped and terminates the process" sent
      # SIGHUP to a child that had inherited SIG_IGN, nothing happened, and the
      # spec failed on Linux while passing on macOS, where the suite is not run
      # under nohup. It looked like a framework difference; it was the harness.
      #
      # This runs BEFORE `require "tina4"`, so a real framework trap installed
      # later still wins and the spec still detects it. Only the inherited
      # IGNORE is cleared, never a deliberate handler.
      %w[HUP INT QUIT].each do |sig|
        begin
          Signal.trap(sig, "DEFAULT")
        rescue ArgumentError
          # signal not available on this platform
        end
      end

      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"

      # Fail LOUD if the child resolved an INSTALLED tina4ruby gem instead of
      # this working tree. A stale gem is on the box, its Tina4::Shutdown is the
      # pre-fix one, and it boots and serves happily - so without this guard a
      # path slip turns the whole spec into a green test of released code.
      loaded_from = $LOADED_FEATURES.find { |feature| feature.end_with?("/tina4.rb") }
      unless loaded_from.to_s.start_with?(#{lib.inspect})
        abort("loaded the WRONG tina4: #{'#{loaded_from}'} (expected #{lib})")
      end

      PROJECT_DIR = #{dir.inspect}
      SLOW_SECONDS = Float(ENV.fetch("PROBE_SLOW_SECONDS", "2.0"))

      Tina4.initialize!(PROJECT_DIR)

      Tina4.get "#{PING_PATH}" do |request, response|
        response.json({ pong: true })
      end

      Tina4.get "#{SLOW_PATH}" do |request, response|
        File.write(File.join(PROJECT_DIR, "slow_started"), Process.pid.to_s)
        # WALL-CLOCK bounded, deliberately NOT one sleep: a signal makes a
        # blocking sleep return early (EINTR), which truncates the handler and
        # makes an interrupted request look like a drained one.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SLOW_SECONDS
        sleep(0.02) while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        File.write(File.join(PROJECT_DIR, "slow_finished"), Process.pid.to_s)
        response.json({ slow: true, seconds: SLOW_SECONDS })
      end

      application = Tina4::RackApp.new(root_dir: PROJECT_DIR)

      # A real WebSocket peer, upgraded by the real framework onto the real
      # process-wide manager RackApp just published (Tina4::WebSocket.current).
      # WebSocket upgrades need rack.hijack, which WEBrick does not provide, so
      # the socket is accepted here instead of by the HTTP server - everything
      # from the handshake onward is the framework's own code path.
      if ENV["PROBE_WS_PORT"]
        Thread.new do
          listener = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PROBE_WS_PORT")))
          loop do
            client = listener.accept
            request = +""
            request << client.readpartial(1) until request.end_with?("\\r\\n\\r\\n")
            env = { "REQUEST_PATH" => request.lines.first.to_s.split(" ")[1].to_s }
            request.lines.drop(1).each do |line|
              name, value = line.split(":", 2)
              next if value.nil?

              env["HTTP_" + name.strip.upcase.tr("-", "_")] = value.strip
            end
            engine = Tina4::WebSocket.current
            engine.handle_upgrade(env, client, manager: engine)
            File.write(File.join(PROJECT_DIR, "ws_open"), engine.connections.size.to_s)
          end
        end
      end

      if ENV["PROBE_BACKGROUND"] == "true"
        Tina4::Background.register(interval: 0.2) do
          File.write(File.join(PROJECT_DIR, "background_tick"), Time.now.to_f.to_s)
        end
      end

      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot(slow_seconds: 2.0, shutdown_timeout: nil, background: false, websocket_port: nil)
    dir = SpecTmpdir.create("tina4-graceful-shutdown")
    port = free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")

    child_env = {
      "TINA4_OVERRIDE_CLIENT" => "true",
      "TINA4_DEBUG" => "false",
      "TINA4_NO_AI_PORT" => "true",
      "TINA4_LOG_LEVEL" => "INFO",
      "TINA4_DEBUG_LEVEL" => nil,
      "TINA4_SHUTDOWN_TIMEOUT" => shutdown_timeout&.to_s,
      "PROBE_PORT" => port.to_s,
      "PROBE_SLOW_SECONDS" => slow_seconds.to_s,
      "PROBE_BACKGROUND" => background.to_s,
      "PROBE_WS_PORT" => websocket_port&.to_s,
      # The throwaway project has no Gemfile, so a child still honouring the
      # parent's Bundler env fails to boot. nil deletes the key.
      "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil,
      "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8"
    }

    # pgroup: true → the child leads its own process group, so cleanup can kill
    # the GROUP and never orphan anything it spawned.
    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    Server.new(pid, port, dir, log_path).wait_until_serving!
  end
end

RSpec.describe "Graceful shutdown", :slow do
  # ── SIGTERM ────────────────────────────────────────────────────────────
  #
  # One real signal drives all four SIGTERM assertions: boot, start a 2s
  # request, wait until the handler is genuinely running, SIGTERM, then observe
  # the new-connection outcome, the in-flight response, the exit status and the
  # port.
  describe "SIGTERM" do
    before(:all) do
      @server = GracefulShutdownProbe.boot(slow_seconds: 2.0)
      @request = @server.start_request(GracefulShutdownProbe::SLOW_PATH)
      @server.wait_until_handling!
      @server.signal("TERM")
      sleep 0.4 # let the signal land and the listener close
      @connection = @server.probe_connection
      @response = @request.value
      @status = @server.wait_for_exit(25)
      @port_free = @server.port_free?
      @log = @server.log
    end

    after(:all) { @server&.destroy! }

    it "SIGTERM lets the in-flight request finish" do
      expect(@response[:status]).to eq(200),
                                    "in-flight request did not complete: #{@response.inspect}\n#{@log}"
      expect(@response[:body]).to include('"slow"')
      expect(@response[:seconds]).to be >= 1.9
    end

    it "SIGTERM stops accepting new connections" do
      expect(@connection[:outcome]).to eq(:refused),
                                       "a connection arriving after SIGTERM must be REFUSED " \
                                       "(the listener closes first), got: #{@connection.inspect}"
    end

    it "SIGTERM exits with code 0" do
      expect(@status).not_to be_nil, "process did not exit within 25s of SIGTERM\n#{@log}"
      expect(@status.signaled?).to be(false),
                                   "process was killed BY the signal instead of handling it\n#{@log}"
      expect(@status.exitstatus).to eq(0)
    end

    it "SIGTERM releases the listening port" do
      expect(@port_free).to be(true), "port #{@server.port} was still bound after shutdown"
    end
  end

  # ── SIGINT ─────────────────────────────────────────────────────────────
  describe "SIGINT" do
    before(:all) do
      @server = GracefulShutdownProbe.boot(slow_seconds: 2.0)
      @request = @server.start_request(GracefulShutdownProbe::SLOW_PATH)
      @server.wait_until_handling!
      @server.signal("INT")
      @response = @request.value
      @status = @server.wait_for_exit(25)
      @log = @server.log
    end

    after(:all) { @server&.destroy! }

    it "SIGINT lets the in-flight request finish" do
      expect(@response[:status]).to eq(200),
                                    "in-flight request did not complete: #{@response.inspect}\n#{@log}"
      expect(@response[:body]).to include('"slow"')
      expect(@response[:seconds]).to be >= 1.9
    end

    it "SIGINT exits with code 0" do
      expect(@status).not_to be_nil, "process did not exit within 25s of SIGINT\n#{@log}"
      expect(@status.signaled?).to be(false),
                                   "process was killed BY the signal instead of handling it\n#{@log}"
      expect(@status.exitstatus).to eq(0)
    end
  end

  # ── SIGHUP: deliberately NOT trapped ───────────────────────────────────
  #
  # The Rust CLI owns file watching and production logs go to stdout, so
  # neither Puma's log-reopen nor gunicorn's config-reload use for SIGHUP is a
  # Tina4 need. This pins the non-handling so nobody "fixes" it by accident.
  it "SIGHUP is not trapped and terminates the process" do
    server = GracefulShutdownProbe.boot(slow_seconds: 0.2)
    begin
      server.signal("HUP")
      status = server.wait_for_exit(15)

      expect(status).not_to be_nil, "process survived SIGHUP - is HUP trapped?\n#{server.log}"
      expect(status.signaled?).to be(true),
                                  "SIGHUP was HANDLED (clean exit #{status.exitstatus}); it must not be trapped"
      expect(status.termsig).to eq(Signal.list.fetch("HUP"))
    ensure
      server.destroy!
    end
  end

  # ── Background tasks ───────────────────────────────────────────────────
  it "a registered background task does not block shutdown" do
    server = GracefulShutdownProbe.boot(slow_seconds: 0.2, background: true)
    begin
      # Prove the task thread is really running before signalling.
      server.wait_for_file!("background_tick")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.signal("TERM")
      status = server.wait_for_exit(20)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(status).not_to be_nil,
                            "a registered background task blocked shutdown forever\n#{server.log}"
      expect(status.exitstatus).to eq(0)
      expect(elapsed).to be < 10
      expect(server.log).to include("Background tasks stopped")
    ensure
      server.destroy!
    end
  end

  # ── WebSocket: RFC 6455 close code 1001 "going away" ───────────────────
  #
  # A REAL peer: real TCP socket, real RFC 6455 handshake through the
  # framework's own WebSocket#handle_upgrade, registered on the real
  # process-wide manager, closed by a REAL SIGTERM. The client then parses the
  # real close frame off the wire.
  #
  # Scope of the claim: this proves initiate_shutdown emits a well-formed 1001
  # close frame to every connection on the live manager. It does NOT prove the
  # production Puma path reaches that code - see the Puma finding: Puma's own
  # launcher replaces Tina4's signal handlers, so on that path initiate_shutdown
  # does not run at all today.
  it "SIGTERM sends RFC 6455 close code 1001 to live WebSocket connections" do
    websocket_port = GracefulShutdownProbe.free_port
    server = GracefulShutdownProbe.boot(slow_seconds: 0.2, websocket_port: websocket_port)
    socket = nil
    begin
      socket = TCPSocket.new("127.0.0.1", websocket_port)
      key = [SecureRandom.bytes(16)].pack("m0")
      socket.write("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{websocket_port}\r\n" \
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")

      headers = +""
      Timeout.timeout(15) { headers << socket.readpartial(1) until headers.end_with?("\r\n\r\n") }
      expect(headers).to start_with("HTTP/1.1 101"), "upgrade rejected: #{headers.inspect}"
      server.wait_for_file!("ws_open")

      server.signal("TERM")

      frame = Timeout.timeout(15) do
        header = socket.read(1)
        # nil = EOF: the peer socket was closed without any close frame at all.
        expect(header).not_to be_nil,
                              "WebSocket socket closed with NO close frame - the peer was never " \
                              "told the server was going away\n#{server.log}"
        first = header.bytes.first
        second = socket.read(1).bytes.first
        length = second & 0x7F
        length = socket.read(2).unpack1("n") if length == 126
        length = socket.read(8).unpack1("Q>") if length == 127
        { opcode: first & 0x0F, payload: length.positive? ? socket.read(length) : "" }
      end

      expect(frame[:opcode]).to eq(0x8), "expected an RFC 6455 CLOSE frame, got opcode #{frame[:opcode]}"
      expect(frame[:payload].bytesize).to be >= 2
      expect(frame[:payload].byteslice(0, 2).unpack1("n")).to eq(1001)
      expect(frame[:payload].byteslice(2..)).to eq("going away")

      status = server.wait_for_exit(20)
      expect(status&.exitstatus).to eq(0)
    ensure
      socket&.close
      server.destroy!
    end
  end

  # ── The drain is BOUNDED ───────────────────────────────────────────────
  #
  # 1s timeout against a 6s handler. The in-flight request is expected to be cut
  # short here — that is the whole point of a bound.
  it "TINA4_SHUTDOWN_TIMEOUT bounds the drain" do
    server = GracefulShutdownProbe.boot(slow_seconds: 6.0, shutdown_timeout: 1)
    begin
      request = server.start_request(GracefulShutdownProbe::SLOW_PATH, read_timeout: 20)
      server.wait_until_handling!

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.signal("TERM")
      status = server.wait_for_exit(12)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      request.value # reap the request thread; its outcome is deliberately unasserted

      expect(status).not_to be_nil,
                            "TINA4_SHUTDOWN_TIMEOUT=1 did not bound the drain - " \
                            "process still alive 12s after SIGTERM\n#{server.log}"
      expect(elapsed).to be < 4.0,
                         "expected the 1s timeout to end the drain well before the 6s handler, " \
                         "took #{elapsed.round(2)}s\n#{server.log}"
      expect(server.log).to include("TINA4_SHUTDOWN_TIMEOUT"),
                            "the timeout warning must NAME the timeout\n#{server.log}"
    ensure
      server.destroy!
    end
  end

  # An unparseable TINA4_SHUTDOWN_TIMEOUT used to go through String#to_i, which
  # turns "abc" into 0 - a silent zero-second drain that force-closes every
  # in-flight request on the first signal. It must warn and fall back to 30
  # instead, so this asserts the BEHAVIOUR (the request still drains), not just
  # the log line.
  it "an invalid TINA4_SHUTDOWN_TIMEOUT warns and still drains" do
    server = GracefulShutdownProbe.boot(slow_seconds: 2.0, shutdown_timeout: "not-a-number")
    begin
      request = server.start_request(GracefulShutdownProbe::SLOW_PATH)
      server.wait_until_handling!
      server.signal("TERM")
      response = request.value
      status = server.wait_for_exit(25)

      expect(response[:status]).to eq(200),
                                   "an invalid timeout silently became a 0s drain and cut the " \
                                   "in-flight request: #{response.inspect}\n#{server.log}"
      expect(status&.exitstatus).to eq(0)
      # Format-agnostic (Decision 3): with TINA4_DEBUG=false this server logs
      # JSON by default, where the value's quotes are JSON-escaped
      # (\"not-a-number\") rather than literal — check for the setting name
      # and the bad value as two substrings rather than one literal-quoted
      # string, so this doesn't pin one specific log format.
      expect(server.log).to include("TINA4_SHUTDOWN_TIMEOUT").and(include("not-a-number")),
                            "the fallback must name the bad value\n#{server.log}"
    ensure
      server.destroy!
    end
  end
end
