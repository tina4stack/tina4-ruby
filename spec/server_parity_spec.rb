# frozen_string_literal: true

require "spec_helper"
require "socket"
require "net/http"
require "timeout"

RSpec.describe Tina4::WebServer do
  let(:app) { Tina4::RackApp.new }
  let(:server) { Tina4::WebServer.new(app, host: "0.0.0.0", port: 17147) }

  # Grab an OS-assigned ephemeral port, then release it so the server under
  # test can bind it. Mirrors the free_port helper in dev_reload_ws_spec.rb.
  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  # Boot the real WEBrick server in a background thread and block until it
  # actually accepts a TCP connection (or time out). start() refuses to boot
  # unless the CLI runs it or TINA4_OVERRIDE_CLIENT=true, so set that for the
  # duration of the boot. Returns the [server, thread] pair.
  def boot_server(port)
    srv = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)
    prev_override = ENV["TINA4_OVERRIDE_CLIENT"]
    prev_no_ai = ENV["TINA4_NO_AI_PORT"]
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    thread = Thread.new { srv.start }
    thread.abort_on_exception = false

    # Wait until the listener is actually accepting connections.
    deadline = Time.now + 10
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        break
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        raise "server never came up on port #{port}" if Time.now > deadline
        sleep 0.05
      end
    end

    [srv, thread]
  ensure
    if prev_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = prev_override end
    if prev_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = prev_no_ai end
  end

  describe "#handle" do
    it "dispatches a Rack env through the app and returns the real /health response" do
      # /health is only routed when Health.register! has run (the CLI does this
      # on boot). Register it so the dispatch exercises the real endpoint.
      Tina4::Health.register!

      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/health",
        "QUERY_STRING" => "",
        "SERVER_NAME" => "localhost",
        "SERVER_PORT" => "17147",
        "CONTENT_TYPE" => "",
        "CONTENT_LENGTH" => "0",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new(""),
        "rack.errors" => $stderr,
        "rack.url_scheme" => "http"
      }

      status, headers, body = server.handle(env)

      # The real computed response — not just the triple's types.
      expect(status).to eq(200)

      content_type = headers["content-type"] || headers["Content-Type"]
      expect(content_type).to include("application/json")

      body_str = +""
      body.each { |chunk| body_str << chunk }
      payload = JSON.parse(body_str)
      expect(payload["status"]).to eq("ok")
      expect(payload["framework"]).to eq("tina4-ruby")
      expect(payload["version"]).to eq(Tina4::VERSION)
    end
  end

  describe "#start" do
    it "binds the port and serves real requests" do
      Tina4::Health.register!
      port = free_port
      srv, thread = boot_server(port)

      begin
        # The socket actually accepts a connection (proven by boot_server's wait),
        # and a real HTTP GET /health is served end-to-end with the health body.
        code, resp_body = Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 5) do |http|
          res = http.get("/health")
          [res.code.to_i, res.body]
        end

        expect(code).to eq(200)
        payload = JSON.parse(resp_body)
        expect(payload["status"]).to eq("ok")
        expect(payload["framework"]).to eq("tina4-ruby")
      ensure
        srv.stop
        thread.join(5)
      end
    end
  end

  describe "#stop" do
    it "shuts the listener down and releases the port" do
      port = free_port
      srv, thread = boot_server(port)

      # The listener is up — a fresh connection succeeds before stop.
      expect { TCPSocket.new("127.0.0.1", port).close }.not_to raise_error

      srv.stop
      thread.join(5)

      # After stop the port is released: rebinding a TCPServer on the same
      # port succeeds (the listener really shut down, not merely "responds to").
      rebound = nil
      Timeout.timeout(10) do
        loop do
          begin
            rebound = TCPServer.new("127.0.0.1", port)
            break
          rescue Errno::EADDRINUSE
            sleep 0.05
          end
        end
      end
      expect(rebound).to be_a(TCPServer)
      rebound.close
    end
  end
end
