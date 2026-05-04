# frozen_string_literal: true

# Integration tests verifying that after the valid_token? → bool refactor
# the rack_app correctly:
#   - Returns 401 for POST without Bearer token
#   - Populates env["tina4.auth_payload"] with the actual payload dict (not true)
#   - Returns 401 for POST with an invalid Bearer token
#
# Run: bundle exec rspec spec/router_auth_payload_spec.rb

require "spec_helper"

RSpec.describe "Router auth payload integration" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_router_auth_payload_test") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    ENV["TINA4_SECRET"] = "test-router-auth-secret"
    # Use HMAC mode (SECRET env var) — reset RSA key state so we don't
    # accidentally pick up keys from a previous spec run.
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
  end

  after(:each) do
    Tina4::Router.clear!
    ENV.delete("TINA4_SECRET")
    FileUtils.rm_rf(tmp_dir)
  end

  # ── Helper: build a minimal Rack env ───────────────────────────

  def mock_env(method, path, headers: {}, body: "")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "SERVER_NAME"    => "localhost",
      "SERVER_PORT"    => "7147",
      "rack.input"     => StringIO.new(body)
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  # ── 1. POST without Bearer returns 401 ─────────────────────────

  it "returns 401 for POST without Bearer token" do
    Tina4::Router.post("/test/auth") { |_req, res| res.json({ ok: true }, 200) }

    status, _headers, _body = app.call(mock_env("POST", "/test/auth"))
    expect(status).to eq(401)
  end

  # ── 2. Valid Bearer attaches payload dict, not true ────────────

  it "attaches payload dict (not true) to env for valid Bearer" do
    # Register a route that returns env["tina4.auth_payload"] as JSON so we
    # can verify it is an actual hash and not the boolean true.
    Tina4::Router.post("/test/auth") do |req, res|
      payload = req.user || {}
      res.json(payload, 200)
    end

    token = Tina4::Auth.get_token({ "sub" => "test-user" })
    env   = mock_env("POST", "/test/auth",
                     headers: { "AUTHORIZATION" => "Bearer #{token}" })

    status, _headers, body_parts = app.call(env)
    expect(status).to eq(200)

    parsed = JSON.parse(body_parts.join)
    expect(parsed).to be_a(Hash),
      "Expected payload to be a Hash, got #{parsed.class} (value: #{parsed.inspect}). " \
      "Did valid_token? return bool and break payload assignment?"
    expect(parsed["sub"]).to eq("test-user"),
      "Expected payload['sub'] == 'test-user', got #{parsed['sub'].inspect}"
  end

  # ── 3. POST with invalid Bearer returns 401 ────────────────────

  it "returns 401 for POST with invalid Bearer token" do
    Tina4::Router.post("/test/auth") { |_req, res| res.json({ ok: true }, 200) }

    env    = mock_env("POST", "/test/auth",
                      headers: { "AUTHORIZATION" => "Bearer garbage.token.here" })
    status, _headers, _body = app.call(env)
    expect(status).to eq(401)
  end
end
