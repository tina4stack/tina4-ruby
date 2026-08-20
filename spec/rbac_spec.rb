# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# RBAC role/permission guards — Feature 138 / ADR-0058.
# Contract answer key: tina4-documentation/plan/v3/fixtures/rbac_contract.json.
#
# Every case drives a REAL request through the in-process TestClient (the same
# Tina4::RackApp.enforce_route_auth the live server runs), with REAL tokens
# minted by Tina4::Auth.get_token. NO MOCKS. role/can read the VERIFIED payload
# only; a guard implies auth (no token -> 401, valid-but-unauthorised -> 403).
RSpec.describe "RBAC guards (Feature 138)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_rbac") }
  let(:client) { Tina4::TestClient.new }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)
    # A stray API key would authorise every request regardless of the JWT.
    @prior_api_key = ENV.delete("TINA4_API_KEY")

    ok = ->(_request, response) { response.json({ ok: true }) }
    # GET routes (public by default) so the guard is what makes them require auth.
    Tina4::Router.get("/rbac/role_admin", &ok).role("admin")
    Tina4::Router.get("/rbac/role_any", &ok).role("admin", "editor")
    Tina4::Router.get("/rbac/role_stacked", &ok).role("admin").role("editor")
    Tina4::Router.get("/rbac/can_delete", &ok).can("posts.delete")
    Tina4::Router.get("/rbac/can_users", &ok).can("users.delete")
  end

  after(:each) do
    Tina4::Router.clear!
    ENV["TINA4_API_KEY"] = @prior_api_key if @prior_api_key
    FileUtils.rm_rf(tmp_dir)
  end

  def get(path, payload = nil, extra_headers = {})
    headers = extra_headers.dup
    headers["Authorization"] = "Bearer #{Tina4::Auth.get_token(payload)}" unless payload.nil?
    client.get(path, headers: headers)
  end

  # ── rbac-role-allows ───────────────────────────────────────────
  it "role claim allows the route" do
    expect(get("/rbac/role_admin", { "sub" => "u", "roles" => ["admin"] }).status).to eq(200)
  end

  # ── rbac-role-denies-403 ───────────────────────────────────────
  it "missing role is forbidden 403" do
    expect(get("/rbac/role_admin", { "sub" => "u", "roles" => ["viewer"] }).status).to eq(403)
  end

  # ── rbac-unauthenticated-401 ───────────────────────────────────
  it "unauthenticated guard is 401" do
    expect(get("/rbac/role_admin").status).to eq(401)
  end

  # ── rbac-role-or-and ───────────────────────────────────────────
  it "role list is any of" do
    expect(get("/rbac/role_any", { "sub" => "u", "roles" => ["editor"] }).status).to eq(200)
    expect(get("/rbac/role_any", { "sub" => "u", "roles" => ["admin"] }).status).to eq(200)
    expect(get("/rbac/role_any", { "sub" => "u", "roles" => ["viewer"] }).status).to eq(403)
  end

  it "stacked guards are all of" do
    expect(get("/rbac/role_stacked", { "sub" => "u", "roles" => %w[admin editor] }).status).to eq(200)
    expect(get("/rbac/role_stacked", { "sub" => "u", "roles" => ["admin"] }).status).to eq(403)
  end

  # ── rbac-can-permission ────────────────────────────────────────
  it "permission grants the route" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["posts.delete"] }).status).to eq(200)
  end

  it "missing permission is forbidden 403" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["posts.read"] }).status).to eq(403)
  end

  it "role alone does not satisfy a permission guard" do
    expect(get("/rbac/can_delete", { "sub" => "u", "roles" => ["admin"] }).status).to eq(403)
  end

  # ── rbac-wildcard-grant ────────────────────────────────────────
  it "wildcard permission grants within scope" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["posts.*"] }).status).to eq(200)
  end

  it "superuser star grants everything" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["*"] }).status).to eq(200)
  end

  it "wildcard does not cross scope" do
    expect(get("/rbac/can_users", { "sub" => "u", "permissions" => ["posts.*"] }).status).to eq(403)
  end

  # ── rbac-verified-payload-only ─────────────────────────────────
  it "spoofed role header is ignored" do
    # A viewer token with a spoofed X-Role: admin header is still forbidden.
    expect(get("/rbac/role_admin", { "sub" => "u", "roles" => ["viewer"] }, { "X-Role" => "admin" }).status).to eq(403)
  end

  # ── rbac-legacy-singular-role ──────────────────────────────────
  it "legacy singular role is coerced" do
    expect(get("/rbac/role_admin", { "sub" => "u", "role" => "admin" }).status).to eq(200)
  end
end
