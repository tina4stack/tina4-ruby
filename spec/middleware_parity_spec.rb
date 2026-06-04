# frozen_string_literal: true

require "spec_helper"

# Cross-framework parity tests for tina4-book#141 (PY-10-01/02/03).
# Mirrors the 16 tests in tina4-python/tests/test_middleware_parity.py
# so behaviour stays identical across Python, PHP, Ruby, Node.js.
RSpec.describe "Middleware & Header parity (book#141)" do
  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end

  # ---------------------------------------------------------------------------
  # PY-10-02 — Registering middleware MUST NOT silently disable auth_required
  # ---------------------------------------------------------------------------
  describe "PY-10-02: middleware does not flip auth_required" do
    let(:noop_class) { Class.new }

    it "POST stays auth_required when class middleware is attached" do
      route = Tina4::Router.post("/api/items") { |_req, resp| resp.json({}) }
      route.middleware(noop_class)
      expect(route.auth_required).to be true
    end

    it "PUT stays auth_required when middleware is attached" do
      route = Tina4::Router.put("/api/items/{id:int}") { |_req, resp| resp.json({}) }
      route.middleware(noop_class)
      expect(route.auth_required).to be true
    end

    it "DELETE stays auth_required when middleware is attached" do
      route = Tina4::Router.delete("/api/items/{id:int}") { |_req, resp| resp.json({}) }
      route.middleware(noop_class)
      expect(route.auth_required).to be true
    end

    it "GET stays public when middleware is attached" do
      route = Tina4::Router.get("/api/items") { |_req, resp| resp.json({}) }
      route.middleware(noop_class)
      expect(route.auth_required).to be false
    end

    it ".no_auth still opts out explicitly" do
      route = Tina4::Router.post("/login") { |_req, resp| resp.json({}) }
      route.middleware(noop_class).no_auth
      expect(route.auth_required).to be false
    end

    it "registering middleware via kwarg on .post also keeps auth_required" do
      route = Tina4::Router.post("/api/items", middleware: [noop_class]) { |_req, resp| resp.json({}) }
      expect(route.auth_required).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # PY-10-03 — request.headers["Content-Type"] must work (case-insensitive)
  # ---------------------------------------------------------------------------
  describe "PY-10-03: case-insensitive request.headers" do
    let(:env) do
      {
        "REQUEST_METHOD"   => "POST",
        "PATH_INFO"        => "/api/echo",
        "QUERY_STRING"     => "",
        "HTTP_HOST"        => "localhost",
        "CONTENT_TYPE"     => "application/json",
        "HTTP_X_API_KEY"   => "secret-abc",
        "HTTP_AUTHORIZATION" => "Bearer xyz",
        "rack.input"       => StringIO.new("{}"),
      }
    end

    it "mixed-case lookup returns the same value as lowercase" do
      req = Tina4::Request.new(env)
      expect(req.headers["Content-Type"]).to eq("application/json")
      expect(req.headers["content-type"]).to eq("application/json")
      expect(req.headers["CONTENT-TYPE"]).to eq("application/json")
    end

    it "uppercase lookup matches lowercase storage" do
      req = Tina4::Request.new(env)
      expect(req.headers["X-API-KEY"]).to eq("secret-abc")
      expect(req.headers["X-Api-Key"]).to eq("secret-abc")
      expect(req.headers["x-api-key"]).to eq("secret-abc")
    end

    it "key? / has_key? are case-insensitive" do
      req = Tina4::Request.new(env)
      expect(req.headers.key?("Authorization")).to be true
      expect(req.headers.key?("authorization")).to be true
      expect(req.headers.include?("Authorization")).to be true
    end

    it "header() helper accepts both dashed and underscored names" do
      req = Tina4::Request.new(env)
      expect(req.header("Content-Type")).to eq("application/json")
      expect(req.header("content_type")).to eq("application/json")
      expect(req.header("CONTENT-TYPE")).to eq("application/json")
    end

    it "missing header returns nil for any casing" do
      req = Tina4::Request.new(env)
      expect(req.headers["X-Missing"]).to be_nil
      expect(req.headers["x-missing"]).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # PY-10-01 — Function-style middleware with next_handler continuation
  # ---------------------------------------------------------------------------
  describe "PY-10-01: function-style middleware with next_handler" do
    def call_route(method, path, env_overrides: {})
      env = {
        "REQUEST_METHOD" => method,
        "PATH_INFO"      => path,
        "QUERY_STRING"   => "",
        "HTTP_HOST"      => "localhost",
        "rack.input"     => StringIO.new(""),
      }.merge(env_overrides)
      Tina4::RackApp.new.call(env)
    end

    it "Route.function_middleware? detects 3-arg lambdas" do
      fn = ->(_req, _resp, _nxt) { nil }
      expect(Tina4::Route.function_middleware?(fn)).to be true
    end

    it "Route.function_middleware? rejects 2-arg procs (class-style heuristic)" do
      fn = ->(_req, _resp) { nil }
      expect(Tina4::Route.function_middleware?(fn)).to be false
    end

    it "Route.function_middleware? rejects classes" do
      klass = Class.new
      expect(Tina4::Route.function_middleware?(klass)).to be false
    end

    it "runs the function-style middleware body and continues to handler" do
      events = []
      logger = lambda do |req, resp, nxt|
        events << :before
        result = nxt.call(req, resp)
        events << :after
        result
      end

      route = Tina4::Router.get("/api/log") { |_req, resp| resp.json({ ok: true }) }
      route.middleware(logger)

      status, _, _ = call_route("GET", "/api/log")
      expect(status).to eq(200)
      expect(events).to eq(%i[before after])
    end

    it "chain order — first declared is outermost" do
      events = []
      outer = lambda do |req, resp, nxt|
        events << :outer_in
        r = nxt.call(req, resp)
        events << :outer_out
        r
      end
      inner = lambda do |req, resp, nxt|
        events << :inner_in
        r = nxt.call(req, resp)
        events << :inner_out
        r
      end

      route = Tina4::Router.get("/api/order") { |_req, resp| events << :handler; resp.json({}) }
      route.middleware(outer, inner)

      call_route("GET", "/api/order")
      expect(events).to eq(%i[outer_in inner_in handler inner_out outer_out])
    end

    it "short-circuits when middleware does not call next_handler" do
      handler_called = false
      blocker = lambda do |_req, resp, _nxt|
        resp.json({ blocked: true }, 401)
      end

      route = Tina4::Router.get("/api/blocked") { |_req, resp| handler_called = true; resp.json({}) }
      route.middleware(blocker)

      status, _, body = call_route("GET", "/api/blocked")
      expect(handler_called).to be false
      expect(status).to eq(401)
      expect(body.join).to include("blocked")
    end

    it "global class-based before_* runs alongside route-level function-style" do
      events = []
      tag_class = Class.new do
        define_singleton_method(:before_tag) do |req, resp|
          events << :class_before
          [req, resp]
        end
      end
      Tina4::Router.use(tag_class)

      fn_mw = lambda do |req, resp, nxt|
        events << :fn_in
        r = nxt.call(req, resp)
        events << :fn_out
        r
      end

      route = Tina4::Router.get("/api/mixed") { |_req, resp| events << :handler; resp.json({}) }
      route.middleware(fn_mw)

      call_route("GET", "/api/mixed")
      # Global class-based before_* runs before the function-style chain
      # wraps the handler. Function-style still gets its before+after on
      # either side of the handler.
      expect(events).to eq(%i[class_before fn_in handler fn_out])
    end

    it "function middleware can mutate the response on the way out" do
      tagger = lambda do |req, resp, nxt|
        result = nxt.call(req, resp)
        resp.add_header("X-Tagged", "yes")
        result
      end

      route = Tina4::Router.get("/api/tag") { |_req, resp| resp.json({ ok: true }) }
      route.middleware(tagger)

      status, headers, _ = call_route("GET", "/api/tag")
      expect(status).to eq(200)
      expect(headers["X-Tagged"]).to eq("yes")
    end
  end
end
