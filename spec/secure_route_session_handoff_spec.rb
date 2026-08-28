# frozen_string_literal: true

# Secure route hands the validated principal + session + cookies to the handler.
#
# Regresses tina4-nodejs#57 (reported on 3.13.103): a login route stores a signed
# token in the session, a later SECURE GET is router-authenticated via the returned
# session cookie (a request WITHOUT the cookie gets 401), but the report says the
# handler saw request.user, request.session and request.cookies as UNAVAILABLE.
# Expected: the secure handler receives the validated principal AND the session.
#
# Driven through the REAL Rack app (Tina4::RackApp#call) with a real session-cookie
# round trip. NO MOCKS.
#
# Flow (exactly the reporter's):
#   1. POST /api/login (public) stores a signed token in the session -> Set-Cookie.
#   2. GET /api/secure (secured) WITHOUT the cookie -> 401 (the router gate works).
#   3. GET /api/secure WITH the session cookie -> 200, and the handler sees the
#      validated principal (user_id == 1), the token a prior request stored, and
#      the cookies.
#
# Same case names in all four:
#   tina4-python/tests/test_secure_route_session_handoff.py
#   tina4-php/tests/SecureRouteSessionHandoffTest.php
#   tina4-nodejs/test/secureRouteSessionHandoff.test.ts
require "spec_helper"
require "json"
require "stringio"
require "fileutils"

RSpec.describe "Secure route session handoff (#57)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_secure_handoff") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    ENV["TINA4_SECRET"] = "secure-handoff-secret"
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)

    # Public login route: store the token the TEST minted into the session.
    Tina4::Router.post("/api/login") do |req, res|
      req.session.set("token", req.body["token"])
      res.json({ ok: true }, 200)
    end.no_auth

    # Secured GET: echo exactly the three things #57 says go missing.
    Tina4::Router.get("/api/secure") do |req, res|
      res.json({
        ok: true,
        user: req.user || {},
        session_token: (req.session ? req.session.get("token") : nil),
        cookie_keys: (req.cookies || {}).keys
      }, 200)
    end.secure
  end

  after(:each) do
    Tina4::Router.clear!
    ENV.delete("TINA4_SECRET")
    FileUtils.rm_rf(tmp_dir)
  end

  def env_for(method, path, cookie: nil, body: "", content_type: nil)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "SERVER_NAME"    => "localhost",
      "SERVER_PORT"    => "7147",
      "rack.input"     => StringIO.new(body)
    }
    env["CONTENT_TYPE"] = content_type if content_type
    env["HTTP_COOKIE"] = cookie if cookie
    env
  end

  # Turn a response's Set-Cookie header into a Cookie request header.
  def cookie_header(headers)
    raw = headers["Set-Cookie"] || headers["set-cookie"] || ""
    raw.to_s.split("\n").map { |c| c.split(";").first }.join("; ")
  end

  it "secure GET handler receives the principal, the session, and the cookies" do
    token = Tina4::Auth.get_token({ "user_id" => 1, "role" => "admin" })

    # 1. Log in: the token lands in the session; the response mints the cookie.
    login_body = JSON.generate({ "token" => token })
    status, headers, _body = app.call(
      env_for("POST", "/api/login", body: login_body, content_type: "application/json")
    )
    expect(status).to eq(200), "login should succeed"
    cookie = cookie_header(headers)
    expect(cookie).not_to be_empty, "login must return a session cookie"

    # 2. The router gate really gates: no cookie -> 401, handler never runs.
    denied_status, = app.call(env_for("GET", "/api/secure"))
    expect(denied_status).to eq(401), "secure GET without the cookie must be 401"

    # 3. THE #57 assertion: with the cookie, the handler gets principal + session + cookies.
    ok_status, _h, ok_body = app.call(env_for("GET", "/api/secure", cookie: cookie))
    expect(ok_status).to eq(200), "secure GET with the cookie must be 200"
    data = JSON.parse(ok_body.join)
    expect(data["user"]).to be_a(Hash)
    expect(data["user"]["user_id"]).to eq(1), "request.user must carry the claims"
    expect(data["session_token"]).to eq(token), "request.session must round-trip the stored token"
    expect(data["cookie_keys"]).not_to be_empty, "request.cookies must be populated in the secured handler"
  end
end
