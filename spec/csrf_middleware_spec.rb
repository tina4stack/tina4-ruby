# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"

# Behavioural tests for CsrfMiddleware -- CSRF token enforcement on
# state-changing requests. Feature 37.
#
# NO MOCKS. Every request is a REAL Tina4::Request built from a Rack env; every
# response a REAL Tina4::Response; every token a REAL HMAC/RS256 JWT from
# Tina4::Auth or the REAL Frond generator; every no_auth route a REAL Tina4::Route;
# every bound session a REAL Tina4::Session. The middleware sees exactly what it
# sees when serving traffic, so a regression in the real wiring is caught here.
#
# The doubles this file used to build (RSpec `double`, stubbed respond_to?) HID
# three real bugs against the live pipeline: the no_auth skip read request.handler
# (never set on a real request), the session-binding read session.session_id /
# session.get("session_id") (a real Tina4::Session exposes neither -- it is
# get_session_id), and the query-string check read request.params (which MERGES
# the body, so a legit body token would false-trip it). Real objects catch all three.
RSpec.describe Tina4::CsrfMiddleware do
  let(:tmp_dir) { Dir.mktmpdir("tina4_csrf_test") }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)
    # A real signing secret so the SEC-01 blank-secret HARD-FAIL does not fire for
    # the behavioural cases (they exercise token validation, not the fail-closed
    # gate). The two SEC-01 cases delete it deliberately. Mirrors Python's autouse
    # fixture (TINA4_SECRET = "test-csrf-secret").
    ENV["TINA4_SECRET"] = "test-csrf-secret"
    # Real sessions in this spec write to a throwaway dir under tmp_dir.
    ENV["TINA4_SESSION_PATH"] = File.join(tmp_dir, "sessions")
    # No ambient session binding on Frond-generated tokens unless a test asks.
    Tina4::Frond.form_token_session_id = ""
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    ENV.delete("TINA4_CSRF")
    ENV.delete("TINA4_SECRET")
    ENV.delete("TINA4_SESSION_PATH")
    Tina4::Frond.form_token_session_id = ""
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  # ── Helpers (all REAL objects, no doubles) ─────────────────────

  # Build a REAL Tina4::Request from a Rack env.
  #   headers: -> HTTP_* env keys (so request.headers resolves them)
  #   body:    -> JSON body (so request.body parses it to a Hash)
  #   query:   -> QUERY_STRING (so request.query parses it)
  #   route:   -> the matched Tina4::Route (request.route, read by the no_auth skip)
  #   session: -> a REAL Tina4::Session injected as the request's session
  def build_request(method:, headers: {}, body: nil, query: {}, route: nil, session: nil)
    query_string = (query || {}).map { |k, v| "#{k}=#{v}" }.join("&")
    env = {
      "REQUEST_METHOD" => method.to_s.upcase,
      "PATH_INFO" => "/__csrf_probe",
      "QUERY_STRING" => query_string,
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.input" => StringIO.new("")
    }
    (headers || {}).each do |name, value|
      env["HTTP_#{name.to_s.upcase.tr('-', '_')}"] = value
    end
    if body && !body.empty?
      raw = JSON.generate(body)
      env["CONTENT_TYPE"] = "application/json"
      env["CONTENT_LENGTH"] = raw.bytesize.to_s
      env["rack.input"] = StringIO.new(raw)
    end
    request = Tina4::Request.new(env)
    request.route = route unless route.nil?
    request.instance_variable_set(:@session, session) unless session.nil?
    request
  end

  def new_response
    Tina4::Response.new
  end

  # A REAL public write route (marked .no_auth -> auth_required == false).
  def public_route
    Tina4::Route.new("POST", "/__csrf_public", ->(_req, _res) {}).no_auth
  end

  # A REAL secured write route (auth_required stays true by default).
  def secured_route
    Tina4::Route.new("POST", "/__csrf_guarded", ->(_req, _res) {})
  end

  # A REAL Tina4::Session whose id IS +sid+ (seed the backend, then adopt it under
  # strict mode -- the same pattern Python's _started_session uses).
  def started_session(sid)
    session = Tina4::Session.new({})
    session.start
    session.write(sid, { "_seeded" => true })
    session.start(sid)
    session
  end

  def form_token(claims = {})
    Tina4::Auth.get_token({ "type" => "form" }.merge(claims))
  end

  def parsed_body(response)
    JSON.parse(response.to_rack[2].first)
  end

  # ── 1. Skips GET requests ──────────────────────────────────────

  it "skips GET requests" do
    request = build_request(method: "GET")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 2. Skips HEAD requests ─────────────────────────────────────

  it "skips HEAD requests" do
    request = build_request(method: "HEAD")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 3. Skips OPTIONS requests ──────────────────────────────────

  it "skips OPTIONS requests" do
    request = build_request(method: "OPTIONS")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 4. Blocks POST without token — returns 403 ────────────────

  it "blocks POST without token and returns 403" do
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 5. Accepts formToken in body ───────────────────────────────

  it "accepts formToken in body" do
    request = build_request(method: "POST", body: { "formToken" => form_token })
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 6. Accepts X-Form-Token header ────────────────────────────

  it "accepts X-Form-Token header" do
    request = build_request(method: "POST", headers: { "X-Form-Token" => form_token })
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 7. Rejects formToken in query params — returns 403 ────────

  it "rejects formToken in query params with 403" do
    request = build_request(method: "POST", query: { "formToken" => form_token })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    body_json = parsed_body(response)
    expect(body_json["error"]).to eq(true)
    expect(body_json["code"]).to eq("CSRF_INVALID")
    expect(body_json["message"]).to include("query string")
  end

  # ── 8. Rejects invalid/expired token — returns 403 ────────────

  it "rejects an invalid token with 403" do
    request = build_request(method: "POST", body: { "formToken" => "invalid.token.here" })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  it "rejects an expired token with 403" do
    token = Tina4::Auth.get_token({ "type" => "form" }, expires_in: -10)
    request = build_request(method: "POST", body: { "formToken" => token })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 9. Skips no_auth routes ────────────────────────────────────

  it "skips routes marked no_auth" do
    request = build_request(method: "POST", route: public_route)
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 10. Skips Bearer auth requests ─────────────────────────────

  it "skips requests with a valid Bearer token" do
    bearer = Tina4::Auth.get_token({ "user_id" => 1 })
    request = build_request(method: "POST", headers: { "authorization" => "Bearer #{bearer}" })
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 11. Rejects token with wrong session_id — returns 403 ─────

  it "rejects token with wrong session_id" do
    token = form_token("session_id" => "session-abc")
    request = build_request(
      method: "POST",
      body: { "formToken" => token },
      session: started_session("session-xyz"),
    )
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 12. Accepts token with matching session_id ─────────────────

  it "accepts token with matching session_id" do
    token = form_token("session_id" => "session-abc")
    request = build_request(
      method: "POST",
      body: { "formToken" => token },
      session: started_session("session-abc"),
    )
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 13. PUT without token returns 403 ─────────────────────────

  it "blocks PUT without token and returns 403" do
    request = build_request(method: "PUT")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 14. DELETE without token returns 403 ──────────────────────

  it "blocks DELETE without token and returns 403" do
    request = build_request(method: "DELETE")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 15. PUT with valid body token passes ──────────────────────

  it "accepts formToken in body for PUT" do
    request = build_request(method: "PUT", body: { "formToken" => form_token })
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 16. Header used when body has no token ────────────────────

  it "accepts X-Form-Token header when body has no formToken" do
    request = build_request(
      method: "POST",
      headers: { "X-Form-Token" => form_token },
      body: { "name" => "Alice" },
    )
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 17. Wrong secret token returns 403 ────────────────────────

  it "rejects a token signed with a wrong secret" do
    # Generate a token with a DIFFERENT key pair (separate tmp dir), then validate
    # against the original -- a real cross-key rejection, no mocks.
    wrong_dir = Dir.mktmpdir("tina4_csrf_wrong")
    begin
      orig_priv = Tina4::Auth.instance_variable_get(:@private_key)
      orig_pub  = Tina4::Auth.instance_variable_get(:@public_key)
      orig_dir  = Tina4::Auth.instance_variable_get(:@keys_dir)

      Tina4::Auth.instance_variable_set(:@private_key, nil)
      Tina4::Auth.instance_variable_set(:@public_key, nil)
      Tina4::Auth.instance_variable_set(:@keys_dir, nil)
      Tina4::Auth.setup(wrong_dir)
      wrong_token = Tina4::Auth.get_token({ "type" => "form" })

      Tina4::Auth.instance_variable_set(:@private_key, orig_priv)
      Tina4::Auth.instance_variable_set(:@public_key, orig_pub)
      Tina4::Auth.instance_variable_set(:@keys_dir, orig_dir)

      request = build_request(method: "POST", body: { "formToken" => wrong_token })
      response = new_response

      Tina4::CsrfMiddleware.before_csrf(request, response)
      expect(response.status_code).to eq(403)
    ensure
      FileUtils.rm_rf(wrong_dir)
    end
  end

  # ── 18. Handler without noauth requires CSRF ──────────────────

  it "requires CSRF when handler has no_auth false" do
    # A secured route (auth_required true) still requires a token.
    request = build_request(method: "POST", route: secured_route)
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 19. Invalid Bearer does not skip CSRF ─────────────────────

  it "does not skip CSRF for an invalid Bearer token" do
    request = build_request(
      method: "POST",
      headers: { "authorization" => "Bearer invalid-token-here" },
    )
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 20. Token without session_id passes ───────────────────────

  it "accepts token without session_id claim (skips session binding)" do
    request = build_request(
      method: "POST",
      body: { "formToken" => form_token },
      session: started_session("some-other-session"),
    )
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 21. CSRF disabled via env false ───────────────────────────

  it "skips CSRF when TINA4_CSRF=false" do
    ENV["TINA4_CSRF"] = "false"
    request = build_request(method: "POST")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 22. CSRF default on without env ───────────────────────────

  it "enforces CSRF by default when TINA4_CSRF is not set" do
    ENV.delete("TINA4_CSRF")
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 23. CSRF enabled via env true ─────────────────────────────

  it "enforces CSRF when TINA4_CSRF=true" do
    ENV["TINA4_CSRF"] = "true"
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 24. CSRF disabled via env zero ────────────────────────────

  it "skips CSRF when TINA4_CSRF=0" do
    ENV["TINA4_CSRF"] = "0"
    request = build_request(method: "POST")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 25. CSRF disabled via env no ──────────────────────────────

  it "skips CSRF when TINA4_CSRF=no" do
    ENV["TINA4_CSRF"] = "no"
    request = build_request(method: "POST")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 26. 403 response has error envelope ───────────────────────

  it "returns error envelope with error and message fields on 403" do
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    body_json = parsed_body(response)
    expect(body_json["error"]).to eq(true)
    expect(body_json["code"]).to eq("CSRF_INVALID")
    expect(body_json).to have_key("message")
  end

  # ── 27. 403 query param rejection has specific message ────────

  it "returns query string rejection message in error envelope" do
    request = build_request(method: "POST", query: { "formToken" => form_token })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    body_json = parsed_body(response)
    expect(body_json["error"]).to eq(true)
    expect(body_json["code"]).to eq("CSRF_INVALID")
    expect(body_json["message"].downcase).to include("query string")
  end

  # ── 28. Missing token error has descriptive message ───────────

  it "returns descriptive message when no token provided" do
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    body_json = parsed_body(response)
    expect(body_json["message"]).to include("form token")
  end

  # ── 29. PATCH without token returns 403 ───────────────────────

  it "blocks PATCH without token and returns 403" do
    request = build_request(method: "PATCH")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ────────────────────────────────────────────────────────────────
  # Cross-framework conformance: the csrf_contract.json invariants.
  #
  # Each `it` description below matches a `case` name in
  # tina4-documentation/plan/v3/fixtures/csrf_contract.json verbatim, so the
  # shared auditor (scripts/audit-contract-fixtures.py) credits this suite. The
  # SAME case names appear in the Python (reference), PHP and Node CSRF suites.
  # Real HS256/RS256, real Request pipeline, real Frond generation, real
  # sessions; NO mocks.
  # ────────────────────────────────────────────────────────────────

  # csrf-no-default-secret (SEC-01). Assert the fail-closed MESSAGE, not merely
  # 403 -- a mismatched-signature token would 403 anyway, so the message is what
  # makes these a genuine gate for the blank-secret HARD-FAIL.
  it "forged default secret token is rejected" do
    ENV.delete("TINA4_SECRET")
    forged = Tina4::Auth.get_token({ "type" => "form" }, secret: "tina4-default-secret")
    request = build_request(method: "POST", body: { "formToken" => forged })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
    expect(parsed_body(response)["message"]).to include("TINA4_SECRET is not set")
  end

  it "forged blank secret token is rejected" do
    ENV.delete("TINA4_SECRET")
    forged = Tina4::Auth.get_token({ "type" => "form" }, secret: "")
    request = build_request(method: "POST", body: { "formToken" => forged })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
    expect(parsed_body(response)["message"]).to include("TINA4_SECRET is not set")
  end

  # csrf-frond-token-validates
  it "a frond emitted form token passes csrf" do
    # TINA4_SECRET is set by the before hook; the Frond generator and the
    # middleware resolve the SAME signing material, so a real token validates.
    token = Tina4::Frond.generate_form_jwt("")
    request = build_request(method: "POST", body: { "formToken" => token })
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # csrf-type-must-be-form
  it "a non form jwt in the form token slot is rejected" do
    # A validly-signed but non-form JWT (e.g. an auth token) must not be accepted
    # in the formToken slot.
    auth_jwt = Tina4::Auth.get_token({ "user_id" => 1 })
    request = build_request(method: "POST", body: { "formToken" => auth_jwt })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # csrf-session-binding. A REAL Tina4::Session (exposes get_session_id, NOT
  # session_id) proves the binding fires in the live pipeline.
  it "a token bound to a foreign session is rejected" do
    token = form_token("session_id" => "session-A")
    request = build_request(
      method: "POST",
      body: { "formToken" => token },
      session: started_session("session-B"),
    )
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # csrf-safe-methods-skipped
  it "a safe get request skips csrf" do
    request = build_request(method: "GET")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # csrf-write-methods-gated
  it "a post without a token is rejected" do
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # csrf-noauth-exempt
  it "a noauth write route skips csrf" do
    request = build_request(method: "POST", route: public_route)
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # csrf-bearer-exempt
  it "a valid bearer token skips csrf" do
    bearer = Tina4::Auth.get_token({ "user_id" => 1 })
    request = build_request(method: "POST", headers: { "authorization" => "Bearer #{bearer}" })
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # csrf-query-token-rejected
  it "a form token in the query string is rejected" do
    request = build_request(method: "POST", query: { "formToken" => form_token })
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # csrf-env-attach
  it "csrf is off by default" do
    ENV.delete("TINA4_CSRF")
    saved = Tina4::Middleware.global_middleware.dup
    begin
      Tina4::Middleware.clear!
      expect(Tina4::CsrfMiddleware.attach_from_env).to eq(false)
      expect(Tina4::Middleware.global_middleware).not_to include(Tina4::CsrfMiddleware)
    ensure
      Tina4::Middleware.clear!
      saved.each { |m| Tina4::Middleware.use(m) }
    end
  end

  it "csrf true attaches the middleware" do
    ENV["TINA4_CSRF"] = "true"
    saved = Tina4::Middleware.global_middleware.dup
    begin
      Tina4::Middleware.clear!
      expect(Tina4::CsrfMiddleware.attach_from_env).to eq(true)
      expect(Tina4::Middleware.global_middleware).to include(Tina4::CsrfMiddleware)
    ensure
      Tina4::Middleware.clear!
      saved.each { |m| Tina4::Middleware.use(m) }
    end
  end

  # csrf-403-envelope
  it "the rejection body is the csrf invalid envelope" do
    request = build_request(method: "POST")
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    body_json = parsed_body(response)
    expect(body_json["error"]).to eq(true)
    expect(body_json["code"]).to eq("CSRF_INVALID")
    expect(body_json["status"]).to eq(403)
  end

  # ────────────────────────────────────────────────────────────────
  # Real dispatch pipeline: proves prepare_route_request attaches the matched
  # Route to the request so the no_auth skip is NOT dead code. Drives the REAL
  # Tina4::RackApp through the in-process TestClient -- the same front controller
  # a live HTTP request goes through. No mocks.
  # ────────────────────────────────────────────────────────────────

  describe "real dispatch pipeline (no_auth route wiring)" do
    it "a no_auth write route passes the real CSRF middleware while a guarded one is blocked" do
      ENV["TINA4_CSRF"] = "true"
      Tina4::Router.post("/__csrf_e2e_public")  { |_req, res| res.json({ ok: true }) }.no_auth
      Tina4::Router.post("/__csrf_e2e_guarded") { |_req, res| res.json({ ok: true }) }
      Tina4::Middleware.use(Tina4::CsrfMiddleware)

      client = Tina4::TestClient.new
      public_res  = client.post("/__csrf_e2e_public", json: {})
      guarded_res = client.post("/__csrf_e2e_guarded", json: {})

      # The no_auth skip fires only because the pipeline attached request.route.
      expect(public_res.status).to eq(200)
      expect(public_res.json["ok"]).to eq(true)

      # CSRF is active on a guarded write with no token.
      expect(guarded_res.status).to eq(403)
      expect(guarded_res.json["code"]).to eq("CSRF_INVALID")
    end
  end
end
