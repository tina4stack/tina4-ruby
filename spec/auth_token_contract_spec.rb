# frozen_string_literal: true

# Auth-token rules: the cross-framework contract (ADR-0079).
#
# The answer key is tina4-documentation/plan/v3/fixtures/auth_token_contract.json.
# Each `it` below is a `case` in that fixture; the SAME cases run in:
#
#   tina4-python/tests/test_auth_token_contract.py   (reference)
#   tina4-php/tests/AuthTokenContractTest.php
#   tina4-nodejs/test/authTokenContract.test.ts
#
# Real RackApp#call, real Frond form tokens, real HMAC, real file sessions, real
# .env files and real child Ruby processes for the boot checks. No mocks.
require "spec_helper"
require "json"
require "stringio"
require "fileutils"
require "open3"
require "rbconfig"
require "openssl"
require "base64"

RSpec.describe "Auth-token rules (ADR-0079)" do
  secret = "auth-token-contract-secret-0123456789abcdef"

  let(:tmp_dir) { Dir.mktmpdir("tina4_auth_contract") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    @saved_env = ENV.to_h.select { |k, _| k.start_with?("TINA4_") }
    ENV["TINA4_SECRET"] = secret
    ENV.delete("TINA4_API_KEY")
    ENV.delete("TINA4_CSRF")
    ENV.delete("TINA4_TOKEN_LIMIT")
    ENV["TINA4_SESSION_BACKEND"] = "file"
    ENV["TINA4_SESSION_PATH"] = File.join(tmp_dir, "sessions")
    Tina4::Frond.form_token_session_id = ""
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, File.join(tmp_dir, ".keys"))

    Tina4::Router.post("/contract/session") do |req, res|
      (req.body.is_a?(Hash) ? req.body : {}).each { |key, value| req.session.set(key, value) }
      res.json({ ok: true }, 200)
    end.no_auth

    Tina4::Router.post("/contract/write") do |req, res|
      res.json({ user: req.user }, 200)
    end

    Tina4::Router.get("/contract/read") do |req, res|
      res.json({ user: req.user }, 200)
    end.secure
  end

  after(:each) do
    Tina4::Router.clear!
    ENV.keys.select { |k| k.start_with?("TINA4_") }.each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def call(method, path, body: nil, headers: {}, cookie: nil)
    raw = body.nil? ? "" : JSON.generate(body)
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "REMOTE_ADDR" => "127.0.0.1", "rack.input" => StringIO.new(raw)
    }
    env["CONTENT_TYPE"] = "application/json" unless raw.empty?
    env["HTTP_COOKIE"] = cookie if cookie
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    status, response_headers, response_body = app.call(env)
    [status, response_headers, response_body.respond_to?(:join) ? response_body.join : response_body.to_s]
  end

  def session_cookie(values)
    status, headers, body = call("POST", "/contract/session", body: values)
    expect(status).to eq(200), body
    raw = headers["Set-Cookie"] || headers["set-cookie"] || ""
    cookie = raw.to_s.split("\n").map { |c| c.split(";").first }.join("; ")
    expect(cookie).not_to be_empty, "the session route minted no cookie"
    cookie
  end

  def form_token
    Tina4::Frond.generate_form_jwt("").to_s
  end

  def fresh_token_header(headers)
    headers["FreshToken"] || headers["freshtoken"]
  end

  def hs256(payload, key)
    b64 = ->(data) { Base64.urlsafe_encode64(data, padding: false) }
    head = b64.call(JSON.generate({ alg: "HS256", typ: "JWT" }))
    body = b64.call(JSON.generate(payload))
    "#{head}.#{body}.#{b64.call(OpenSSL::HMAC.digest('SHA256', key, "#{head}.#{body}"))}"
  end

  def user_of(body)
    JSON.parse(body)["user"]
  end

  # ── auth-form-token-is-not-identity ───────────────────────────────────

  it "a form token in the bearer header is refused by the route gate" do
    status, = call("POST", "/contract/write", headers: { "Authorization" => "Bearer #{form_token}" })
    expect(status).to eq(401)
  end

  it "a form token in the body is refused by the route gate" do
    status, headers, = call("POST", "/contract/write", body: { "formToken" => form_token })
    expect(status).to eq(401)
    expect(fresh_token_header(headers)).to be_nil
  end

  it "a form token in the session is refused by the route gate" do
    cookie = session_cookie({ "token" => form_token })
    status, = call("GET", "/contract/read", cookie: cookie)
    expect(status).to eq(401)
  end

  it "a form token in the body falls through to the session token" do
    cookie = session_cookie({ "token" => Tina4::Auth.get_token({ "user_id" => 7 }) })
    status, _headers, body = call("POST", "/contract/write", body: { "formToken" => form_token }, cookie: cookie)
    expect(status).to eq(200), body
    expect(user_of(body)["user_id"]).to eq(7)
  end

  it "a form token is refused on a secured websocket upgrade" do
    form = form_token
    expect(Tina4.ws_authorized(true, { "authorization" => "Bearer #{form}" })).to eq([nil, false])
    expect(Tina4.ws_authorized(true, {}, "", "bearer, #{form}")).to eq([nil, false])
    expect(Tina4.ws_authorized(true, {}, "token=#{form}")).to eq([nil, false])
    payload, ok = Tina4.ws_authorized(true, { "authorization" => "Bearer #{Tina4::Auth.get_token({ 'user_id' => 3 })}" })
    expect(ok).to be(true)
    expect(payload["user_id"]).to eq(3)
  end

  it "a form token is refused by authenticate request" do
    expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{form_token}" })).to be_nil
    token = Tina4::Auth.get_token({ "user_id" => 4 })
    expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })["user_id"]).to eq(4)
    env = { "HTTP_AUTHORIZATION" => "Bearer #{form_token}" }
    expect(Tina4::Auth.bearer_auth.call(env)).to be(false)
  end

  it "refresh never issues a fresh token from a form token" do
    # The gate earns no FreshToken from a form token...
    _status, headers, = call("POST", "/contract/write", body: { "formToken" => form_token })
    expect(fresh_token_header(headers)).to be_nil
    # ...and refresh preserves purpose: a refreshed form token is still a form
    # token (CSRF rotation), so it is still refused as an identity.
    rotated = Tina4::Auth.refresh_token(form_token)
    expect(Tina4::Auth.valid_token(rotated)["type"]).to eq("form")
    status, = call("POST", "/contract/write", headers: { "Authorization" => "Bearer #{rotated}" })
    expect(status).to eq(401)
    refreshed = Tina4::Auth.refresh_token(Tina4::Auth.get_token({ "user_id" => 5 }))
    expect(Tina4::Auth.valid_token(refreshed)["user_id"]).to eq(5)
  end

  it "an auth token still passes the route gate" do
    token = Tina4::Auth.get_token({ "user_id" => 9 })
    status, = call("POST", "/contract/write", headers: { "Authorization" => "Bearer #{token}" })
    expect(status).to eq(200)
    status, headers, = call("POST", "/contract/write", body: { "formToken" => token })
    expect(status).to eq(200)
    expect(fresh_token_header(headers)).not_to be_nil, "an auth token in the body still earns a FreshToken"
  end

  it "a form token still passes csrf" do
    # CSRF skips no_auth routes, so the realistic case is a logged-in user
    # (auth token in the session) posting a rendered form.
    Tina4::Router.post("/contract/csrf") do |req, res|
      res.json({ user: req.user }, 200)
    end.middleware(Tina4::CsrfMiddleware)

    cookie = session_cookie({ "token" => Tina4::Auth.get_token({ "user_id" => 11 }) })
    status, _headers, body = call("POST", "/contract/csrf", body: { "formToken" => form_token }, cookie: cookie)
    expect(status).to eq(200), body
    expect(user_of(body)["user_id"]).to eq(11)
    status, = call("POST", "/contract/csrf", body: { "x" => 1 }, cookie: cookie)
    expect(status).to eq(403)
    # A form token in the Bearer slot is not an API-client identity, so it does
    # not skip the CSRF check either.
    status, = call("POST", "/contract/csrf", body: { "x" => 1 }, cookie: cookie,
                                             headers: { "Authorization" => "Bearer #{form_token}" })
    expect(status).to eq(403)
  end

  # ── auth-secret-strength ─────────────────────────────────────────────

  it "signing with a blank secret is refused" do
    ENV.delete("TINA4_SECRET")
    expect { Tina4::Auth.get_token({ "user_id" => 1 }) }
      .to raise_error(Tina4::Auth::InsecureSecretError, /TINA4_SECRET.*openssl rand -hex 32/)
    expect { Tina4::Auth.get_token({ "user_id" => 1 }, secret: "") }
      .to raise_error(Tina4::Auth::InsecureSecretError, /TINA4_SECRET/)
  end

  it "signing with a secret shorter than 32 bytes is refused" do
    expect { Tina4::Auth.get_token({ "user_id" => 1 }, secret: "x" * 31) }
      .to raise_error(Tina4::Auth::InsecureSecretError, /32 bytes/)
  end

  it "a token forged with the empty key is rejected" do
    ENV.delete("TINA4_SECRET")
    forged = hs256({ "user_id" => 1, "exp" => Time.now.to_i + 600 }, "")
    expect(Tina4::Auth.valid_token(forged)).to be_nil
    expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{forged}" }, secret: "")).to be_nil
    expect(Dir.exist?(File.join(tmp_dir, ".keys"))).to be(false), "a blank secret must not mint an RSA key pair"
    status, = call("POST", "/contract/write", headers: { "Authorization" => "Bearer #{forged}" })
    expect(status).to eq(401)
  end

  it "a weak key rejection names the fix" do
    # Rejection alone is guaranteed twice over (the signer refuses too); the
    # verifier's own check is what TELLS the operator why every token fails.
    # Observed in a real child process.
    token = hs256({ "user_id" => 1 }, "short")
    lib = File.expand_path("../lib", __dir__)
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_") }
    code = "require 'tina4'; p Tina4::Auth.authenticate_request({ 'HTTP_AUTHORIZATION' => 'Bearer #{token}' }, secret: 'short')"
    output, status = Open3.capture2e(env, RbConfig.ruby, "-I", lib, "-e", code, unsetenv_others: true)
    expect(status.exitstatus).to eq(0), output
    expect(output).to include("nil").and include("at least 32 bytes").and include("openssl rand -hex 32")
  end

  it "a 32 byte secret signs and verifies" do
    key = "k" * 32
    token = Tina4::Auth.get_token({ "user_id" => 2 }, secret: key)
    expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" }, secret: key)["user_id"]).to eq(2)
  end

  def boot(env_file)
    dir = Dir.mktmpdir("tina4_boot")
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    File.write(File.join(dir, ".env"), env_file)
    lib = File.expand_path("../lib", __dir__)
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_") }.merge("TINA4_NO_BROWSER" => "true")
    code = "require 'tina4'; Tina4.initialize!(#{dir.inspect}); puts 'BOOTED'"
    output, status = Open3.capture2e(env, RbConfig.ruby, "-I", lib, "-e", code, chdir: dir, unsetenv_others: true)
    [status.exitstatus, output, dir]
  end

  it "boot outside dev refuses a blank secret" do
    exit_code, output, dir = boot("TINA4_DEBUG=false\n")
    expect(exit_code).not_to eq(0), output
    expect(output).not_to include("BOOTED")
    expect(output).to include("TINA4_SECRET").and include("openssl rand -hex 32")
    expect(Dir.exist?(File.join(dir, ".keys"))).to be(false), "boot must not mint an RSA key pair"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "boot outside dev refuses a short secret" do
    exit_code, output, dir = boot("TINA4_DEBUG=false\nTINA4_SECRET=too-short\n")
    expect(exit_code).not_to eq(0), output
    expect(output).not_to include("BOOTED")
    expect(output).to include("32 bytes")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # ── empty-peer-is-not-loopback ───────────────────────────────────────

  it "an empty peer is not loopback" do
    expect(Tina4.is_loopback?("")).to be(false)
    expect(Tina4.is_loopback?(nil)).to be(false)
  end

  it "a loopback peer is loopback" do
    ["127.0.0.1", "127.8.9.10", "::1", "::ffff:127.0.0.1", "localhost"].each do |address|
      expect(Tina4.is_loopback?(address)).to be(true), address
    end
    ["10.0.0.1", "0.0.0.0", "192.168.1.5", "::ffff:10.0.0.1"].each do |address|
      expect(Tina4.is_loopback?(address)).to be(false), address
    end
  end

  it "an empty peer is refused by the mcp gate" do
    ENV["TINA4_DEBUG"] = "true"
    ENV.delete("TINA4_MCP")
    ENV.delete("TINA4_MCP_REMOTE")
    expect(Tina4.request_allowed?("")).to be(false)
    expect(Tina4.request_allowed?("127.0.0.1")).to be(true)
  end

  # ── sso-identity-expires ─────────────────────────────────────────────

  def sso(expires_at)
    { "marker" => 1, "_tina4_sso" => { "version" => 1, "expires_at" => expires_at,
                                        "identity" => { "issuer" => "https://idp.example", "subject" => "u-1" } } }
  end

  it "an expired sso identity is refused" do
    status, = call("GET", "/contract/read", cookie: session_cookie(sso(Time.now.to_i - 5)))
    expect(status).to eq(401)
  end

  it "a live sso identity passes" do
    status, _headers, body = call("GET", "/contract/read", cookie: session_cookie(sso(Time.now.to_i + 300)))
    expect(status).to eq(200)
    expect(user_of(body)["subject"]).to eq("u-1")
    status, = call("GET", "/contract/read", cookie: session_cookie(sso(0)))
    expect(status).to eq(200)
  end

  # ── form-token-lifetime ──────────────────────────────────────────────

  it "a form token lives token limit minutes" do
    ENV["TINA4_TOKEN_LIMIT"] = "5"
    payload = Tina4::Auth.valid_token(form_token)
    expect(payload["exp"] - payload["iat"]).to eq(5 * 60)
  end

  # ── debug-is-explicit ────────────────────────────────────────────────

  it "a missing env file does not enable debug" do
    dir = Dir.mktmpdir("tina4_env")
    ENV.delete("TINA4_DEBUG")
    ENV.delete("TINA4_API_KEY")
    Tina4::Env.load_env(dir)
    written = File.exist?(File.join(dir, ".env")) ? File.read(File.join(dir, ".env")) : ""
    expect(written).not_to include("TINA4_DEBUG")
    expect(written).not_to include("TINA4_API_KEY")
    expect(ENV["TINA4_DEBUG"]).to be_nil
    expect(ENV["TINA4_API_KEY"]).to be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
