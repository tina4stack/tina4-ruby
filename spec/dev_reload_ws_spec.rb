# frozen_string_literal: true

# Tests for the WebSocket-primary DevReload path (parity with the Python
# master's tests/test_dev_reload_ws.py).
#
# DevReload is WebSocket-primary: POST /__dev/api/reload re-discovers changed
# route files in-process and then broadcasts an instant reload message to every
# browser connected on /__dev_reload. The mtime poll is only a fallback. These
# specs cover both halves:
#
#   * POST /__dev/api/reload broadcasts a JSON {type, file, mtime} payload on
#     the dev-reload channel (CSS vs code distinction), and never 500s when the
#     broadcast raises or there are zero clients.
#   * The /__dev_reload WebSocket route is registered in debug mode.
#   * A real browser connecting on /__dev_reload receives the broadcast
#     end-to-end against a live Puma server (no Rust CLI — the POST is issued
#     directly, exactly as the CLI watcher does), and the server is not
#     respawned (same PID, V1 -> V2 in-process).

require "spec_helper"
require_relative "support/real_env"
require "json"
require "stringio"
require "socket"
require "securerandom"
require "digest"
require "net/http"
require "timeout"

RSpec.describe "DevReload WebSocket" do
  # A stand-in connection that records the frames a broadcast would send.
  FakeWsConn = Struct.new(:id, :sent) do
    def send_text(message)
      sent << message
    end
  end

  def reload_env(body)
    {
      "PATH_INFO" => "/__dev/api/reload",
      "REQUEST_METHOD" => "POST",
      "rack.input" => StringIO.new(JSON.generate(body))
    }
  end

  before do
    set_real_env("TINA4_DEBUG" => "true")
    # Start each spec with an empty dev-reload manager.
    Tina4::DevReload.manager.connections.clear
  end

  after do
    Tina4::DevReload.manager.connections.clear
  end

  describe "POST /__dev/api/reload broadcast" do
    it "broadcasts type=reload on /__dev_reload with file + mtime for a code change" do
      conn = FakeWsConn.new("c1", [])
      Tina4::DevReload.add(conn)

      status, _headers, body = Tina4::DevAdmin.handle_request(
        reload_env({ "type" => "code", "file" => "src/routes/index.rb" })
      )

      expect(status).to eq(200)
      result = JSON.parse(body.first)
      expect(result["ok"]).to be true
      expect(result["type"]).to eq("code") # HTTP echoes the caller's original type

      expect(conn.sent.size).to eq(1)
      payload = JSON.parse(conn.sent.first)
      expect(payload["type"]).to eq("reload") # code normalised to reload on the wire
      expect(payload["file"]).to eq("src/routes/index.rb")
      expect(payload["mtime"]).to be_an(Integer)
    end

    it "broadcasts type=css so the client swaps stylesheets" do
      conn = FakeWsConn.new("c1", [])
      Tina4::DevReload.add(conn)

      Tina4::DevAdmin.handle_request(
        reload_env({ "type" => "css", "file" => "src/public/css/app.css" })
      )

      expect(conn.sent.size).to eq(1)
      payload = JSON.parse(conn.sent.first)
      expect(payload["type"]).to eq("css")
      expect(payload["file"]).to eq("src/public/css/app.css")
    end

    it "does not 500 when there are zero connected clients" do
      status, _headers, body = Tina4::DevAdmin.handle_request(
        reload_env({ "type" => "code", "file" => "src/routes/x.rb" })
      )
      expect(status).to eq(200)
      expect(JSON.parse(body.first)["ok"]).to be true
    end

    it "does not 500 when a broadcast raises" do
      boom = FakeWsConn.new("boom", [])
      def boom.send_text(_message)
        raise "socket gone"
      end
      Tina4::DevReload.add(boom)

      status, _headers, body = Tina4::DevAdmin.handle_request(
        reload_env({ "type" => "code", "file" => "src/routes/x.rb" })
      )
      expect(status).to eq(200)
      expect(JSON.parse(body.first)["ok"]).to be true
    end
  end

  describe "/__dev_reload route registration" do
    it "registers the WebSocket route so a handshake can match it (debug mode)" do
      Tina4::Router.clear!
      Tina4::RackApp.register_dev_reload_ws
      ws_route, _params = Tina4::Router.find_ws_route("/__dev_reload")
      expect(ws_route).not_to be_nil
      expect(ws_route.path).to eq("/__dev_reload")
    end

    it "is idempotent — registering twice leaves a single route" do
      Tina4::Router.clear!
      Tina4::RackApp.register_dev_reload_ws
      Tina4::RackApp.register_dev_reload_ws
      expect(Tina4::Router.ws_routes.count { |r| r.path == "/__dev_reload" }).to eq(1)
    end
  end

  describe "live end-to-end (Puma)", :slow do
    # Boot a real Puma server (Puma provides rack.hijack, which the WS upgrade
    # requires; WEBrick does not), connect a raw RFC 6455 client, edit a route
    # V1 -> V2, POST the reload the CLI would, and assert the client receives
    # the broadcast, the new code is served in-process, and the PID is stable.
    require "puma"

    def free_port
      s = TCPServer.new("127.0.0.1", 0)
      port = s.addr[1]
      s.close
      port
    end

    def ws_recv_one(host, port, path, timeout)
      sock = TCPSocket.new(host, port)
      key = [SecureRandom.bytes(16)].pack("m0")
      req = "GET #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\n" \
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
            "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      sock.write(req)

      Timeout.timeout(timeout) do
        # Read the handshake headers.
        headers = +""
        headers << sock.readpartial(1) until headers.end_with?("\r\n\r\n")
        return [false, nil, sock] unless headers.start_with?("HTTP/1.1 101")

        # Read one frame (server frames are unmasked).
        b1 = sock.read(2).bytes
        length = b1[1] & 0x7F
        if length == 126
          length = sock.read(2).unpack1("n")
        elsif length == 127
          length = sock.read(8).unpack1("Q>")
        end
        sock.read(4) if (b1[1] & 0x80) != 0 # masked (defensive — servers don't)
        payload = length.positive? ? sock.read(length) : ""
        [true, payload, sock]
      end
    rescue Timeout::Error
      [false, nil, sock]
    end

    def http_get(host, port, path)
      Net::HTTP.start(host, port, open_timeout: 5, read_timeout: 5) do |http|
        res = http.get(path)
        [res.code.to_i, res.body]
      end
    end

    def post_reload(host, port, body)
      Net::HTTP.start(host, port, open_timeout: 5, read_timeout: 10) do |http|
        res = http.post("/__dev/api/reload", JSON.generate(body),
                        "Content-Type" => "application/json")
        [res.code.to_i, res.body]
      end
    end

    it "delivers the broadcast, serves V2 in-process, and does not respawn" do
      Dir.mktmpdir do |proj|
        routes = File.join(proj, "src", "routes")
        FileUtils.mkdir_p(routes)
        File.write(File.join(proj, ".env"),
                   "TINA4_DEBUG=true\nTINA4_LOG_LEVEL=NONE\nTINA4_OVERRIDE_CLIENT=true\nTINA4_NO_AI_PORT=true\n")

        index = File.join(routes, "index.rb")
        File.write(index, <<~RB)
          Tina4.get "/" do |request, response|
            response.html("<h1>Version 1</h1>")
          end
        RB

        lib = File.expand_path("../lib", __dir__)
        config_ru = File.join(proj, "config.ru")
        File.write(config_ru, <<~RU)
          $LOAD_PATH.unshift(#{lib.inspect})
          require "tina4"
          Tina4.initialize!(#{proj.inspect})
          # load_routes (not bare require) sets @last_routes_dir so rescan_routes!
          # re-loads changed files in-process — the framework's real discovery path.
          Tina4::Router.load_routes(File.join(#{proj.inspect}, "src", "routes"))
          run Tina4::RackApp.new(root_dir: #{proj.inspect})
        RU

        port = free_port
        puma_bin = Gem.bin_path("puma", "puma")
        # Strip the Bundler env we inherit from `bundle exec rspec`: the
        # throwaway project has no Gemfile, so a child that still tries to
        # honour BUNDLE_GEMFILE / RUBYOPT=-rbundler/setup fails to boot. nil
        # values delete the keys from the child environment.
        child_env = {
          "TINA4_DEBUG" => "true", "TINA4_OVERRIDE_CLIENT" => "true",
          "TINA4_LOG_LEVEL" => "NONE", "TINA4_NO_AI_PORT" => "true",
          "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil,
          # Force a UTF-8 locale: with the Bundler env stripped the child can
          # default to US-ASCII, and Rack::Builder.load_file then raises
          # "invalid byte sequence in US-ASCII" while parsing config.ru.
          "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8"
        }
        log_path = File.join(proj, "puma.log")
        pid = spawn(
          child_env,
          RbConfig.ruby, puma_bin, "-b", "tcp://127.0.0.1:#{port}", config_ru,
          chdir: proj, out: log_path, err: log_path
        )

        begin
          # Wait for the server to serve Version 1.
          ready = false
          deadline = Time.now + 25
          while Time.now < deadline
            begin
              status, b = http_get("127.0.0.1", port, "/")
              if status == 200 && b.include?("Version 1")
                ready = true
                break
              end
            rescue StandardError
              # not up yet
            end
            sleep 0.2
          end
          unless ready
            log = File.exist?(log_path) ? File.read(log_path) : "(no log)"
            raise "server did not start serving Version 1\n--- puma log ---\n#{log}"
          end

          # Connect a browser-like WS client, then edit + POST after it is up.
          # The thread's value IS the helper's [connected, payload, sock] tuple.
          client = Thread.new { ws_recv_one("127.0.0.1", port, "/__dev_reload", 20) }
          sleep 0.7 # let the upgrade complete and register on the manager

          # Edit V1 -> V2 on disk and bump mtime so the mtime-gated rescan sees it.
          File.write(index, <<~RB)
            Tina4.get "/" do |request, response|
              response.html("<h1>Version 2</h1>")
            end
          RB
          future = Time.now + 5
          File.utime(future, future, index)

          status, = post_reload("127.0.0.1", port, { "type" => "code", "file" => "src/routes/index.rb" })
          expect(status).to eq(200)

          connected, payload, sock = client.value
          sock&.close rescue nil

          # (a) WS client received the broadcast.
          expect(connected).to be(true), "WebSocket handshake failed (/__dev_reload not registered?)"
          expect(payload).not_to be_nil
          msg = JSON.parse(payload)
          expect(msg["type"]).to eq("reload")
          expect(msg["file"]).to eq("src/routes/index.rb")

          # (b) In-process re-import — V2 is served, no restart.
          status, body = http_get("127.0.0.1", port, "/")
          expect(status).to eq(200)
          expect(body).to include("Version 2")

          # (c) Same process — no respawn.
          expect(Process.waitpid(pid, Process::WNOHANG)).to be_nil
        ensure
          Process.kill("TERM", pid) rescue nil
          begin
            Timeout.timeout(5) { Process.waitpid(pid) }
          rescue StandardError
            Process.kill("KILL", pid) rescue nil
          end
        end
      end
    end
  end
end
