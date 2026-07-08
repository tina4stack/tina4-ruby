# frozen_string_literal: true

require "spec_helper"

# TestClient routes through the REAL auth gate (parity with Python #PY2).
#
# The in-process TestClient is the surface developers test routes on. Before
# this fix it matched a route and ran the handler DIRECTLY, skipping the
# secure-by-default auth gate that the live RackApp applies — so a tokenless
# write returned the handler's 201 in a test while the live server returned
# 401. A green test hid a live failure: the verification layer lied.
#
# TestClient now calls the same Tina4::RackApp.enforce_route_auth the live
# dispatch uses, so an auth-required write (POST/PUT/PATCH/DELETE by default, or
# any .secure route) with no valid token returns 401 exactly as in production;
# a valid Bearer token (or a formToken in the body) passes; a public route
# (GET, or a write marked .no_auth) is unaffected.
#
# NOT a mock: real Router registration, real JWTs via Tina4::Auth.get_token /
# valid_token signed with real RSA keys, real enforce_route_auth.
RSpec.describe "TestClient auth gate (PY2 parity)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_test_client_auth") }
  let(:client) { Tina4::TestClient.new }

  before(:each) do
    Tina4::Router.clear!
    # Fresh RSA key material so get_token / valid_token agree.
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)
    # A stray API key would authorise every write regardless of the JWT.
    @prior_api_key = ENV.delete("TINA4_API_KEY")

    # Fresh routes each test (spec_helper + clear! reset the registry).
    Tina4::Router.post("/tc-secure-write") do |request, response|
      response.json({ created: true }, 201)
    end

    Tina4::Router.post("/tc-public-write") do |request, response|
      response.json({ created: true }, 201)
    end.no_auth

    Tina4::Router.get("/tc-public-read") do |request, response|
      response.json({ ok: true })
    end

    Tina4::Router.get("/tc-secured-read") do |request, response|
      response.json({ secret: true })
    end.secure
  end

  after(:each) do
    Tina4::Router.clear!
    ENV["TINA4_API_KEY"] = @prior_api_key if @prior_api_key
    FileUtils.rm_rf(tmp_dir)
  end

  # ── The core contract: a tokenless write is rejected ─────────────
  it "rejects a tokenless write with 401" do
    r = client.post("/tc-secure-write", json: { name: "Alice" })
    expect(r.status).to eq(401)
    expect(r.json["error"]).to eq("Unauthorized")
  end

  # ── A valid Bearer token passes ──────────────────────────────────
  it "passes a write with a valid Bearer token" do
    token = Tina4::Auth.get_token({ "sub" => "user-1" })
    r = client.post("/tc-secure-write", json: { name: "Alice" }, headers: { "Authorization" => "Bearer #{token}" })
    expect(r.status).to eq(201)
    expect(r.json["created"]).to eq(true)
  end

  # ── A formToken in the body passes (frond.js posts the token there) ─
  it "passes a write with a formToken in the body" do
    token = Tina4::Auth.get_token({ "sub" => "user-1" })
    r = client.post("/tc-secure-write", json: { name: "Bob", formToken: token })
    expect(r.status).to eq(201)
  end

  # ── An invalid token is rejected ─────────────────────────────────
  it "rejects a write with an invalid token" do
    r = client.post("/tc-secure-write", json: { name: "Mallory" }, headers: { "Authorization" => "Bearer not-a-real-token" })
    expect(r.status).to eq(401)
  end

  # ── A write opened with .no_auth needs no token ──────────────────
  it "allows a .no_auth write with no token" do
    r = client.post("/tc-public-write", json: { name: "Anon" })
    expect(r.status).to eq(201)
  end

  # ── A plain GET needs no token ───────────────────────────────────
  it "allows a public GET with no token" do
    r = client.get("/tc-public-read")
    expect(r.status).to eq(200)
    expect(r.json["ok"]).to eq(true)
  end

  # ── A .secure GET without a token is rejected ────────────────────
  it "rejects a .secure GET with no token" do
    r = client.get("/tc-secured-read")
    expect(r.status).to eq(401)
  end

  # ── A .secure GET with a valid token passes ──────────────────────
  it "passes a .secure GET with a valid token" do
    token = Tina4::Auth.get_token({ "sub" => "user-1" })
    r = client.get("/tc-secured-read", headers: { "Authorization" => "Bearer #{token}" })
    expect(r.status).to eq(200)
    expect(r.json["secret"]).to eq(true)
  end
end
