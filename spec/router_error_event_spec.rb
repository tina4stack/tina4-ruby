# frozen_string_literal: true

# Tina4 Ruby — v3.13.7 router error handling (DevProx brief PLATFORM-2159).
#
# Three contracts:
#
#   1. ``tina4.request.error`` event fires before the 500 is rendered, so
#      observability consumers (CloudWatch, Sentry, etc.) see route
#      failures even though the framework caught them. Payload is a
#      single hash ``{ exception:, request: }`` — same shape mirrored
#      across Python / PHP / Node.
#
#   2. In non-debug mode the 500 response body never contains a stack
#      trace (CWE-209). Debug mode keeps the ErrorOverlay path intact.
#
#   3. Listener exceptions MUST NOT break the 500 render. A broken
#      listener gets logged via ``Tina4::Log.warning`` and the framework
#      proceeds.

require "spec_helper"

RSpec.describe "Router error event (v3.13.7)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_error_event") }
  let(:app)     { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Events.clear
    # Force production mode so the ErrorOverlay path is bypassed and the
    # safe-render path is exercised — matches the CWE-209 conditions.
    @saved_debug = ENV.delete("TINA4_DEBUG")
    ENV["TINA4_DEBUG"] = "false"
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
    Tina4::Events.clear
    if @saved_debug
      ENV["TINA4_DEBUG"] = @saved_debug
    else
      ENV.delete("TINA4_DEBUG")
    end
  end

  def mock_env(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "SERVER_NAME"    => "localhost",
      "SERVER_PORT"    => "7147",
      "rack.input"     => StringIO.new("")
    }
  end

  def register_failing_route(path = "/api/widgets", message = "simulated explosion inside route")
    Tina4.get(path) { |_req, _res| raise message }
  end

  # ── Contract 1: event fires with the right payload ─────────────────

  context "event payload" do
    it "fires tina4.request.error with exception + request" do
      captured = []
      Tina4::Events.on("tina4.request.error") { |payload| captured << payload }

      register_failing_route("/api/widgets", "boom")
      app.call(mock_env("GET", "/api/widgets"))

      expect(captured.length).to eq(1)
      payload = captured.first
      expect(payload[:exception]).to be_a(StandardError)
      expect(payload[:exception].message).to eq("boom")
      # request is the Tina4::Request wrapper (set into env["tina4.request"])
      expect(payload[:request]).to respond_to(:path)
    end

    it "fires in both production and dev mode" do
      seen = { dev: false, prod: false }
      Tina4::Events.on("tina4.request.error") do
        seen[ENV["TINA4_DEBUG"] == "true" ? :dev : :prod] = true
      end

      register_failing_route
      ENV["TINA4_DEBUG"] = "true"
      app.call(mock_env("GET", "/api/widgets"))
      ENV["TINA4_DEBUG"] = "false"
      app.call(mock_env("GET", "/api/widgets"))

      expect(seen[:dev]).to eq(true)
      expect(seen[:prod]).to eq(true)
    end

    it "fires every registered listener in priority order" do
      calls = []
      Tina4::Events.on("tina4.request.error", priority: 10) { calls << "first" }
      Tina4::Events.on("tina4.request.error", priority: 0)  { calls << "second" }

      register_failing_route
      app.call(mock_env("GET", "/api/widgets"))

      expect(calls).to eq(["first", "second"])
    end
  end

  # ── Contract 2: no stack trace in production body (CWE-209) ────────

  context "production response body (CWE-209)" do
    it "does not include a stack trace" do
      register_failing_route("/api/leak-test", "simulated explosion inside route")
      status, _headers, body_parts = app.call(mock_env("GET", "/api/leak-test"))
      body = body_parts.join

      expect(status).to eq(500)
      forbidden = [
        "simulated explosion inside route",
        "rack_app.rb",
        ".rb:",                         # Ruby backtrace marker
        "in `",                          # Ruby method ref marker (e.g. `in `block (3 levels)`)
      ]
      forbidden.each do |marker|
        expect(body).not_to include(marker),
          "CWE-209 regression: body leaked #{marker.inspect}\n#{body}"
      end
    end

    it "still surfaces a request_id" do
      register_failing_route
      _status, _headers, body_parts = app.call(mock_env("GET", "/api/widgets"))
      body = body_parts.join
      # SecureRandom.hex(6) → 12 hex chars
      expect(body).to match(/[a-f0-9]{12}/)
    end
  end

  # ── Contract 3: listener errors don't break the 500 render ─────────

  context "listener safety" do
    it "renders 500 even when a listener raises" do
      Tina4::Events.on("tina4.request.error") { raise "listener is broken" }

      register_failing_route
      status, _headers, _body = app.call(mock_env("GET", "/api/widgets"))
      expect(status).to eq(500)
    end
  end
end
