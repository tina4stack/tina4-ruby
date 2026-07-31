# frozen_string_literal: true
#
# Middleware pipeline characterisation (feature-7).
#
# THE CONTRACT under test — the return value of EVERY before_*/after_* hook, at
# EVERY scope (global via Tina4::Router.use, and per-route via route.middleware):
#
#   a Tina4::Response       SHORT-CIRCUIT. That object IS the response, at ANY
#                           status. PRIMARY rule — the only one that can express
#                           a 302 redirect.
#   [request, response]     rebind both, continue
#   false                   SHORT-CIRCUIT. Send the response AS SET; only when it
#                           is still default/empty does it become a 403.
#   nil                     continue
#
#   plus a RETAINED LEGACY COMPAT PATH: after a before hook returns, a response
#   status >= 400 ALSO short-circuits even when the hook returned nil.
#
# The 17 `it` sentences below are IDENTICAL in tina4-python, tina4-php,
# tina4-ruby and tina4-nodejs so the four suites grep the same way. Do not
# reword them.
#
# NO MOCKS — and that explicitly excludes RSpec double/instance_double/
# allow(...).to receive. Every middleware here is a real class with real
# `def self.before_*` methods (real source_location, which is what the
# definition-order discovery reads), the request/response are real
# Tina4::Request / Tina4::Response, and the dispatch path is the real
# Tina4::RackApp reached through Tina4::TestClient.
#
# Both public entry points are exercised for every rule:
#   * Tina4::Middleware.run_before / .run_after — the orchestrator
#   * Tina4::TestClient                          — the real dispatcher
# Both must obey the same table.

require "spec_helper"
require "tmpdir"
require "fileutils"

# ── Real middleware under test ───────────────────────────────────────────────
#
# Namespaced so the suite's global constant space stays clean. TRACE is real
# shared state written by real hooks — it is a recorder, not a stand-in for a
# collaborator, so it is not a mock.
module MwPipeline
  TRACE = []

  def self.reset!
    TRACE.clear
  end

  # Two before hooks + one after hook. `before_zulu` is DEFINED FIRST but sorts
  # LAST alphabetically, so a run order of [zulu, alpha] proves definition order
  # and disproves alphabetical order.
  class Ordered
    def self.before_zulu(request, response)
      TRACE << :zulu
      [request, response]
    end

    def self.before_alpha(request, response)
      TRACE << :alpha
      [request, response]
    end

    def self.after_omega(request, response)
      TRACE << :omega
      [request, response]
    end
  end

  # Registration-order pair. Names chosen so alphabetical order (Ay, Bee) is the
  # OPPOSITE of the registration order used in the test (Bee first).
  class Ay
    def self.before_mark(request, response)
      TRACE << :ay
      [request, response]
    end
  end

  class Bee
    def self.before_mark(request, response)
      TRACE << :bee
      [request, response]
    end
  end

  # Inheritance: the base hook must be discovered through the subclass, and must
  # run BEFORE the subclass's own hook (base -> derived).
  class Base
    def self.before_base(request, response)
      TRACE << :base_before
      [request, response]
    end

    def self.after_base(request, response)
      TRACE << :base_after
      [request, response]
    end
  end

  class Derived < Base
    def self.before_derived(request, response)
      TRACE << :derived_before
      [request, response]
    end
  end

  # Refusal shapes -----------------------------------------------------------

  # Sets 4xx and returns the pair — the historically-honoured shape.
  class DenyPair
    def self.before_deny(request, response)
      TRACE << :deny_pair
      response.json({ error: "denied" }, 403)
      [request, response]
    end
  end

  # Sets 4xx and returns NOTHING. THE SECURITY REGRESSION (case 6): the status
  # check used to live inside the "returned a 2-element Array" branch, so this
  # shape set 403 and then ran the handler anyway.
  class DenyNil
    def self.before_deny(request, response)
      TRACE << :deny_nil
      response.json({ error: "denied" }, 403)
      nil
    end
  end

  # Refuses AND has an after hook, to prove after hooks still run on a halt.
  class DenyWithAfter
    def self.before_deny(request, response)
      TRACE << :deny_with_after_before
      response.json({ error: "denied" }, 403)
      nil
    end

    def self.after_stamp(request, response)
      TRACE << :deny_with_after_after
      response.add_header("x-after-ran", "yes")
      [request, response]
    end
  end

  # Returns a Response object directly (200) — PRIMARY short-circuit rule.
  class ReturnsResponse
    def self.before_take_over(_request, response)
      TRACE << :returns_response
      response.json({ taken_over: true }, 200)
    end
  end

  # Returns a REDIRECT Response (302) — the case the >= 400 rule cannot express.
  class ReturnsRedirect
    def self.before_redirect(_request, response)
      TRACE << :returns_redirect
      response.redirect("/login", 302)
    end
  end

  # Returns literal false and sets NOTHING — must become a 403.
  class ReturnsFalse
    def self.before_deny(_request, _response)
      TRACE << :returns_false
      false
    end
  end

  # Returns literal false but HAS set its own response — that response must be
  # sent as set, NOT replaced by a hardcoded 403.
  class ReturnsFalseWithBody
    def self.before_deny(_request, response)
      TRACE << :returns_false_with_body
      response.json({ error: "teapot" }, 418)
      false
    end
  end

  # Returns nothing and sets nothing — must continue to the handler.
  class ReturnsNothing
    def self.before_noop(_request, _response)
      TRACE << :returns_nothing
      nil
    end
  end

  # Throwing hooks -----------------------------------------------------------

  class ThrowingBefore
    def self.before_boom(_request, _response)
      TRACE << :throwing_before
      raise "before hook exploded"
    end
  end

  # First after hook throws; the SECOND must still run.
  class ThrowingAfter
    def self.after_boom(_request, _response)
      TRACE << :throwing_after
      raise "after hook exploded"
    end

    def self.after_survivor(request, response)
      TRACE << :after_survivor
      [request, response]
    end
  end

  # Per-route middleware ------------------------------------------------------

  class RouteHooks
    def self.before_tag(request, response)
      TRACE << :route_before
      response.add_header("x-route-before", "yes")
      [request, response]
    end

    def self.after_tag(request, response)
      TRACE << :route_after
      response.add_header("x-route-after", "yes")
      [request, response]
    end
  end

  class RouteDenyNil
    def self.before_deny(_request, response)
      TRACE << :route_deny_nil
      response.json({ error: "route denied" }, 403)
      nil
    end
  end

  class RouteReturnsRedirect
    def self.before_redirect(_request, response)
      TRACE << :route_returns_redirect
      response.redirect("/login", 302)
    end
  end

  class RouteReturnsFalse
    def self.before_deny(_request, _response)
      TRACE << :route_returns_false
      false
    end
  end
