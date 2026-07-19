# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::RackApp do
  let(:tmp_dir) { Dir.mktmpdir("tina4_rack_test") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) { Tina4::Router.clear! }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def mock_env(method, path, headers: {}, body: "")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new(body)
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  describe "#call" do
    it "handles OPTIONS preflight" do
      status, headers, _body = app.call(mock_env("OPTIONS", "/api/test"))
      expect(status).to eq(204)
    end

    it "routes GET requests" do
      Tina4.get("/hello") { |_req, res| res.json({ message: "hi" }) }
      status, headers, body = app.call(mock_env("GET", "/hello"))
      expect(status).to eq(200)
      parsed = JSON.parse(body.join)
      expect(parsed["message"]).to eq("hi")
    end

    it "returns 404 for unknown routes" do
      status, _headers, _body = app.call(mock_env("GET", "/nonexistent"))
      expect(status).to eq(404)
    end

    it "serves static files with their real contents and content type" do
      # Create a static file
      pub_dir = File.join(tmp_dir, "public")
      FileUtils.mkdir_p(pub_dir)
      File.write(File.join(pub_dir, "test.txt"), "hello static")

      status, headers, body = app.call(mock_env("GET", "/test.txt"))
      expect(status).to eq(200)
      # The exact file bytes must be served back, not just any 200.
      expect(body.join).to eq("hello static")
      # And the content type must be derived from the .txt extension.
      content_type = headers["content-type"] || headers["Content-Type"]
      expect(content_type).to include("text/plain")
    end

    it "prevents path traversal" do
      result = app.call(mock_env("GET", "/../../../etc/passwd"))
      status = result[0]
      expect(status).to eq(404)
    end

    it "serves swagger UI when enabled" do
      saved = ENV["TINA4_SWAGGER_ENABLED"]
      ENV["TINA4_SWAGGER_ENABLED"] = "true"
      status, _headers, body = app.call(mock_env("GET", "/swagger"))
      expect(status).to eq(200)
      expect(body.join).to include("swagger-ui")
    ensure
      ENV["TINA4_SWAGGER_ENABLED"] = saved
    end

    it "404s swagger UI when disabled (production gate)" do
      saved_e = ENV["TINA4_SWAGGER_ENABLED"]
      saved_d = ENV["TINA4_DEBUG"]
      ENV["TINA4_SWAGGER_ENABLED"] = "false"
      ENV.delete("TINA4_DEBUG")
      status, = app.call(mock_env("GET", "/swagger"))
      expect(status).to eq(404)
    ensure
      ENV["TINA4_SWAGGER_ENABLED"] = saved_e
      ENV["TINA4_DEBUG"] = saved_d
    end

    it "serves OpenAPI JSON spec when enabled" do
      saved = ENV["TINA4_SWAGGER_ENABLED"]
      ENV["TINA4_SWAGGER_ENABLED"] = "true"
      status, _headers, body = app.call(mock_env("GET", "/swagger/openapi.json"))
      expect(status).to eq(200)
      spec = JSON.parse(body.join)
      expect(spec["openapi"]).to eq("3.0.3")
    ensure
      ENV["TINA4_SWAGGER_ENABLED"] = saved
    end

    it "handles exceptions with 500" do
      Tina4.get("/crash") { |_req, _res| raise "boom" }
      status, _headers, _body = app.call(mock_env("GET", "/crash"))
      expect(status).to eq(500)
    end

    it "returns 403 for failed auth" do
      Tina4.secure_get("/secret") { |_req, res| res.json({ secret: true }) }
      status, _headers, _body = app.call(mock_env("GET", "/secret"))
      expect(status).to eq(403)
    end

    it "passes path params to handler" do
      Tina4.get("/users/{id}") { |req, res| res.json({ id: req.params["id"] }) }
      status, _headers, body = app.call(mock_env("GET", "/users/42"))
      expect(status).to eq(200)
      parsed = JSON.parse(body.join)
      expect(parsed["id"]).to eq("42")
    end
  end

  # nodejs#33 was a Node-only prod crash: `new URL(req.url)` threw
  # ERR_INVALID_URL on `//`, `///`, `/\` before any try/catch, taking down the
  # worker (unauthenticated DoS). Ruby is structurally safe — Rack hands the
  # path as an opaque PATH_INFO string and the whole `#call` is wrapped in a
  # rescue — so a malformed path is just an unmatched route. This lock-in spec
  # pins that: each malformed path returns a clean 4xx (never a raise/500), and
  # the app keeps serving a normal request afterwards.
  describe "#call malformed path is safe (nodejs#33 parity lock-in)" do
    %w[// /// /\\ /%2e%2e //../.. /..;/].each do |bad_path|
      it "returns a 4xx for #{bad_path.inspect} and does not crash" do
        Tina4.get("/ok") { |_req, res| res.json({ ok: true }) }

        status, = app.call(mock_env("GET", bad_path))
        expect(status).to be_between(400, 499).inclusive

        # The worker survives — a following normal request still routes 200.
        after_status, _headers, after_body = app.call(mock_env("GET", "/ok"))
        expect(after_status).to eq(200)
        expect(JSON.parse(after_body.join)["ok"]).to be(true)
      end
    end
  end

  # v3.13.14 — per-request log line. The dev inspector fed only the /__dev
  # UI; nothing reached stdout, so `tina4ruby serve` went silent after the
  # banner. Now every request logs through Tina4::Log (→ stdout), on by
  # default in dev, opt-in in prod via TINA4_LOG_REQUESTS.
  describe "request logging (v3.13.14)" do
    around do |example|
      saved_debug = ENV["TINA4_DEBUG"]
      saved_req = ENV["TINA4_LOG_REQUESTS"]
      example.run
      saved_debug.nil? ? ENV.delete("TINA4_DEBUG") : ENV["TINA4_DEBUG"] = saved_debug
      saved_req.nil? ? ENV.delete("TINA4_LOG_REQUESTS") : ENV["TINA4_LOG_REQUESTS"] = saved_req
    end

    def gate(app_instance)
      app_instance.send(:request_logging_enabled?)
    end

    it "gate: unset follows dev mode (on)" do
      ENV.delete("TINA4_LOG_REQUESTS")
      ENV["TINA4_DEBUG"] = "true"
      expect(gate(app)).to be(true)
    end

    it "gate: unset follows dev mode (off in prod)" do
      ENV.delete("TINA4_LOG_REQUESTS")
      ENV["TINA4_DEBUG"] = "false"
      expect(gate(app)).to be(false)
    end

    it "gate: explicit true overrides prod" do
      ENV["TINA4_LOG_REQUESTS"] = "true"
      ENV["TINA4_DEBUG"] = "false"
      expect(gate(app)).to be(true)
    end

    it "gate: explicit false overrides dev" do
      ENV["TINA4_LOG_REQUESTS"] = "false"
      ENV["TINA4_DEBUG"] = "true"
      expect(gate(app)).to be(false)
    end

    it "logs every request through Tina4::Log in dev" do
      ENV["TINA4_DEBUG"] = "true"
      ENV.delete("TINA4_LOG_REQUESTS")
      Tina4::Log.configure(tmp_dir) # writes logs/tina4.log under tmp_dir
      Tina4.get("/hello") { |_req, res| res.json({ ok: true }) }
      app.call(mock_env("GET", "/hello"))
      log = File.read(File.join(tmp_dir, "logs", "tina4.log"))
      expect(log).to include("GET /hello -> 200 (")
      expect(log).to include("ms)")
    end
  end

  # ── issue #31: the auto-session Set-Cookie must route through
  #    Session#cookie_header so TINA4_SESSION_SECURE / _SAMESITE are honoured ──
  #
  # Wire-level, per the no-mock rule: a REAL app.call() whose route touches the
  # session, asserting the ACTUAL Set-Cookie header the RackApp emits. This is
  # the path that ships — a test against Session#cookie_header alone would pass
  # even WITH the bug, because the bug was the hand-written header in
  # rack_app.rb bypassing the builder and hardcoding HttpOnly/SameSite=Lax and
  # never a Secure flag. Only reading the real emitted header catches it.
  describe "session cookie attributes on the wire (issue #31)" do
    def with_env(pairs)
      saved = pairs.keys.to_h { |key| [key, [ENV.key?(key), ENV[key]]] }
      pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      saved.each { |key, (had, previous)| had ? ENV[key] = previous : ENV.delete(key) }
    end

    # Drive a REAL request through a route that starts a session; return the
    # actual Set-Cookie header the RackApp emitted (nil if none).
    def emitted_set_cookie(request_headers = {})
      Tina4.get("/needs-session") do |request, response|
        request.session["user"] = "alice"
        response.json({ ok: true })
      end
      _status, headers, _body = app.call(mock_env("GET", "/needs-session", headers: request_headers))
      headers["set-cookie"] || headers["Set-Cookie"]
    end

    it "sets a tina4_session cookie when a route uses the session" do
      cookie = emitted_set_cookie
      expect(cookie).not_to be_nil
      expect(cookie).to include("tina4_session=")
      expect(cookie).to include("Path=/")
    end

    it "emits Secure when the request is https via x-forwarded-proto" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        expect(emitted_set_cookie("X-Forwarded-Proto" => "https")).to include("Secure")
      end
    end

    it "does NOT emit Secure on plain http with no proxy header" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        cookie = emitted_set_cookie
        expect(cookie).not_to be_nil
        expect(cookie).not_to include("Secure")
      end
    end

    it "does NOT emit Secure when x-forwarded-proto is http" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        expect(emitted_set_cookie("X-Forwarded-Proto" => "http")).not_to include("Secure")
      end
    end

    it "emits Secure when TINA4_SESSION_SECURE=true on plain http" do
      with_env("TINA4_SESSION_SECURE" => "true", "TINA4_SESSION_SAMESITE" => nil) do
        expect(emitted_set_cookie).to include("Secure")
      end
    end

    it "honours TINA4_SESSION_SAMESITE=Strict (proves it is not hardcoded Lax)" do
      with_env("TINA4_SESSION_SAMESITE" => "Strict", "TINA4_SESSION_SECURE" => nil) do
        cookie = emitted_set_cookie
        expect(cookie).to include("SameSite=Strict")
        expect(cookie).not_to include("SameSite=Lax")
      end
    end
  end
end
