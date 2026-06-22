# frozen_string_literal: true

require "spec_helper"

# v3.13.42 — Swagger configurability contract specs (Ruby mirror of the Python
# master tests/test_swagger_v3_13_42.py). Locks the four gaps:
#   1. Configurable security schemes (bearerFormat, apiKey) + per-route security + scopes
#   2. Path include/exclude filtering (framework internals always excluded)
#   3. OpenAPI 3.1 opt-in (default 3.0.3)
#   4. Reusable custom component schemas via add_schema + request/response schema refs
RSpec.describe "Tina4::Swagger v3.13.42 configurability" do
  CONFIG_ENV_KEYS = %w[
    TINA4_SWAGGER_OPENAPI TINA4_SWAGGER_BEARER_FORMAT
    TINA4_SWAGGER_API_KEY_NAME TINA4_SWAGGER_API_KEY_IN
    TINA4_SWAGGER_DEFAULT_SCHEME TINA4_SWAGGER_INCLUDE TINA4_SWAGGER_EXCLUDE
    TINA4_SWAGGER_SERVERS TINA4_SWAGGER_ENABLED TINA4_DEBUG
  ].freeze

  before(:each) do
    Tina4::Router.clear!
    Tina4::Swagger.reset_registry
  end

  after(:each) { Tina4::Swagger.reset_registry }

  around(:each) do |example|
    saved = ENV.to_hash.slice(*CONFIG_ENV_KEYS)
    CONFIG_ENV_KEYS.each { |k| ENV.delete(k) }
    example.run
    CONFIG_ENV_KEYS.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # A bare route definition (mirrors the Python helper _route). Uses a real
  # registered route so route.path / route.auth_handler / route.swagger_meta
  # are populated by the Router.
  def add_route(method, path, swagger_meta: {}, secure: false)
    if secure
      Tina4::Router.send(:add, method.to_s.upcase, path, ->(_req, res) { res },
                         auth_handler: ->(_req) { true }, swagger_meta: swagger_meta)
    else
      Tina4::Router.send(:add, method.to_s.upcase, path, ->(_req, res) { res },
                         swagger_meta: swagger_meta)
    end
  end

  # ── OpenAPI version ──────────────────────────────────────────────

  describe "OpenAPI version" do
    it "defaults to 3.0.3" do
      expect(Tina4::Swagger.generate([])["openapi"]).to eq("3.0.3")
    end

    it "opts in to 3.1.0 via TINA4_SWAGGER_OPENAPI=3.1" do
      ENV["TINA4_SWAGGER_OPENAPI"] = "3.1"
      expect(Tina4::Swagger.generate([])["openapi"]).to eq("3.1.0")
    end
  end

  # ── Configurable security schemes ────────────────────────────────

  describe "configurable security schemes" do
    it "makes the bearer format configurable" do
      ENV["TINA4_SWAGGER_BEARER_FORMAT"] = "opaque"
      spec = Tina4::Swagger.generate([])
      expect(spec["components"]["securitySchemes"]["bearerAuth"]["bearerFormat"]).to eq("opaque")
    end

    it "emits an apiKey scheme from env" do
      ENV["TINA4_SWAGGER_API_KEY_NAME"] = "X-Api-Key"
      schemes = Tina4::Swagger.generate([])["components"]["securitySchemes"]
      expect(schemes["apiKeyAuth"]).to eq({ "type" => "apiKey", "name" => "X-Api-Key", "in" => "header" })
    end

    it "drives secured routes with the configured default scheme" do
      ENV["TINA4_SWAGGER_API_KEY_NAME"] = "X-Api-Key"
      ENV["TINA4_SWAGGER_DEFAULT_SCHEME"] = "apiKeyAuth"
      add_route(:post, "/api/v1/things", secure: true)
      spec = Tina4::Swagger.generate
      op = spec["paths"]["/api/v1/things"]["post"]
      expect(op["security"]).to eq([{ "apiKeyAuth" => [] }])
    end

    it "merges a registered scheme into securitySchemes" do
      Tina4::Swagger.add_security_scheme("oauth2", {
        "type" => "oauth2",
        "flows" => { "clientCredentials" => { "tokenUrl" => "https://x/token",
                                              "scopes" => { "read:users" => "Read" } } }
      })
      schemes = Tina4::Swagger.generate([])["components"]["securitySchemes"]
      expect(schemes["oauth2"]["type"]).to eq("oauth2")
    end
  end

  # ── Per-route security + scopes ──────────────────────────────────

  describe "per-route security" do
    it "lets an explicit security declaration override the default" do
      add_route(:get, "/api/v1/me", swagger_meta: { security: "bearerAuth" })
      spec = Tina4::Swagger.generate
      expect(spec["paths"]["/api/v1/me"]["get"]["security"]).to eq([{ "bearerAuth" => [] }])
    end

    it "marks a 'public' route with no security even when secured" do
      add_route(:post, "/api/v1/webhook", swagger_meta: { security: "public" }, secure: true)
      spec = Tina4::Swagger.generate
      expect(spec["paths"]["/api/v1/webhook"]["post"]["security"]).to eq([])
    end

    it "preserves oauth2 scopes" do
      Tina4::Swagger.add_security_scheme("oauth2", {
        "type" => "oauth2",
        "flows" => { "clientCredentials" => { "tokenUrl" => "https://x/token",
                                              "scopes" => { "read:users" => "Read", "write:users" => "Write" } } }
      })
      add_route(:get, "/api/v1/users",
                swagger_meta: { security: "oauth2", scopes: ["read:users", "write:users"] })
      op = Tina4::Swagger.generate["paths"]["/api/v1/users"]["get"]
      expect(op["security"]).to eq([{ "oauth2" => ["read:users", "write:users"] }])
    end

    it "drops scopes on a non-oauth2 scheme" do
      add_route(:get, "/api/v1/users", swagger_meta: { security: "bearerAuth", scopes: ["read:users"] })
      op = Tina4::Swagger.generate["paths"]["/api/v1/users"]["get"]
      expect(op["security"]).to eq([{ "bearerAuth" => [] }])
    end

    it "supports OR requirements (a list of maps)" do
      Tina4::Swagger.add_security_scheme("oauth2", { "type" => "oauth2", "flows" => {} })
      add_route(:get, "/api/v1/x",
                swagger_meta: { security: [{ "oauth2" => ["read"] }, { "bearerAuth" => [] }] })
      op = Tina4::Swagger.generate["paths"]["/api/v1/x"]["get"]
      expect(op["security"]).to eq([{ "oauth2" => ["read"] }, { "bearerAuth" => [] }])
    end
  end

  # ── Path filtering ───────────────────────────────────────────────

  describe "path filtering" do
    def register_filter_routes
      add_route(:get, "/api/v1/users")
      add_route(:get, "/dashboard")
      add_route(:get, "/__dev/api/reload")
      add_route(:get, "/swagger")
    end

    it "always excludes framework internals (/swagger, /__dev)" do
      register_filter_routes
      paths = Tina4::Swagger.generate["paths"]
      expect(paths).not_to have_key("/__dev/api/reload")
      expect(paths).not_to have_key("/swagger")
      expect(paths).to have_key("/api/v1/users")
    end

    it "honours an INCLUDE allow-list" do
      ENV["TINA4_SWAGGER_INCLUDE"] = "/api/v1"
      register_filter_routes
      paths = Tina4::Swagger.generate["paths"]
      expect(paths.keys).to eq(["/api/v1/users"])
    end

    it "honours an EXCLUDE prefix" do
      ENV["TINA4_SWAGGER_EXCLUDE"] = "/dashboard"
      register_filter_routes
      paths = Tina4::Swagger.generate["paths"]
      expect(paths).not_to have_key("/dashboard")
      expect(paths).to have_key("/api/v1/users")
    end
  end

  # ── Reusable custom schemas ──────────────────────────────────────

  describe "reusable custom schemas" do
    it "$refs a registered request schema and lands it in components.schemas" do
      Tina4::Swagger.add_schema("CreateUser", {
        "type" => "object",
        "properties" => { "email" => { "type" => "string" }, "name" => { "type" => "string" } },
        "required" => ["email"]
      })
      add_route(:post, "/api/v1/users", swagger_meta: { request_schema: "CreateUser" })
      spec = Tina4::Swagger.generate
      body = spec["paths"]["/api/v1/users"]["post"]["requestBody"]
      expect(body["content"]["application/json"]["schema"]).to eq({ "$ref" => "#/components/schemas/CreateUser" })
      expect(spec["components"]["schemas"]).to have_key("CreateUser")
    end

    it "$refs registered response schemas (single + list)" do
      Tina4::Swagger.add_schema("User", { "type" => "object", "properties" => { "id" => { "type" => "integer" } } })
      add_route(:get, "/api/v1/users", swagger_meta: {
                  response_schemas: { 200 => "User", 201 => { name: "User", list: true } }
                })
      resps = Tina4::Swagger.generate["paths"]["/api/v1/users"]["get"]["responses"]
      expect(resps["200"]["content"]["application/json"]["schema"]).to eq({ "$ref" => "#/components/schemas/User" })
      expect(resps["201"]["content"]["application/json"]["schema"]).to eq(
        { "type" => "array", "items" => { "$ref" => "#/components/schemas/User" } }
      )
    end
  end
end
