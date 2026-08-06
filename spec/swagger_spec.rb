# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Swagger do
  before(:each) { Tina4::Router.clear! }

  describe ".generate" do
    it "returns a valid OpenAPI 3.0.3 spec" do
      spec = Tina4::Swagger.generate
      expect(spec["openapi"]).to eq("3.0.3")
      expect(spec["info"]).to be_a(Hash)
      expect(spec["paths"]).to be_a(Hash)
    end

    it "includes registered routes" do
      Tina4.get("/api/test") { |_req, res| res.json({ ok: true }) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"]).to have_key("/api/test")
      expect(spec["paths"]["/api/test"]).to have_key("get")
    end

    it "includes path parameters" do
      Tina4.get("/api/users/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"]).to have_key("/api/users/{id}")
      params = spec["paths"]["/api/users/{id}"]["get"]["parameters"]
      expect(params.any? { |p| p["name"] == "id" }).to be true
    end

    it "computes bearerAuth security for a secure GET route" do
      Tina4.secure_get("/api/secret") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/secret"]["get"]
      # secure_get sets route.auth_handler, so resolve_security applies the
      # default scheme (bearerAuth). bearerAuth is type "http", so scopes are
      # sanitized to [] (scopes only allowed on oauth2/openIdConnect).
      expect(operation["security"]).to eq([{ "bearerAuth" => [] }])
    end

    it "includes request body for POST routes" do
      Tina4.post("/api/items") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/items"]["post"]
      expect(operation["requestBody"]).not_to be_nil
    end

    it "includes bearer auth component" do
      spec = Tina4::Swagger.generate
      schemes = spec.dig("components", "securitySchemes", "bearerAuth")
      expect(schemes["type"]).to eq("http")
      expect(schemes["scheme"]).to eq("bearer")
    end

    it "includes bearerFormat JWT" do
      spec = Tina4::Swagger.generate
      schemes = spec.dig("components", "securitySchemes", "bearerAuth")
      expect(schemes["bearerFormat"]).to eq("JWT")
    end

    it "falls back to the 'Tina4 API' default info title" do
      # base_spec falls back to "Tina4 API" only when neither TINA4_SWAGGER_TITLE
      # nor PROJECT_NAME is set. Scrub both for this example so we assert the
      # real computed default rather than whatever the ambient env contributes.
      original_title = ENV.delete("TINA4_SWAGGER_TITLE")
      original_project = ENV.delete("PROJECT_NAME")
      begin
        spec = Tina4::Swagger.generate
        expect(spec["info"]["title"]).to eq("Tina4 API")
      ensure
        ENV["TINA4_SWAGGER_TITLE"] = original_title if original_title
        ENV["PROJECT_NAME"] = original_project if original_project
      end
    end

    it "defaults info.version to the app version 1.0.0, not the framework version" do
      # S3 (3.13.96): info.version is the APPLICATION's API version. Defaulting
      # to Tina4::VERSION made an undocumented app claim API v3.13.x; the settled
      # default is "1.0.0". TINA4_SWAGGER_VERSION still overrides.
      original_version = ENV.delete("TINA4_SWAGGER_VERSION")
      begin
        spec = Tina4::Swagger.generate
        expect(spec["info"]["version"]).to eq("1.0.0")
        expect(spec["info"]["version"]).not_to eq(Tina4::VERSION)
      ensure
        ENV["TINA4_SWAGGER_VERSION"] = original_version if original_version
      end
    end

    it "defaults info.description to the empty string" do
      # S3 (3.13.96): a canned "Auto-generated..." blurb is doc noise; the
      # settled default is empty. Set TINA4_SWAGGER_DESCRIPTION to fill it.
      original = ENV.delete("TINA4_SWAGGER_DESCRIPTION")
      begin
        spec = Tina4::Swagger.generate
        expect(spec["info"]["description"]).to eq("")
      ensure
        ENV["TINA4_SWAGGER_DESCRIPTION"] = original if original
      end
    end

    it "has servers array with root url" do
      spec = Tina4::Swagger.generate
      expect(spec["servers"]).to be_a(Array)
      expect(spec["servers"].first["url"]).to eq("/")
    end

    it "returns empty paths when no routes registered" do
      spec = Tina4::Swagger.generate
      expect(spec["paths"]).to be_empty
    end

    it "includes request body for PUT routes" do
      Tina4.put("/api/items/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/items/{id}"]["put"]
      expect(operation["requestBody"]).not_to be_nil
    end

    it "includes request body for PATCH routes" do
      Tina4.patch("/api/items/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/items/{id}"]["patch"]
      expect(operation["requestBody"]).not_to be_nil
    end

    it "does not include request body for GET routes" do
      Tina4.get("/api/items") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/items"]["get"]
      expect(operation["requestBody"]).to be_nil
    end

    it "does not include request body for DELETE routes" do
      Tina4.delete("/api/items/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/items/{id}"]["delete"]
      expect(operation["requestBody"]).to be_nil
    end

    it "includes multiple routes" do
      Tina4.get("/api/users") { |_req, res| res.json({}) }
      Tina4.post("/api/users") { |_req, res| res.json({}) }
      Tina4.get("/api/items") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"].keys.length).to eq(2)
      expect(spec["paths"]["/api/users"]).to have_key("get")
      expect(spec["paths"]["/api/users"]).to have_key("post")
      expect(spec["paths"]["/api/items"]).to have_key("get")
    end

    it "emits only 200 on an undecorated public GET (S5)" do
      # S5 (3.13.96): an undecorated route emits ONLY 200. The framework does
      # not produce 400/404/500 for a public GET, and 401 appears only on a
      # secured route (see swagger_parity_31396_spec.rb) — so a public GET
      # advertising 401/404/500 was fiction. This corrects that pinned bug.
      Tina4.get("/api/test") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      responses = spec["paths"]["/api/test"]["get"]["responses"]
      expect(responses.keys).to eq(["200"])
    end

    it "generates summary from method and path" do
      Tina4.get("/api/users") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      summary = spec["paths"]["/api/users"]["get"]["summary"]
      expect(summary).to include("GET")
      expect(summary).to include("/api/users")
    end

    it "extracts tags from path" do
      Tina4.get("/users/list") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      tags = spec["paths"]["/users/list"]["get"]["tags"]
      expect(tags).to include("users")
    end

    it "uses 'default' tag for root path" do
      Tina4.get("/") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      tags = spec["paths"]["/"]["get"]["tags"]
      expect(tags).to include("default")
    end

    it "converts path params with type hints to plain params" do
      Tina4.get("/api/users/{id:int}/posts/{slug:path}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"]).to have_key("/api/users/{id}/posts/{slug}")
    end

    it "maps integer param type to integer schema" do
      Tina4.get("/api/users/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/users/{id}"]["get"]["parameters"]
      id_param = params.find { |p| p["name"] == "id" }
      expect(id_param["schema"]["type"]).to eq("integer")
    end

    it "maps float param type to number schema" do
      Tina4.get("/api/items/{price:float}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/items/{price}"]["get"]["parameters"]
      price_param = params.find { |p| p["name"] == "price" }
      expect(price_param["schema"]["type"]).to eq("number")
    end

    it "maps unknown param type to string schema" do
      Tina4.get("/api/items/{slug}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/items/{slug}"]["get"]["parameters"]
      slug_param = params.find { |p| p["name"] == "slug" }
      expect(slug_param["schema"]["type"]).to eq("string")
    end

    it "marks path parameters as required" do
      Tina4.get("/api/users/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/users/{id}"]["get"]["parameters"]
      id_param = params.find { |p| p["name"] == "id" }
      expect(id_param["required"]).to be true
    end

    it "sets parameter 'in' to 'path'" do
      Tina4.get("/api/users/{id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/users/{id}"]["get"]["parameters"]
      id_param = params.find { |p| p["name"] == "id" }
      expect(id_param["in"]).to eq("path")
    end

    it "includes security with bearerAuth for secure routes" do
      Tina4.secure_post("/api/admin") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/admin"]["post"]
      expect(operation["security"]).to eq([{ "bearerAuth" => [] }])
    end

    it "does not include security for non-secure routes" do
      Tina4.get("/api/public") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/public"]["get"]
      expect(operation["security"]).to be_nil
    end

    it "default request body uses application/json" do
      Tina4.post("/api/data") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      body = spec["paths"]["/api/data"]["post"]["requestBody"]
      expect(body["content"]).to have_key("application/json")
    end

    it "default request body schema is object" do
      Tina4.post("/api/data") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      schema = spec["paths"]["/api/data"]["post"]["requestBody"]["content"]["application/json"]["schema"]
      expect(schema["type"]).to eq("object")
    end

    it "includes swagger_meta summary when provided" do
      Tina4.get("/api/health", swagger_meta: { summary: "Health check" }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      summary = spec["paths"]["/api/health"]["get"]["summary"]
      expect(summary).to eq("Health check")
    end

    it "includes swagger_meta description when provided" do
      Tina4.get("/api/health", swagger_meta: { description: "Returns service health" }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      desc = spec["paths"]["/api/health"]["get"]["description"]
      expect(desc).to eq("Returns service health")
    end

    it "includes swagger_meta tags when provided" do
      Tina4.get("/api/health", swagger_meta: { tags: ["monitoring"] }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      tags = spec["paths"]["/api/health"]["get"]["tags"]
      expect(tags).to eq(["monitoring"])
    end

    it "includes swagger_meta custom responses" do
      custom_responses = { "200" => { "description" => "OK" }, "503" => { "description" => "Service unavailable" } }
      Tina4.get("/api/health", swagger_meta: { responses: custom_responses }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      responses = spec["paths"]["/api/health"]["get"]["responses"]
      expect(responses).to have_key("503")
      expect(responses["503"]["description"]).to eq("Service unavailable")
    end

    it "includes swagger_meta custom request body" do
      custom_body = {
        "content" => {
          "multipart/form-data" => {
            "schema" => { "type" => "object" }
          }
        }
      }
      Tina4.post("/api/upload", swagger_meta: { request_body: custom_body }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      body = spec["paths"]["/api/upload"]["post"]["requestBody"]
      expect(body["content"]).to have_key("multipart/form-data")
    end

    it "handles routes with no path parameters" do
      Tina4.get("/api/items") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/items"]["get"]["parameters"]
      expect(params).to be_empty
    end

    it "handles routes with multiple path parameters" do
      Tina4.get("/api/users/{user_id:int}/posts/{post_id:int}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      params = spec["paths"]["/api/users/{user_id}/posts/{post_id}"]["get"]["parameters"]
      expect(params.length).to eq(2)
      names = params.map { |p| p["name"] }
      expect(names).to include("user_id")
      expect(names).to include("post_id")
    end

    # Parity with the Python decorator-stacking regression (issue #59):
    # combining multiple fields in one swagger_meta must preserve all of them.
    it "preserves all swagger_meta fields when combined (parity issue #59)" do
      Tina4.post("/api/regr", swagger_meta: {
        summary: "Create a user",
        description: "Creates a user account",
        tags: ["Users"],
        example: { "email" => "a@b.c" }
      }) { |_req, res| res.json({}) }
      op = Tina4::Swagger.generate["paths"]["/api/regr"]["post"]
      expect(op["summary"]).to eq("Create a user")
      expect(op["description"]).to include("Creates a user account")
      expect(op["tags"]).to eq(["Users"])
      expect(op).to have_key("requestBody")
    end
  end
end