end

RSpec.describe "Middleware pipeline (feature-7 contract)" do
  before(:all) do
    # A real, empty project root so the real RackApp has a real static root and
    # no stray route files. TestClient dispatches through this app.
    @root_dir = Dir.mktmpdir("tina4_mw_pipeline")
    FileUtils.mkdir_p(File.join(@root_dir, "src", "public"))
    @app = Tina4::RackApp.new(root_dir: @root_dir)
  end

  after(:all) do
    FileUtils.rm_rf(@root_dir) if @root_dir
  end

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    MwPipeline.reset!
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    MwPipeline.reset!
  end

  # ── helpers (real objects only) ────────────────────────────────────────────

  def client
    Tina4::TestClient.new(@app)
  end

  # A real Tina4::Request / Tina4::Response pair, exactly as the dispatcher
  # builds them.
  def real_pair(path = "/probe", method = "GET")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "rack.input"     => StringIO.new("")
    }
    [Tina4::Request.new(env), Tina4::Response.new]
  end

  # Register a real GET route whose handler records that it ran.
  def handler_route(path = "/probe")
    Tina4::Router.get(path) do |_request, response|
      MwPipeline::TRACE << :handler
      response.json({ handler: true })
    end
  end

  def handler_ran?
    MwPipeline::TRACE.include?(:handler)
  end

  # ── 1 ──────────────────────────────────────────────────────────────────────
  it "global class middleware runs its before hook" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::Ordered], request, response)).to be true
    expect(MwPipeline::TRACE).to include(:zulu, :alpha)

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::Ordered)
    handler_route
    expect(client.get("/probe").status).to eq(200)
    expect(MwPipeline::TRACE).to include(:zulu, :alpha)
  end

  # ── 2 ──────────────────────────────────────────────────────────────────────
  it "global class middleware runs its after hook" do
    request, response = real_pair
    Tina4::Middleware.run_after([MwPipeline::Ordered], request, response)
    expect(MwPipeline::TRACE).to eq([:omega])

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::Ordered)
    handler_route
    expect(client.get("/probe").status).to eq(200)
    expect(MwPipeline::TRACE).to include(:omega)
    expect(MwPipeline::TRACE.index(:omega)).to be > MwPipeline::TRACE.index(:handler)
  end

  # ── 3 ──────────────────────────────────────────────────────────────────────
  it "hooks within one class run in definition order" do
    request, response = real_pair
    Tina4::Middleware.run_before([MwPipeline::Ordered], request, response)
    # before_zulu is written FIRST; alphabetical order would be [alpha, zulu].
    expect(MwPipeline::TRACE).to eq(%i[zulu alpha])
  end

  # ── 4 ──────────────────────────────────────────────────────────────────────
  it "classes run in registration order" do
    request, response = real_pair
    Tina4::Middleware.run_before([MwPipeline::Bee, MwPipeline::Ay], request, response)
    # Registered Bee first; alphabetical order would be [ay, bee].
    expect(MwPipeline::TRACE).to eq(%i[bee ay])

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::Bee)
    Tina4::Router.use(MwPipeline::Ay)
    handler_route
    client.get("/probe")
    expect(MwPipeline::TRACE.first(2)).to eq(%i[bee ay])
  end

  # ── 5 ──────────────────────────────────────────────────────────────────────
  it "a before hook that returns a 4xx pair skips the handler" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::DenyPair], request, response)).to be false
    expect(response.status_code).to eq(403)

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::DenyPair)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(403)
    expect(handler_ran?).to be false
  end

  # ── 6 ── THE SECURITY REGRESSION ───────────────────────────────────────────
  it "a before hook that sets 4xx and returns nothing skips the handler" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::DenyNil], request, response)).to be false
    expect(response.status_code).to eq(403)

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::DenyNil)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(403)
    expect(handler_ran?).to be false
  end

  # ── 7 ──────────────────────────────────────────────────────────────────────
  it "after hooks still run when a before hook short circuits" do
    Tina4::Router.use(MwPipeline::DenyWithAfter)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(403)
    expect(handler_ran?).to be false
    expect(MwPipeline::TRACE).to include(:deny_with_after_after)
    expect(result.headers["x-after-ran"]).to eq("yes")
  end

  # ── 8 ──────────────────────────────────────────────────────────────────────
  it "a throwing before hook becomes a clean 500" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::ThrowingBefore], request, response)).to be false
    expect(response.status_code).to eq(500)
    expect(JSON.parse(response.body)).to eq({ "error" => "Internal Server Error", "status" => 500 })

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::ThrowingBefore)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(500)
    expect(result.json).to eq({ "error" => "Internal Server Error", "status" => 500 })
    expect(handler_ran?).to be false
  end

  # ── 9 ──────────────────────────────────────────────────────────────────────
  it "a throwing after hook does not stop the remaining after hooks" do
    request, response = real_pair
    Tina4::Middleware.run_after([MwPipeline::ThrowingAfter], request, response)
    expect(MwPipeline::TRACE).to eq(%i[throwing_after after_survivor])
  end

  # ── 10 ─────────────────────────────────────────────────────────────────────
  it "hook discovery includes hooks inherited from a base class" do
    request, response = real_pair
    Tina4::Middleware.run_before([MwPipeline::Derived], request, response)
    expect(MwPipeline::TRACE).to include(:base_before)

    MwPipeline.reset!
    Tina4::Middleware.run_after([MwPipeline::Derived], request, response)
    expect(MwPipeline::TRACE).to include(:base_after)
  end

  # ── 11 ─────────────────────────────────────────────────────────────────────
  it "inherited before hooks run before the subclass own hooks" do
    request, response = real_pair
    Tina4::Middleware.run_before([MwPipeline::Derived], request, response)
    expect(MwPipeline::TRACE).to eq(%i[base_before derived_before])
  end

  # ── 12 ─────────────────────────────────────────────────────────────────────
  it "route class middleware runs its before hook" do
    request, response = real_pair
    route = handler_route
    route.middleware(MwPipeline::RouteHooks)
    expect(route.run_middleware(request, response)).to be true
    expect(MwPipeline::TRACE).to include(:route_before)

    MwPipeline.reset!
    result = client.get("/probe")
    expect(result.status).to eq(200)
    expect(MwPipeline::TRACE).to include(:route_before)
    expect(result.headers["x-route-before"]).to eq("yes")
  end

  # ── 13 ─────────────────────────────────────────────────────────────────────
  it "route class middleware runs its after hook" do
    route = handler_route
    route.middleware(MwPipeline::RouteHooks)

    result = client.get("/probe")
    expect(result.status).to eq(200)
    expect(MwPipeline::TRACE).to include(:route_after)
    expect(MwPipeline::TRACE.index(:route_after)).to be > MwPipeline::TRACE.index(:handler)
    expect(result.headers["x-route-after"]).to eq("yes")
  end

  # ── 14 ─────────────────────────────────────────────────────────────────────
  it "a before hook that returns a response object short circuits" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::ReturnsResponse], request, response)).to be false
    expect(response.status_code).to eq(200)
    expect(JSON.parse(response.body)).to eq({ "taken_over" => true })

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::ReturnsResponse)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(200)
    expect(result.json).to eq({ "taken_over" => true })
    expect(handler_ran?).to be false
  end

  # ── 15 ── load-bearing: the >= 400 rule CANNOT express a 302 ────────────────
  it "a before hook that returns a redirect response short circuits" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::ReturnsRedirect], request, response)).to be false
    expect(response.status_code).to eq(302)
    expect(response.headers["location"]).to eq("/login")

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::ReturnsRedirect)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(302)
    expect(result.headers["location"]).to eq("/login")
    expect(handler_ran?).to be false

    # ...and the same rule at ROUTE scope.
    MwPipeline.reset!
    Tina4::Middleware.clear!
    Tina4::Router.clear!
    handler_route.middleware(MwPipeline::RouteReturnsRedirect)
    route_result = client.get("/probe")
    expect(route_result.status).to eq(302)
    expect(route_result.headers["location"]).to eq("/login")
    expect(handler_ran?).to be false
  end

  # ── 16 ─────────────────────────────────────────────────────────────────────
  it "a before hook that returns false short circuits with 403" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::ReturnsFalse], request, response)).to be false
    expect(response.status_code).to eq(403)

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::ReturnsFalse)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(403)
    expect(handler_ran?).to be false

    # ...at ROUTE scope too, where the halt used to discard the response and
    # return a hardcoded "403 Forbidden".
    MwPipeline.reset!
    Tina4::Middleware.clear!
    Tina4::Router.clear!
    handler_route.middleware(MwPipeline::RouteReturnsFalse)
    expect(client.get("/probe").status).to eq(403)
    expect(handler_ran?).to be false

    # A hook that returns false having ALREADY set a response keeps ITS
    # response — false must not clobber it with a hardcoded 403.
    MwPipeline.reset!
    Tina4::Middleware.clear!
    Tina4::Router.clear!
    Tina4::Router.use(MwPipeline::ReturnsFalseWithBody)
    handler_route
    kept = client.get("/probe")
    expect(kept.status).to eq(418)
    expect(kept.json).to eq({ "error" => "teapot" })
    expect(handler_ran?).to be false
  end

  # ── 17 ─────────────────────────────────────────────────────────────────────
  it "a before hook that returns nothing continues to the handler" do
    request, response = real_pair
    expect(Tina4::Middleware.run_before([MwPipeline::ReturnsNothing], request, response)).to be true
    expect(response.status_code).to eq(200)

    MwPipeline.reset!
    Tina4::Router.use(MwPipeline::ReturnsNothing)
    handler_route
    result = client.get("/probe")
    expect(result.status).to eq(200)
    expect(handler_ran?).to be true
  end
