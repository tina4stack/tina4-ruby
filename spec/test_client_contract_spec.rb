# frozen_string_literal: true
#
# Shared cross-framework conformance for feature 131 (TestClient fidelity).
#
# Plan: tina4-documentation/plan/v3/features/131-test-client.md
# Fixture: tina4-documentation/plan/v3/fixtures/test_client_contract.json
#
# Ruby's TestClient has always dispatched through the REAL front controller
# (RackApp#call, on RackApp.current or a lazily-built one) — this suite is the
# shared conformance fixture proven against all four languages, so a
# regression that made Ruby's TestClient skip a stage would be caught the same
# way Node's re-implemented dispatch is (TC-DEC-01). This is the model the
# oracle case is ported from spec/test_client_pipeline_spec.rb (D6).
#
# TC-DEC-02: get_all(name) is the new multi accessor for a duplicate response
# header (two Set-Cookie) — @headers[name] stays the back-compat single (last)
# value.
#
# Four cases, identical names in all four frameworks' own idiom:
#   * test client response equals a real socket request — THE ORACLE. Boots a
#     REAL Tina4::WebServer on a real TCP port (the same pattern
#     test_client_pipeline_spec.rb already uses) and asserts the in-process
#     TestClient response equals what the real socket gave back (status,
#     body, content-type, a custom marker header).
#   * a secured route returns 401 without running its route middleware —
#     locks gate-BEFORE-middleware (ADR-0012): a visible marker proves the
#     route's own middleware never ran on a request the gate already
#     rejected.
#   * a session login then authenticated request succeeds — locks the session
#     stage: a login route sets request.session.set("token", ...), the
#     Set-Cookie is threaded BY HAND (no cookie jar — TC-NO-COOKIE-JAR is
#     deliberately out of scope) into a second request to a .secure() route.
#   * duplicate response headers are all exposed — two response.cookie()
#     calls on one route; get_all("set-cookie") returns BOTH,
#     headers["set-cookie"] still collapses to the last (back-compat).
#
# NO MOCKS: the oracle is a real Tina4::WebServer on a real socket; every
# other case drives the real in-process dispatch (RackApp#call) through
# TestClient. Positive AND negative assertions throughout.

require "spec_helper"
require "socket"
require "net/http"
require "tmpdir"

# Visible marker a route-attached middleware class flips when it runs.
class Tc131Marker
  class << self
    def ran?
      @ran || false
    end

    def reset!
      @ran = false
    end

    def before_marker(request, response)
      @ran = true
      [request, response]
    end
  end
end

