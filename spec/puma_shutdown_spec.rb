# frozen_string_literal: true

# Graceful shutdown on the PRODUCTION path (Puma).
#
# spec/graceful_shutdown_spec.rb covers the development path (WEBrick). In
# production Ruby never reaches WEBrick: Tina4.run! and the CLI's `serve
# --production` both hand off to Puma, and puma is a hard dependency in
# tina4ruby.gemspec, so the LoadError fallback effectively never fires.
#
# Feature 9's OUTCOMES are the framework's contract whichever server owns the
# socket; the MECHANISM differs. Puma already stops accepting and drains, so
# that is CONFIGURED (force_shutdown_after, raise_exception_on_sigterm) rather
# than reimplemented. What Puma cannot know about - ORM-bound database
# connections, Tina4 background threads, WebSocket peers owed an RFC 6455 close
# frame - is ours, and runs in an ensure around the launcher.
#
# Everything here is real: a real `tina4ruby serve --production` child in its
# own process group, real SQLite databases, real sockets, a real SIGTERM, and
# the real exit status.

require "spec_helper"
require "json"
require "socket"
require "securerandom"
require "timeout"
require "tmpdir"
require "fileutils"
require_relative "support/shutdown_probe"

module PumaShutdownProbe
  module_function

  def exe_path
    File.expand_path("../exe/tina4ruby", __dir__)
  end

  # The app's boot code, discovered from src/routes exactly as a real app's is.
  def write_project(dir)
    routes = File.join(dir, "src", "routes")
    FileUtils.mkdir_p(routes)
    File.write(File.join(routes, "probe.rb"), <<~RUBY)
      require "json"

      PROBE_DIR = #{dir.inspect}

      # Fail LOUD if this process resolved an INSTALLED tina4ruby gem instead of
      # the working tree: several stale versions are on the box, they boot and
      # serve happily, and a path slip would turn this whole spec into a green
      # test of RELEASED code. Assert on the resolved source file of a Tina4
      # method, not on $LOAD_PATH order.
      loaded_from = Tina4::Shutdown.method(:release_resources).source_location.first
      unless loaded_from.to_s.start_with?(#{ShutdownProbe.worktree_lib.inspect})
        abort("loaded the WRONG tina4: \#{loaded_from}")
      end

      # A REAL second database, registered the documented way, so shutdown has
      # both a default connection and a NAMED one to close.
      Tina4.bind_database(Tina4::Database.new("sqlite://\#{PROBE_DIR}/analytics.db"), name: :analytics)

      Tina4.get "/ping" do |request, response|
        response.json({ pong: true })
      end

      # Proves BOTH connections are genuinely live BEFORE the signal, so the
      # post-shutdown "closed" assertion means something.
      Tina4.get "/dbcheck" do |request, response|
        response.json({
          default: Tina4.database.fetch_one("SELECT 1 AS one")[:one],
          analytics: Tina4.databases[:analytics].fetch_one("SELECT 2 AS two")[:two]
        })
      end

      Tina4.get "/slow" do |request, response|
        File.write(File.join(PROBE_DIR, "slow_started"), Process.pid.to_s)
        # WALL-CLOCK bounded, deliberately NOT one sleep: a signal makes a
        # blocking sleep return early (EINTR), which truncates the handler and
        # makes an interrupted request look like a drained one.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   Float(ENV.fetch("PROBE_SLOW_SECONDS", "2.0"))
        sleep(0.02) while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        response.json({ slow: true })
      end

      Tina4::WebSocket.route("/ws") do |connection|
        File.write(File.join(PROBE_DIR, "ws_open"), connection.id)
      end

      # Observe the REAL post-shutdown state of every connection and report it
      # out of band. at_exit runs after start_puma_server's ensure, so a
      # connection that is still usable here was never closed.
      at_exit do
        state = {}
        [["default", Tina4.database], *Tina4.databases.map { |name, db| [name.to_s, db] }].each do |(name, db)|
          next if db.nil?

          state[name] = begin
            db.fetch_one("SELECT 1 AS one")
            "USABLE"
          rescue StandardError => e
            "CLOSED:\#{e.class}"
          end
        end
        File.write(File.join(PROBE_DIR, "db_state.json"), JSON.generate(state))
      end
    RUBY
    dir
  end

  def boot(slow_seconds: 2.0, shutdown_timeout: nil, pin_builtin: false)
    dir = SpecTmpdir.create("tina4-puma-shutdown")
    write_project(dir)
    port = ShutdownProbe.free_port
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env(
      "PROBE_DIR" => dir,
      "PROBE_SLOW_SECONDS" => slow_seconds.to_s,
      "TINA4_DATABASE_URL" => "sqlite://#{dir}/app.db",
      "TINA4_SHUTDOWN_TIMEOUT" => shutdown_timeout&.to_s,
      "TINA4_DEFAULT_WEBSERVER" => (pin_builtin ? "TRUE" : nil),
      # Only the built-in WEBrick server enforces this; harmless for Puma.
      "TINA4_OVERRIDE_CLIENT" => "true"
    )

    pid = spawn(child_env, RbConfig.ruby, exe_path, "serve", "--production",
                "--host", "127.0.0.1", "--port", port.to_s, "--no-browser",
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!
  end
end

RSpec.describe "Graceful shutdown (production / Puma)", :slow do
  before(:all) do
    require "puma"
  rescue LoadError
    # Loud on purpose: puma is a hard dependency in tina4ruby.gemspec, so its
    # absence is a broken install, not a reason to quietly pass.
    skip "the puma gem is NOT installed, so the production shutdown path cannot " \
         "be exercised at all (tina4ruby.gemspec declares puma ~> 6.0 as a hard dependency)"
  end

  describe "SIGTERM" do
    before(:all) do
      @server = PumaShutdownProbe.boot(slow_seconds: 2.0)
      @dbcheck_status, @dbcheck_body = @server.get("/dbcheck")
      @request = @server.start_request("/slow")
      @server.wait_until_handling!
      @server.signal("TERM")
      @response = @request.value
      @status = @server.wait_for_exit(30)
      @db_state = @server.read_file("db_state.json")
      @log = @server.log
    end

    after(:all) { @server&.destroy! }

    it "serves both databases before the signal" do
      expect(@dbcheck_status).to eq(200), "/dbcheck failed: #{@dbcheck_body.inspect}\n#{@log}"
      expect(JSON.parse(@dbcheck_body)).to eq("default" => 1, "analytics" => 2)
    end

    it "lets the in-flight request finish" do
      expect(@response[:status]).to eq(200),
                                    "in-flight request did not complete: #{@response.inspect}\n#{@log}"
      expect(@response[:seconds]).to be >= 1.9
    end

    it "exits with code 0" do
      expect(@status).not_to be_nil, "process did not exit within 30s of SIGTERM\n#{@log}"
      expect(@status.signaled?).to be(false),
                                   "the process was terminated BY the signal instead of exiting " \
                                   "cleanly (Puma's raise_exception_on_sigterm defaults to true)\n#{@log}"
      expect(@status.exitstatus).to eq(0)
    end

    it "closes every database connection, default and named" do
      expect(@db_state).not_to be_nil, "the child never wrote db_state.json\n#{@log}"
      state = JSON.parse(@db_state)
      expect(state.keys).to contain_exactly("default", "analytics")
      expect(state["default"]).to start_with("CLOSED"),
                                  "the DEFAULT database connection was still usable after shutdown " \
                                  "- it leaked: #{state.inspect}\n#{@log}"
      expect(state["analytics"]).to start_with("CLOSED"),
                                    "the NAMED database connection was still usable after shutdown " \
                                    "- it leaked: #{state.inspect}\n#{@log}"
      expect(@log).to include("Database connections closed (2)")
    end
  end

  it "TINA4_SHUTDOWN_TIMEOUT bounds the production drain" do
    server = PumaShutdownProbe.boot(slow_seconds: 6.0, shutdown_timeout: 1)
    begin
      request = server.start_request("/slow", read_timeout: 20)
      server.wait_until_handling!

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.signal("TERM")
      status = server.wait_for_exit(15)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      request.value # reap; the in-flight request is deliberately cut short here

      expect(status).not_to be_nil,
                            "TINA4_SHUTDOWN_TIMEOUT=1 did not bound the drain - the process was " \
                            "still alive 15s after SIGTERM\n#{server.log}"
      expect(elapsed).to be < 4.0,
                         "expected the 1s timeout to end the drain well before the 6s handler, " \
                         "took #{elapsed.round(2)}s (is force_shutdown_after wired to " \
                         "TINA4_SHUTDOWN_TIMEOUT? Puma's default is :forever)\n#{server.log}"
    ensure
      server.destroy!
    end
  end

  it "sends RFC 6455 close code 1001 to live WebSocket connections" do
    server = PumaShutdownProbe.boot(slow_seconds: 0.2)
    socket = nil
    begin
      socket = TCPSocket.new("127.0.0.1", server.port)
      key = [SecureRandom.bytes(16)].pack("m0")
      socket.write("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{server.port}\r\n" \
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")

      headers = +""
      Timeout.timeout(15) { headers << socket.readpartial(1) until headers.end_with?("\r\n\r\n") }
      expect(headers).to start_with("HTTP/1.1 101"), "upgrade rejected: #{headers.inspect}"
      server.wait_for_file!("ws_open")

      server.signal("TERM")

      frame = Timeout.timeout(20) do
        header = socket.read(1)
        expect(header).not_to be_nil,
                              "the WebSocket socket closed with NO close frame - the peer was " \
                              "never told the server was going away\n#{server.log}"
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
    ensure
      socket&.close
      server.destroy!
    end
  end

  # TINA4_DEFAULT_WEBSERVER is NOT the remedy for a production shutdown problem
  # - an operator must never have to give up Puma to get their databases closed.
  # It is a deterministic way to pin the built-in server (e.g. in CI) without
  # having to switch TINA4_DEBUG on to get there.
  it "TINA4_DEFAULT_WEBSERVER=TRUE pins the built-in server even with --production" do
    server = PumaShutdownProbe.boot(slow_seconds: 0.2, pin_builtin: true)
    begin
      status, = server.get("/ping")
      expect(status).to eq(200), "the pinned built-in server did not serve\n#{server.log}"
      expect(server.log).to include("Development server: WEBrick")
      expect(server.log).not_to include("Production server: puma")

      server.signal("TERM")
      expect(server.wait_for_exit(25)&.exitstatus).to eq(0)
    ensure
      server.destroy!
    end
  end

  it "leaves the production path unpinned by default" do
    server = PumaShutdownProbe.boot(slow_seconds: 0.2)
    begin
      expect(server.log).to include("Production server: puma"),
                            "--production must still choose Puma when TINA4_DEFAULT_WEBSERVER " \
                            "is unset\n#{server.log}"
    ensure
      server.destroy!
    end
  end
end
