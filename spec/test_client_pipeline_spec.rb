# frozen_string_literal: true
#
# Lock-in spec for D6 (feature-recount audit): Tina4::TestClient MUST dispatch
# through the REAL Tina4::RackApp#call, not straight at Tina4::Router.match.
#
# Before the fix, test_client.rb called Router.match directly, so everything the
# RackApp front-controller does BEFORE (and AROUND) route matching was invisible
# to the test surface: global middleware, static files, /swagger,
# /swagger/openapi.json, the framework's bundled public assets, RFC 9110
# OPTIONS/405 Allow handling, and HEAD body-stripping all returned
# {"error":"Not found"} under TestClient while returning their real response
# through the live server. Any Ruby spec asserting framework endpoint behaviour
# via TestClient was asserting nothing.
#
# NO mocks, doubles, stubs or fake transports. This spec boots the REAL
# Tina4::WebServer on a REAL ephemeral TCP port with a REAL RackApp rooted at a
# REAL temp project dir holding a REAL static file, then asserts — for every
# probe — that what TestClient returns MATCHES what a real HTTP client gets over
# the socket from the same running app. The live socket is the oracle; TestClient
# is the thing under test.

require "spec_helper"
require "socket"
require "net/http"
require "tmpdir"
require "fileutils"

RSpec.describe "TestClient dispatches through the real RackApp (D6)" do
  STATIC_PROBE_BODY = "tina4-static-probe-body"

  before(:all) do
    # A real project root with a real static asset on disk.
    @root_dir = Dir.mktmpdir("tina4_test_client_pipeline")
    FileUtils.mkdir_p(File.join(@root_dir, "src", "public"))
    File.write(File.join(@root_dir, "src", "public", "probe.txt"), STATIC_PROBE_BODY)

    # /swagger + /swagger/openapi.json are gated on TINA4_SWAGGER_ENABLED
    # (falling back to TINA4_DEBUG) — turn them on for BOTH surfaces.
    @prior_swagger = ENV["TINA4_SWAGGER_ENABLED"]
    ENV["TINA4_SWAGGER_ENABLED"] = "true"

    @app = Tina4::RackApp.new(root_dir: @root_dir)
    @port = free_port
    @server = Tina4::WebServer.new(@app, host: "127.0.0.1", port: @port)

    prev_override = ENV["TINA4_OVERRIDE_CLIENT"]
    prev_no_ai = ENV["TINA4_NO_AI_PORT"]
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    @thread = Thread.new { @server.start }
    @thread.abort_on_exception = false
    wait_for_port(@port)
    if prev_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = prev_override end
    if prev_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = prev_no_ai end
  end

  after(:all) do
    @server&.stop
    @thread&.kill
    FileUtils.rm_rf(@root_dir) if @root_dir
    if @prior_swagger.nil?
      ENV.delete("TINA4_SWAGGER_ENABLED")
    else
      ENV["TINA4_SWAGGER_ENABLED"] = @prior_swagger
    end
  end

  # spec_helper clears the Router and Middleware after EVERY example, so both
  # registries are rebuilt per example. The already-booted server reads the live
  # registries at request time, so this is all the live app needs.
  before(:each) do
    Tina4::Health.register!

    Tina4::Router.get("/pipeline/plain") do |request, response|
      response.json({ ok: true })
    end

    Tina4::Router.get("/pipeline/get-only") do |request, response|
      response.json({ method: "GET" })
    end

    # Real global middleware — a block-based before hook that stamps the request.
    # Under the old TestClient this NEVER ran; the live server always ran it.
    Tina4::Middleware.before do |request, _response|
      request.env["tina4.middleware_ran"] = "yes"
      true
    end

    Tina4::Router.get("/pipeline/middleware-probe") do |request, response|
      response.json({ middleware: request.env["tina4.middleware_ran"] || "no" })
    end
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_port(port)
    deadline = Time.now + 10
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        raise "server never came up on port #{port}" if Time.now > deadline
        sleep 0.05
      end
    end
  end

  # A real HTTP request over the real socket to the running server.
  def live(method, path)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    klass = Net::HTTP.const_get(method.capitalize)
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
      http.request(klass.new(uri))
    end
    { status: res.code.to_i, body: res.body.to_s, headers: res.to_hash, content_type: res["content-type"].to_s }
  end

  # The same request through the in-process TestClient, bound to the SAME app.
  let(:client) { Tina4::TestClient.new(@app) }

  # ── The core contract: framework endpoints are reachable, not 404 ──────────

  describe "framework endpoints that the old TestClient reported as 404" do
    {
      "/swagger" => "text/html",
      "/swagger/openapi.json" => "application/json",
      "/__health" => "application/json",
      "/health" => "application/json"
    }.each do |path, expected_type|
      it "serves #{path} with the same status the live server gives" do
        live_result = live("get", path)
        test_result = client.get(path)

        # The live server is the oracle — prove IT is 200 first, so a shared
        # 404 could never make this assertion vacuously pass.
        expect(live_result[:status]).to eq(200), "live server did not serve #{path}: #{live_result.inspect}"
        expect(test_result.status).to eq(live_result[:status])
        expect(test_result.content_type).to include(expected_type)
        # NEGATIVE: the old short-circuit body must be gone.
        expect(test_result.body).not_to include('{"error":"Not found"}')
      end
    end
  end

  describe "static files" do
    it "serves a project static file (src/public/probe.txt) exactly as the live server does" do
      live_result = live("get", "/probe.txt")
      test_result = client.get("/probe.txt")

      expect(live_result[:status]).to eq(200), "live server did not serve /probe.txt: #{live_result.inspect}"
      expect(live_result[:body]).to eq(STATIC_PROBE_BODY)
      expect(test_result.status).to eq(200)
      expect(test_result.body).to eq(STATIC_PROBE_BODY)
    end

    it "serves the framework's bundled public asset (/js/tina4js.min.js)" do
      live_result = live("get", "/js/tina4js.min.js")
      test_result = client.get("/js/tina4js.min.js")

      expect(live_result[:status]).to eq(200), "live server did not serve the bundled asset: #{live_result[:status]}"
      expect(test_result.status).to eq(200)
      expect(test_result.body.bytesize).to eq(live_result[:body].bytesize)
    end

    it "still 404s a static path that does not exist (negative)" do
      live_result = live("get", "/definitely-not-here.txt")
      test_result = client.get("/definitely-not-here.txt")

      expect(live_result[:status]).to eq(404)
      expect(test_result.status).to eq(404)
    end
  end

  describe "global middleware" do
    it "runs global before middleware, exactly as the live server does" do
      live_result = live("get", "/pipeline/middleware-probe")
      test_result = client.get("/pipeline/middleware-probe")

      expect(JSON.parse(live_result[:body])["middleware"]).to eq("yes")
      # NEGATIVE against the old behaviour: the pre-fix TestClient never ran
      # global middleware, so this read "no".
      expect(test_result.json["middleware"]).to eq("yes")
    end
  end

  describe "RFC 9110 handling owned by RackApp, not the Router" do
    # TestClient's verb surface is get/post/put/patch/delete in ALL FOUR
    # frameworks (python test_client/__init__.py, Tina4/TestClient.php,
    # packages/core/src/testClient.ts) — deliberately no head/options, so this
    # exercises the RackApp-owned RFC 9110 paths with the verbs that exist.
    it "returns 405 + Allow for a method the path does not support" do
      live_result = live("put", "/pipeline/get-only")
      test_result = client.put("/pipeline/get-only", json: { nope: true })

      # The live server is the oracle: prove IT answers 405, not 404.
      expect(live_result[:status]).to eq(405), "live server did not 405: #{live_result.inspect}"
      # NEGATIVE against the old behaviour: pre-fix this was a flat 404 with
      # {"error":"Not found"} because Router.match simply missed.
      expect(test_result.status).to eq(405)
      expect(test_result.headers["allow"].to_s).to include("GET")
      expect(test_result.json["error"]).to eq("Method Not Allowed")
      expect(test_result.json["allow"]).to include("GET")
    end

    it "keeps OPTIONS/HEAD handling in the app both surfaces share" do
      # Asserted on the live socket (TestClient exposes no head/options verb in
      # any framework) — this pins that the pipeline TestClient now routes
      # through is the same one answering these.
      expect(live("options", "/pipeline/get-only")[:status]).to eq(204)
      head_result = live("head", "/pipeline/plain")
      expect(head_result[:status]).to eq(200)
      expect(head_result[:body].to_s).to eq("")
    end
  end

  describe "ordinary routes are unaffected" do
    it "matches a plain GET route and returns its JSON" do
      expect(client.get("/pipeline/plain").json["ok"]).to eq(true)
      expect(JSON.parse(live("get", "/pipeline/plain")[:body])["ok"]).to eq(true)
    end

    it "404s a genuinely unregistered API path the same way the live server does" do
      live_result = live("get", "/api/pipeline/nope")
      test_result = client.get("/api/pipeline/nope")

      expect(live_result[:status]).to eq(404)
      expect(test_result.status).to eq(404)
      # Same content type as the live server (the old TestClient hardcoded JSON).
      expect(test_result.content_type.split(";").first).to eq(live_result[:content_type].split(";").first)
    end
  end

  describe "the app binding" do
    # RackApp.current is last-one-wins process-wide state (spec_helper resets it
    # after every example), so each of these builds the app it asserts on rather
    # than depending on which example ran first.
    it "reuses the process-wide RackApp when none is passed" do
      fresh = Tina4::RackApp.new(root_dir: @root_dir)
      expect(Tina4::RackApp.current).to equal(fresh)
      expect(Tina4::TestClient.new.app).to equal(fresh)
    end

    it "uses an explicitly passed app over the process-wide one" do
      current = Tina4::RackApp.new(root_dir: @root_dir)
      other = Tina4::RackApp.new(root_dir: @root_dir)
      # `other` is the most recent, so make `current` the process-wide one again
      # to prove the explicit argument really is what wins.
      Tina4::RackApp.current = current
      expect(Tina4::TestClient.new(other).app).to equal(other)
      expect(Tina4::TestClient.new.app).to equal(current)
    end

    it "builds an app rooted at Dir.pwd when nothing is bound (negative)" do
      Tina4::RackApp.current = nil
      built = Tina4::TestClient.new.app
      expect(built).to be_a(Tina4::RackApp)
      expect(built.instance_variable_get(:@root_dir)).to eq(Dir.pwd)
    end
  end
end