end

# ── String-form middleware specs (fact C) ────────────────────────────────────
#
# Python (`_resolve_string_middleware`), PHP (`Router::resolveStringMiddleware`)
# and Node (`resolveStringMiddleware`) all accept "ResponseCache" and
# "ResponseCache:300" in a route's middleware list. Ruby was the only one of the
# four with no such mechanism — a String in the list reached
# `mw.call(request, response)` and raised NoMethodError.
RSpec.describe "String-form route middleware (Python/PHP/Node parity)" do
  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end

  def real_pair(path = "/probe")
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "rack.input"     => StringIO.new("")
    }
    [Tina4::Request.new(env), Tina4::Response.new]
  end

  it "resolves the bare name to the configured middleware" do
    resolved = Tina4::Router.resolve_string_middleware("ResponseCache")
    expect(resolved).to be_a(Tina4::ResponseCache)
  end

  it "resolves the Name:arg form and applies the argument" do
    resolved = Tina4::Router.resolve_string_middleware("ResponseCache:300")
    expect(resolved).to be_a(Tina4::ResponseCache)
    expect(resolved.instance_variable_get(:@ttl)).to eq(300)
  end

  it "returns the SAME instance for the same spec so the cache actually hits" do
    first  = Tina4::Router.resolve_string_middleware("ResponseCache:120")
    second = Tina4::Router.resolve_string_middleware("ResponseCache:120")
    expect(first).to equal(second)
  end

  it "raises naming the known set for an unknown middleware name" do
    expect { Tina4::Router.resolve_string_middleware("NoSuchMiddleware") }
      .to raise_error(ArgumentError, /NoSuchMiddleware.*ResponseCache/m)
  end

  it "runs a string-specified middleware on the route instead of raising NoMethodError" do
    request, response = real_pair
    route = Tina4::Router.get("/probe") { |_rq, rs| rs.json({ ok: true }) }
    route.middleware("ResponseCache")
    expect { route.run_middleware(request, response) }.not_to raise_error
    expect(route.run_middleware(request, response)).to be true
  end
end
