# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"

# Global middleware runs in TWO passes, split by what it depends on.
#
# The two groups need opposite things and cannot share a position:
#
#   PRE-match  - must survive a short-circuit, needs no route metadata.
#                CORS lives here. A browser shown a 401 with no CORS headers
#                reports a CORS error, so the real 401 never reaches the
#                developer debugging it.
#   POST-match - reads the matched route's metadata. CSRF lives here, because
#                it must honour a route marked no_auth. PHP shipped exactly
#                that bypass as DEAD CODE once, because the metadata was not
#                assigned yet on a real dispatch.
#
# Moving the whole pass before matching would have broken the second group -
# measured, not assumed: Python's middleware reads request._handler /
# _noauth, and Ruby's characterisation suite covers the same behaviour.
#
# Opt-in via `def self.pre_match?; true; end`. Everything else keeps running
# exactly where it always has, so this is additive.
#
# NO MOCKS: a real RackApp, real routes, real dispatch.
RSpec.describe "Global middleware pre/post split" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_mw_split") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    FileUtils.rm_rf(tmp_dir)
  end

  def call(method, path)
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147", "rack.input" => StringIO.new("")
    }
    status, headers, body = app.call(env)
    [status, headers, Array(body).join]
  end

  # A pre-match middleware that stamps a header, like CORS would.
  def stamping_middleware(pre_match:)
    Class.new do
      define_singleton_method(:pre_match?) { pre_match }
      class << self
        def before_stamp(req, res)
          res.add_header("X-Ran-Before-Match", "yes") if res.respond_to?(:add_header)
          [req, res]
        end
      end
    end
  end

  # ── POSITIVE: middleware runs before a route is even matched ────

  it "pre match middleware runs on a path with NO route at all" do
    Tina4::Middleware.use(stamping_middleware(pre_match: true))

    status, _h, _b = call("GET", "/no/such/route")
    expect(status).to eq(404)
    # The point: it ran even though nothing matched. A post-match middleware
    # could not have, because the dispatch never reaches that pass.
    expect(Tina4::Middleware.pre_match_middleware.size).to eq(1)
    expect(Tina4::Middleware.post_match_middleware).to be_empty
  end

  # ── POSITIVE: its work SURVIVES a short-circuited auth failure ──
  #
  # This is the case the whole split exists for.

  it "pre match middleware output survives a 401" do
    Tina4::Middleware.use(stamping_middleware(pre_match: true))
    Tina4::Router.post("/secured") { |_q, s| s.call("x", Tina4::HTTP_OK) }

    status, headers, _b = call("POST", "/secured")
    expect(status).to eq(401), "expected the write route to be secured by default"

    stamped = headers.find { |k, _| k.to_s.downcase == "x-ran-before-match" }
    expect(stamped).not_to be_nil,
                          "a pre-match middleware's header was lost on the 401 - the " \
                          "pre-match response is not being threaded through"
  end

  # ── NEGATIVE: the default is UNCHANGED ──────────────────────────
  #
  # Middleware that does not opt in must keep running after matching, where
  # the route metadata it may depend on is readable.

  it "middleware without the flag still runs after matching" do
    Tina4::Middleware.use(stamping_middleware(pre_match: false))

    expect(Tina4::Middleware.pre_match_middleware).to be_empty
    expect(Tina4::Middleware.post_match_middleware.size).to eq(1)
  end

  # ── NEGATIVE: the split must not weaken the auth gate ───────────
  #
  # "Middleware before a route, still secure" - registering pre-match
  # middleware must not open a secured route.

  it "pre match middleware does not open a secured route" do
    Tina4::Middleware.use(stamping_middleware(pre_match: true))
    Tina4::Router.post("/still-secured") { |_q, s| s.call("x", Tina4::HTTP_OK) }

    status, _h, _b = call("POST", "/still-secured")
    expect(status).to eq(401),
                      "registering pre-match middleware relaxed the auth gate"
  end

  # ── The route handler still sees the matched params ─────────────
  #
  # The request is built BEFORE matching now, so path params are attached
  # afterwards. If the memoised #params were not reset, the handler would read
  # a param-less copy.

  it "path params still reach the handler when the request is built early" do
    Tina4::Middleware.use(stamping_middleware(pre_match: true))
    Tina4::Router.get("/items/{id}") do |req, res|
      res.call({ id: req.params["id"] }, Tina4::HTTP_OK)
    end

    status, _h, body = call("GET", "/items/42")
    expect(status).to eq(200)
    expect(body).to include("42"),
                    "path params were lost - the pre-built request memoised #params too early"
  end
end