RSpec.describe "TestClient contract (feature 131)" do
  before(:each) do
    Tc131Marker.reset!

    Tina4::Router.post("/tc131-secured-write") do |_req, res|
      res.json({ created: true }, 201)
    end.middleware(Tc131Marker)

    Tina4::Router.post("/tc131-login") do |req, res|
      token = Tina4::Auth.get_token({ "sub" => "tc131-user" })
      req.session.set("token", token)
      res.json({ logged_in: true })
    end.no_auth

    Tina4::Router.get("/tc131-protected") do |_req, res|
      res.json({ ok: true })
    end.secure

    Tina4::Router.get("/tc131-cookies") do |_req, res|
      res.cookie("tc131_a", "1")
      res.cookie("tc131_b", "2")
      res.json({ ok: true })
    end
  end

  # ── the oracle ──────────────────────────────────────────────────────

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

  it "test client response equals a real socket request" do
    Tina4::Router.get("/tc131-oracle") do |_req, res|
      res.header("X-Tc131-Marker", "oracle")
      res.json({ pipeline: "ok" })
    end

    app = Tina4::RackApp.new(root_dir: Dir.mktmpdir("tina4_tc131_oracle"))
    port = free_port
    server = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)

    prev_override = ENV["TINA4_OVERRIDE_CLIENT"]
    prev_no_ai = ENV["TINA4_NO_AI_PORT"]
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    thread = Thread.new { server.start }
    thread.abort_on_exception = false
    begin
      wait_for_port(port)
    ensure
      if prev_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = prev_override end
      if prev_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = prev_no_ai end
    end

    begin
      uri = URI("http://127.0.0.1:#{port}/tc131-oracle")
      live = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) { |http| http.request(Net::HTTP::Get.new(uri)) }

      # The live server is the oracle: prove IT answered before trusting the
      # comparison (a shared failure could vacuously "match").
      expect(live.code.to_i).to eq(200), "live server did not answer /tc131-oracle"
      expect(live["X-Tc131-Marker"]).to eq("oracle")

      test_result = Tina4::TestClient.new(app).get("/tc131-oracle")

      expect(test_result.status).to eq(live.code.to_i)
      expect(test_result.body).to eq(live.body.to_s)
      expect(test_result.headers["content-type"]).to eq(live["content-type"])
      expect(test_result.headers["x-tc131-marker"]).to eq(live["X-Tc131-Marker"])
    ensure
      server&.stop
      thread&.kill
    end
  end

  # ── gate BEFORE route middleware (ADR-0012) ─────────────────────────

  it "a secured route returns 401 without running its route middleware" do
    expect(Tc131Marker.ran?).to be(false), "marker must start unset"

    response = Tina4::TestClient.new.post("/tc131-secured-write", json: { name: "Mallory" })

    expect(response.status).to eq(401), "a tokenless write to a secured route must 401"
    expect(Tc131Marker.ran?).to be(false),
      "the route's own middleware ran on a request the auth gate should have " \
      "rejected first — gate-before-middleware order (ADR-0012) is broken"

    # Positive control: a VALID token lets the request through, and only THEN
    # does the route's own middleware run — proving the marker mechanism
    # itself works (a permanently-false marker would pass the negative
    # assertion above for the wrong reason).
    token = Tina4::Auth.get_token({ "sub" => "tc131-user" })
    ok = Tina4::TestClient.new.post(
      "/tc131-secured-write", json: { name: "Alice" }, headers: { "Authorization" => "Bearer #{token}" }
    )
    expect(ok.status).to eq(201)
    expect(Tc131Marker.ran?).to be(true), "middleware must run for an authorised request"
  end

  # ── the session stage runs ───────────────────────────────────────────

  it "a session login then authenticated request succeeds" do
    client = Tina4::TestClient.new

    # Negative first: the protected route is genuinely gated.
    bare = client.get("/tc131-protected")
    expect(bare.status).to eq(401), "the session-guarded route must reject an unauthenticated request"

    login_response = client.post("/tc131-login")
    expect(login_response.status).to eq(200)
    set_cookie = login_response.headers["set-cookie"]
    expect(set_cookie).not_to be_nil, "login must set a session cookie for the session stage to have run"
    cookie_pair = set_cookie.split(";").first

    protected_response = client.get("/tc131-protected", headers: { "Cookie" => cookie_pair })
    expect(protected_response.status).to eq(200),
      "replaying the session cookie must authenticate the request via the " \
      "session-token path — this is structurally unreachable if the session " \
      "stage never attaches request.session"
    expect(protected_response.json).to eq({ "ok" => true })
  end

  # ── duplicate response headers are all exposed (TC-DEC-02) ─────────

  it "duplicate response headers are all exposed" do
    response = Tina4::TestClient.new.get("/tc131-cookies")

    expect(response.status).to eq(200)
    all_cookies = response.get_all("set-cookie")
    expect(all_cookies.length).to eq(2), "expected 2 Set-Cookie values, got: #{all_cookies.inspect}"
    expect(all_cookies.any? { |c| c.start_with?("tc131_a=1") }).to be(true)
    expect(all_cookies.any? { |c| c.start_with?("tc131_b=2") }).to be(true)

    # Back-compat: the single accessor still collapses to ONE value (the last
    # one sent), never an array — existing callers are unaffected.
    expect(response.headers["set-cookie"]).to be_a(String)
    expect(all_cookies).to include(response.headers["set-cookie"])

    # Negative: a header that was only ever sent once returns a one-item
    # array, not an empty one, and a header never sent returns [].
    expect(response.get_all("content-type")).to eq([response.headers["content-type"]])
    expect(response.get_all("x-tc131-never-sent")).to eq([])
  end
end
