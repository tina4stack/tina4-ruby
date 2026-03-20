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

    it "includes security for secure routes" do
      Tina4.secure_get("/api/secret") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      operation = spec["paths"]["/api/secret"]["get"]
      expect(operation["security"]).not_to be_nil
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

    it "has a default info title" do
      spec = Tina4::Swagger.generate
      expect(spec["info"]["title"]).to be_a(String)
      expect(spec["info"]["title"]).not_to be_empty
    end

    it "has a default info version" do
      spec = Tina4::Swagger.generate
      expect(spec["info"]["version"]).to be_a(String)
      expect(spec["info"]["version"]).not_to be_empty
    end

    it "has a description in info" do
      spec = Tina4::Swagger.generate
      expect(spec["info"]["description"]).to eq("Auto-generated API documentation")
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

    it "includes default responses" do
      Tina4.get("/api/test") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      responses = spec["paths"]["/api/test"]["get"]["responses"]
      expect(responses).to have_key("200")
      expect(responses).to have_key("400")
      expect(responses).to have_key("401")
      expect(responses).to have_key("404")
      expect(responses).to have_key("500")
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
  end
end
