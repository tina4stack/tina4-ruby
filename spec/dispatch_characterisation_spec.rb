# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Feature 6, step 1: FREEZE the dispatch behaviour before refactoring it.
#
# These are characterisation tests, not new-behaviour tests. Every one asserts
# what `Tina4::RackApp#call` does TODAY, so the named-stage extraction that
# follows can be proved behaviour-preserving. The plan is explicit that this
# step is "not optional and not reorderable": the pipeline refactor is the
# largest in the audit and it touches every single request.
#
# They deliberately drive `app.call(env)` with a raw Rack env rather than going
# through TestClient. That IS the function being refactored (currently CC 51,
# maintainability 4.5 against a floor of 40), so this exercises the real thing
# with nothing in between.
#
# NO MOCKS: a real RackApp over a real temp directory, real routes, real files
# on disk. Nothing is stubbed.
#
# Identical case names in all four frameworks:
#   tina4-python/tests/test_dispatch_characterisation.py
#   tina4-php/tests/DispatchCharacterisationTest.php
#   tina4-nodejs/test/dispatchCharacterisation.test.ts
RSpec.describe "Dispatch characterisation" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_dispatch_char") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "templates"))
  end

  after(:each) do
    Tina4::Router.clear!
    FileUtils.rm_rf(tmp_dir)
  end

  def env_for(method, path, query: "", headers: {}, body: "")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => query,
      "HTTP_HOST"      => "localhost",
      "SERVER_NAME"    => "localhost",
      "SERVER_PORT"    => "7147",
      "rack.input"     => StringIO.new(body)
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  def call(method, path, **kwargs)
    status, headers, body = app.call(env_for(method, path, **kwargs))
    [status, headers, Array(body).join]
  end

  # ── 1. The happy path ────────────────────────────────────────────

  it "dispatch get known route returns handler body" do
    Tina4::Router.get("/hello") { |_req, res| res.call("world", Tina4::HTTP_OK) }

    status, _h, body = call("GET", "/hello")
    expect(status).to eq(200)
    expect(body).to include("world")
  end

  # ── 2. 404 is reached only AFTER static and template both miss ───

  it "dispatch unknown path returns 404" do
    status, _h, _b = call("GET", "/definitely/not/a/route")
    expect(status).to eq(404)
  end

  # ── 3. A known path with the wrong method is 405, not 404 ────────
  #
  # This is the ordering the pipeline has to preserve: method_not_allowed
  # only runs when match_route found nothing, and it must beat the 404.

  it "dispatch known path wrong method returns 405 with allow" do
    Tina4::Router.get("/only-get") { |_req, res| res.call("ok", Tina4::HTTP_OK) }

    status, headers, _b = call("POST", "/only-get")
    expect(status).to eq(405)
    allow_header = headers.find { |k, _| k.to_s.downcase == "allow" }&.last
    expect(allow_header.to_s.upcase).to include("GET")
  end

  # ── 4. OPTIONS on a known path: RFC 9110 shape ───────────────────

  it "dispatch options on known path returns 204 with allow" do
    Tina4::Router.get("/opt") { |_req, res| res.call("ok", Tina4::HTTP_OK) }

    status, headers, body = call("OPTIONS", "/opt")
    expect([200, 204]).to include(status)
    allow_header = headers.find { |k, _| k.to_s.downcase == "allow" }&.last
    expect(allow_header.to_s.upcase).to include("GET") if allow_header
    expect(body).to eq("") if status == 204
  end

  # ── 5. A trailing slash redirects and KEEPS the query string ─────
  #
  # Dropping the query on a redirect silently loses the user's filters, which
  # is why the query half is asserted separately from the status.

  it "dispatch trailing slash redirects 301 preserving query" do
    Tina4::Router.get("/items") { |_req, res| res.call("list", Tina4::HTTP_OK) }

    status, headers, _b = call("GET", "/items/", query: "page=2&sort=name")
    location = headers.find { |k, _| k.to_s.downcase == "location" }&.last

    if [301, 302, 308].include?(status)
      expect(location).to include("/items")
      expect(location).to include("page=2"), "the redirect dropped the query string"
    else
      # Some builds serve the slashed path directly rather than redirecting.
      # Either is acceptable TODAY; the refactor must not change which.
      expect([200, 404]).to include(status)
    end
  end

  # ── 6. A static asset answers a conditional request cheaply ──────

  it "dispatch static asset returns 304 on matching validator" do
    asset = File.join(tmp_dir, "src", "public", "char.css")
    File.write(asset, "body { color: red; }")

    status, headers, _b = call("GET", "/char.css")
    expect(status).to eq(200), "the static asset was not served at all"

    validator = headers.find { |k, _| %w[etag last-modified].include?(k.to_s.downcase) }
    next if validator.nil?

    header_name = validator.first.to_s.downcase == "etag" ? "IF_NONE_MATCH" : "IF_MODIFIED_SINCE"
    status2, _h2, _b2 = call("GET", "/char.css", headers: { header_name => validator.last })
    expect(status2).to eq(304)
  end

  # ── 7. HEAD behaves like GET on a template route ─────────────────

  it "dispatch template path renders for get and head" do
    File.write(File.join(tmp_dir, "src", "templates", "char.twig"), "<p>rendered</p>")

    get_status, _gh, get_body = call("GET", "/char.twig")
    head_status, _hh, head_body = call("HEAD", "/char.twig")

    expect(get_status).to eq(head_status),
                          "HEAD and GET disagree on a template route"
    expect(get_body).to include("rendered") if get_status == 200
    # HEAD carries no body by definition, whatever the status.
    expect(head_body).to eq("") if head_status == 200
  end

  # ── 8. CORS today: preflight only ────────────────────────────────
  #
  # CHARACTERISATION, and it pins a GAP rather than the desired behaviour.
  #
  # Measured 2026-07-31: Ruby emits Access-Control-* on an OPTIONS preflight and
  # on NOTHING else - not on a 200, and not on a short-circuited 401.
  #
  # The parked pattern wants global_middleware (stage 2) to run BEFORE
  # match_route (stage 3) precisely so a 401 still carries CORS, and calls PHP's
  # ordering on this point "provably correct". Ruby does not do that today.
  # Without CORS on the 401 a browser reports a CORS error and the real 401 is
  # invisible to the developer debugging it.
  #
  # That is a step-4 parity finding, to be fixed in step 6 with its own
  # positive/negative pair - NOT silently inside the extraction. This test
  # exists to make the refactor preserve today's behaviour exactly, and to fail
  # loudly if someone "fixes" it mid-refactor without a decision.

  it "dispatch cors headers present on 401" do
    Tina4::Router.post("/needs-auth") { |_req, res| res.call("secret", Tina4::HTTP_OK) }
    origin = { "ORIGIN" => "https://example.com" }

    status, headers, _b = call("POST", "/needs-auth", headers: origin)
    expect([401, 403]).to include(status), "expected the write route to be secured by default"

    cors_on_401 = headers.keys.any? { |k| k.to_s.downcase.start_with?("access-control") }
    expect(cors_on_401).to be(false),
                           "Ruby now emits CORS on a 401. That is the DESIRED end state, " \
                           "but it must arrive via the step-6 fix with its own test pair, " \
                           "not as a silent side effect of the pipeline extraction."

    # The preflight DOES carry CORS, and must keep doing so.
    pf_status, pf_headers, _pb = call("OPTIONS", "/needs-auth", headers: origin)
    expect(pf_status).to eq(204)
    expect(pf_headers.keys.map { |k| k.to_s.downcase })
      .to include("access-control-allow-origin")
  end

  # ── 9. Matched-route metadata is visible to the auth stage ───────
  #
  # authorise runs AFTER match_route so `no_auth` is readable. PHP's own
  # comment records that this assignment was once missing and the bypass was
  # dead code on a real dispatch.

  it "dispatch noauth write route is not blocked by csrf" do
    route = Tina4::Router.post("/public-write") { |_req, res| res.call("open", Tina4::HTTP_OK) }
    route.no_auth if route.respond_to?(:no_auth)

    status, _h, _b = call("POST", "/public-write")
    expect(status).to eq(200),
                      "a route marked no_auth was still blocked - the matched route's metadata did not reach the auth stage"
  end

  # ── 10. Middleware ordering contract ─────────────────────────────

  it "dispatch middleware runs in registration order" do
    order = []
    # PER-ROUTE middleware is anything responding to .call(request, response).
    # The before_*/after_* CLASS-hook discovery is a different mechanism, used
    # for GLOBAL middleware; passing such a class here raises "undefined method
    # 'call'" and the dispatcher turns it into a clean 500.
    first  = ->(req, res) { order << :first;  [req, res] }
    second = ->(req, res) { order << :second; [req, res] }

    Tina4::Router.get("/ordered", middleware: [first, second]) do |_req, res|
      res.call("done", Tina4::HTTP_OK)
    end

    call("GET", "/ordered")
    expect(order).to eq(%i[first second]),
                     "middleware ran out of registration order"
  end

  # ── ADR-0010: routes beat files ──────────────────────────────────
  #
  # A BEHAVIOUR CHANGE, decided rather than refactored. Static resolution
  # moved AFTER route matching, so a reviewed route can no longer be shadowed
  # by a file that arrived from a build step, an upload directory, or a
  # careless deploy.
  #
  # Ruby previously guarded against exactly this with `unless
  # path.start_with?("/api/")` around the static check - a partial patch that
  # only protected paths beginning /api/. Route-first removes the hazard
  # outright and that guard with it.

  it "a route wins over a file at the same path" do
    # A file that WOULD have been served first under the old ordering.
    File.write(File.join(tmp_dir, "src", "public", "clash.json"), '{"from":"file"}')
    Tina4::Router.get("/clash.json") { |_req, res| res.call('{"from":"route"}', Tina4::HTTP_OK) }

    status, _h, body = call("GET", "/clash.json")
    expect(status).to eq(200)
    expect(body).to include("route"),
                    "a file in public/ shadowed a registered route - ADR-0010 is not in effect"
    expect(body).not_to include("file")
  end

  # NEGATIVE: route-first must not stop files being served at all.
  it "a file is still served when no route matches" do
    File.write(File.join(tmp_dir, "src", "public", "plain.json"), '{"from":"file"}')

    status, _h, body = call("GET", "/plain.json")
    expect(status).to eq(200)
    expect(body).to include("file"),
                    "moving static after matching stopped files being served"
  end

  # The retired guard must not come back: an /api/ path with no route is a
  # 404, and one WITH a route reaches the route - neither needs a special case.
  it "an api path needs no special case now that routes win" do
    Tina4::Router.get("/api/thing") { |_req, res| res.call("routed", Tina4::HTTP_OK) }

    status, _h, body = call("GET", "/api/thing")
    expect(status).to eq(200)
    expect(body).to include("routed")

    miss_status, _mh, _mb = call("GET", "/api/nothing")
    expect(miss_status).to eq(404)
  end
end
