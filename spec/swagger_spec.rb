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
  end
end
