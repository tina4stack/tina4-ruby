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
  it "allows the route when the role claim is present" do
    expect(get("/rbac/role_admin", { "sub" => "u", "roles" => ["admin"] }).status).to eq(200)
  end

  # ── rbac-role-denies-403 ───────────────────────────────────────
  it "forbids (403) when the role is missing" do
    expect(get("/rbac/role_admin", { "sub" => "u", "roles" => ["viewer"] }).status).to eq(403)
  end

  # ── rbac-unauthenticated-401 ───────────────────────────────────
  it "is 401 (not 403) when unauthenticated — a guard implies auth" do
    expect(get("/rbac/role_admin").status).to eq(401)
  end

  # ── rbac-role-or-and ───────────────────────────────────────────
  it "treats a role list as any-of" do
    expect(get("/rbac/role_any", { "sub" => "u", "roles" => ["editor"] }).status).to eq(200)
    expect(get("/rbac/role_any", { "sub" => "u", "roles" => ["admin"] }).status).to eq(200)
    expect(get("/rbac/role_any", { "sub" => "u", "roles" => ["viewer"] }).status).to eq(403)
  end

  it "treats stacked guards as all-of" do
    expect(get("/rbac/role_stacked", { "sub" => "u", "roles" => %w[admin editor] }).status).to eq(200)
    expect(get("/rbac/role_stacked", { "sub" => "u", "roles" => ["admin"] }).status).to eq(403)
  end

  # ── rbac-can-permission ────────────────────────────────────────
  it "grants the route on the permission" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["posts.delete"] }).status).to eq(200)
  end

  it "forbids (403) when the permission is missing" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["posts.read"] }).status).to eq(403)
  end

  it "does not let a role satisfy a permission guard" do
    expect(get("/rbac/can_delete", { "sub" => "u", "roles" => ["admin"] }).status).to eq(403)
  end

  # ── rbac-wildcard-grant ────────────────────────────────────────
  it "grants within scope via a wildcard permission" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["posts.*"] }).status).to eq(200)
  end

  it "grants everything via the superuser star" do
    expect(get("/rbac/can_delete", { "sub" => "u", "permissions" => ["*"] }).status).to eq(200)
  end

  it "does not let a wildcard cross scope" do
    expect(get("/rbac/can_users", { "sub" => "u", "permissions" => ["posts.*"] }).status).to eq(403)
  end

  # ── rbac-verified-payload-only ─────────────────────────────────
  it "ignores a spoofed role header" do
    # A viewer token with a spoofed X-Role: admin header is still forbidden.
    expect(get("/rbac/role_admin", { "sub" => "u", "roles" => ["viewer"] }, { "X-Role" => "admin" }).status).to eq(403)
  end

  # ── rbac-legacy-singular-role ──────────────────────────────────
  it "coerces a legacy singular role claim" do
    expect(get("/rbac/role_admin", { "sub" => "u", "role" => "admin" }).status).to eq(200)
  end
end
