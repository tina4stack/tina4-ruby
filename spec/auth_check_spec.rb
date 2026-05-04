# frozen_string_literal: true

# Tests for the expanded _check_auth logic in RackApp#handle_route.
# Covers three token sources (Bearer header, body formToken, session token),
# the FreshToken response header, and priority ordering.
#
# Run: bundle exec rspec spec/auth_check_spec.rb

require "spec_helper"
require "json"
require "uri"
require "fileutils"

RSpec.describe "RackApp auth check (header / body / session)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_auth_check_test") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    ENV["TINA4_SECRET"] = "auth-check-test-secret"
    # Force HMAC mode — clear any RSA key state
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)

    # Register a secured POST route that echoes auth payload
    Tina4::Router.post("/secure/action") do |req, res|
      res.json({ ok: true, user: req.user || {} }, 200)
    end

    # Register a secured GET route for session token testing
    Tina4::Router.get("/secure/dashboard") { |req, res|
      res.json({ ok: true, user: req.user || {} }, 200)
    }.secure
  end

  after(:each) do
    Tina4::Router.clear!
    ENV.delete("TINA4_SECRET")
    ENV.delete("TINA4_API_KEY")
    FileUtils.rm_rf(tmp_dir)
  end

  # ── Helper: build a minimal Rack env ───────────────────────────

  def mock_env(method, path, headers: {}, body: "", content_type: nil, cookie: nil)
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
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  # ── 1. Valid Bearer header passes ──────────────────────────────

  it "allows request with valid Bearer header" do
    token = Tina4::Auth.get_token({ "sub" => "header-user" })
    env = mock_env("POST", "/secure/action",
                   headers: { "AUTHORIZATION" => "Bearer #{token}" })

    status, _headers, body = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body.join)
    expect(parsed["ok"]).to eq(true)
    expect(parsed["user"]["sub"]).to eq("header-user")
  end

  # ── 2. Invalid Bearer header fails with 401 ───────────────────

  it "returns 401 for invalid Bearer header" do
    env = mock_env("POST", "/secure/action",
                   headers: { "AUTHORIZATION" => "Bearer invalid.token.here" })

    status, _headers, body = app.call(env)
    expect(status).to eq(401)

    parsed = JSON.parse(body.join)
    expect(parsed["error"]).to eq("Unauthorized")
  end

  # ── 3. Valid formToken in body passes ──────────────────────────

  it "allows request with valid formToken in JSON body" do
    token = Tina4::Auth.get_token({ "type" => "form", "context" => "checkout" })
    json_body = JSON.generate({ "formToken" => token, "name" => "Test" })
    env = mock_env("POST", "/secure/action",
                   body: json_body,
                   content_type: "application/json")

    status, _headers, body = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body.join)
    expect(parsed["ok"]).to eq(true)
    expect(parsed["user"]["type"]).to eq("form")
  end

  it "allows request with valid formToken in URL-encoded body" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    form_body = "name=Test&formToken=#{URI.encode_www_form_component(token)}"
    env = mock_env("POST", "/secure/action",
                   body: form_body,
                   content_type: "application/x-www-form-urlencoded")

    status, _headers, body = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body.join)
    expect(parsed["ok"]).to eq(true)
  end

  # ── 4. FreshToken header is returned when body token validates ─

  it "returns FreshToken header when formToken in body validates" do
    token = Tina4::Auth.get_token({ "type" => "form", "context" => "checkout" })
    json_body = JSON.generate({ "formToken" => token })
    env = mock_env("POST", "/secure/action",
                   body: json_body,
                   content_type: "application/json")

    status, headers, _body = app.call(env)
    expect(status).to eq(200)
    expect(headers).to have_key("FreshToken")
    expect(headers["FreshToken"]).not_to be_nil
    expect(headers["FreshToken"]).not_to be_empty

    # The fresh token should itself be valid
    expect(Tina4::Auth.valid_token(headers["FreshToken"])).to be_truthy
  end

  it "does NOT return FreshToken header when Bearer header is used" do
    token = Tina4::Auth.get_token({ "sub" => "header-user" })
    env = mock_env("POST", "/secure/action",
                   headers: { "AUTHORIZATION" => "Bearer #{token}" })

    status, headers, _body = app.call(env)
    expect(status).to eq(200)
    expect(headers).not_to have_key("FreshToken")
  end

  # ── 5. Valid session token passes ──────────────────────────────

  it "allows request with valid token stored in session" do
    token = Tina4::Auth.get_token({ "sub" => "session-user" })

    # Create a session and store the token in it
    session = Tina4::Session.new({})
    session.set("token", token)
    session.save
    session_id = session.id

    env = mock_env("GET", "/secure/dashboard",
                   cookie: "tina4_session=#{session_id}")

    status, _headers, body = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body.join)
    expect(parsed["ok"]).to eq(true)
    expect(parsed["user"]["sub"]).to eq("session-user")
  end

  # ── 6. All invalid returns 401 ─────────────────────────────────

  it "returns 401 when no token is provided at all" do
    env = mock_env("POST", "/secure/action")

    status, _headers, body = app.call(env)
    expect(status).to eq(401)
  end

  it "returns 401 for invalid formToken in body" do
    json_body = JSON.generate({ "formToken" => "garbage.invalid.token" })
    env = mock_env("POST", "/secure/action",
                   body: json_body,
                   content_type: "application/json")

    status, _headers, body = app.call(env)
    expect(status).to eq(401)
  end

  it "returns 401 for expired session token" do
    # Create a token that is already expired
    expired_token = Tina4::Auth.get_token({ "sub" => "expired-user" }, expires_in: -1)

    session = Tina4::Session.new({})
    session.set("token", expired_token)
    session.save
    session_id = session.id

    env = mock_env("GET", "/secure/dashboard",
                   cookie: "tina4_session=#{session_id}")

    status, _headers, _body = app.call(env)
    expect(status).to eq(401)
  end

  # ── 7. Priority chain: header > body > session ─────────────────

  it "prefers Bearer header over body formToken" do
    header_token = Tina4::Auth.get_token({ "sub" => "header-user", "source" => "header" })
    body_token = Tina4::Auth.get_token({ "sub" => "body-user", "source" => "body" })
    json_body = JSON.generate({ "formToken" => body_token })

    env = mock_env("POST", "/secure/action",
                   headers: { "AUTHORIZATION" => "Bearer #{header_token}" },
                   body: json_body,
                   content_type: "application/json")

    status, headers, body = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body.join)
    expect(parsed["user"]["source"]).to eq("header")

    # No FreshToken because header was used, not body
    expect(headers).not_to have_key("FreshToken")
  end

  it "prefers body formToken over session token" do
    body_token = Tina4::Auth.get_token({ "sub" => "body-user", "source" => "body" })
    session_token = Tina4::Auth.get_token({ "sub" => "session-user", "source" => "session" })

    session = Tina4::Session.new({})
    session.set("token", session_token)
    session.save
    session_id = session.id

    json_body = JSON.generate({ "formToken" => body_token })
    env = mock_env("POST", "/secure/action",
                   body: json_body,
                   content_type: "application/json",
                   cookie: "tina4_session=#{session_id}")

    status, headers, body = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body.join)
    expect(parsed["user"]["source"]).to eq("body")

    # FreshToken should be present because body token was used
    expect(headers).to have_key("FreshToken")
  end
end
