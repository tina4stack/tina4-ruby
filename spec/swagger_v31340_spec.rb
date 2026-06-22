# frozen_string_literal: true

require "spec_helper"

# Test ORM models for the components.schemas / $ref mirror specs.
class SwaggerWidget < Tina4::ORM
  table_name "swagger_widgets"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  integer_field :category_id
end

# v3.13.40 Swagger sweep — Ruby mirror contract specs.
RSpec.describe "Tina4::Swagger v3.13.40 sweep" do
  before(:each) { Tina4::Router.clear! }

  around(:each) do |example|
    saved = ENV.to_hash.slice("TINA4_SWAGGER_SERVERS", "TINA4_SWAGGER_ENABLED", "TINA4_DEBUG")
    %w[TINA4_SWAGGER_SERVERS TINA4_SWAGGER_ENABLED TINA4_DEBUG].each { |k| ENV.delete(k) }
    example.run
    %w[TINA4_SWAGGER_SERVERS TINA4_SWAGGER_ENABLED TINA4_DEBUG].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  describe "operationId" do
    it "emits an operationId on every operation" do
      Tina4.get("/api/things") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"]["/api/things"]["get"]["operationId"]).not_to be_nil
    end

    it "de-duplicates colliding operationIds" do
      Tina4.get("/users/{id}") { |_req, res| res.json({}) }
      Tina4.get("/users/id") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      ids = [
        spec["paths"]["/users/{id}"]["get"]["operationId"],
        spec["paths"]["/users/id"]["get"]["operationId"]
      ]
      expect(ids.uniq.length).to eq(2)
    end
  end

  describe "spec-valid splat paths" do
    it "converts a splat param to valid {name} templating with a matching parameter" do
      Tina4.get("/files/*path") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"].keys).to include("/files/{path}")
      expect(spec["paths"].keys.join).not_to include("*")
      param = spec["paths"]["/files/{path}"]["get"]["parameters"].first
      expect(param["name"]).to eq("path")
      expect(param["in"]).to eq("path")
    end
  end

  describe "typed path params" do
    it "maps uuid params to a uuid format" do
      Tina4.get("/items/{id:uuid}") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      schema = spec["paths"]["/items/{id}"]["get"]["parameters"].first["schema"]
      expect(schema).to eq({ "type" => "string", "format" => "uuid" })
    end
  end

  describe "ORM model -> components.schemas + $ref" do
    it "builds a component schema and $refs the request body" do
      Tina4.post("/api/swagger_widgets", swagger_meta: { model: SwaggerWidget }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["components"]["schemas"]).to have_key("SwaggerWidget")
      props = spec["components"]["schemas"]["SwaggerWidget"]["properties"]
      expect(props["id"]["type"]).to eq("integer")
      expect(props["id"]["readOnly"]).to be true
      expect(props["name"]["type"]).to eq("string")
      expect(props["category_id"]["type"]).to eq("integer")
      body = spec["paths"]["/api/swagger_widgets"]["post"]["requestBody"]["content"]["application/json"]["schema"]
      expect(body).to eq({ "$ref" => "#/components/schemas/SwaggerWidget" })
    end

    it "emits an array-of-$ref response for a list route" do
      Tina4.get("/api/swagger_widgets", swagger_meta: { model: SwaggerWidget, model_list: true }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      schema = spec["paths"]["/api/swagger_widgets"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
      expect(schema).to eq({ "type" => "array", "items" => { "$ref" => "#/components/schemas/SwaggerWidget" } })
    end
  end

  describe "examples + deprecated + tags" do
    it "emits a request body example from swagger_meta[:example]" do
      Tina4.post("/api/items", swagger_meta: { example: { "name" => "Bolt" } }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      ex = spec["paths"]["/api/items"]["post"]["requestBody"]["content"]["application/json"]["example"]
      expect(ex).to eq({ "name" => "Bolt" })
    end

    it "preserves a multipart request_body override" do
      avatar = { "type" => "string", "format" => "binary" }
      schema = { "type" => "object", "properties" => { "avatar" => avatar } }
      mp = { "content" => { "multipart/form-data" => { "schema" => schema } } }
      Tina4.post("/api/upload", swagger_meta: { request_body: mp }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"]["/api/upload"]["post"]["requestBody"]).to eq(mp)
    end

    it "marks a route deprecated" do
      Tina4.get("/api/old", swagger_meta: { deprecated: true }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["paths"]["/api/old"]["get"]["deprecated"]).to be true
    end

    it "emits a top-level tags[] array" do
      Tina4.get("/api/widgets", swagger_meta: { tags: ["widgets"] }) { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      expect(spec["tags"].map { |t| t["name"] }).to include("widgets")
    end
  end

  describe "servers" do
    it "emits a multi-server list from TINA4_SWAGGER_SERVERS" do
      ENV["TINA4_SWAGGER_SERVERS"] = "https://a.test, https://b.test"
      spec = Tina4::Swagger.generate
      expect(spec["servers"].map { |s| s["url"] }).to eq(["https://a.test", "https://b.test"])
    end

    it "defaults to a single relative server" do
      spec = Tina4::Swagger.generate
      expect(spec["servers"]).to eq([{ "url" => "/" }])
    end
  end

  describe ".enabled?" do
    it "is off by default and honours TINA4_DEBUG / explicit override" do
      expect(Tina4::Swagger.enabled?).to be false
      ENV["TINA4_DEBUG"] = "true"
      expect(Tina4::Swagger.enabled?).to be true
      ENV["TINA4_SWAGGER_ENABLED"] = "false"
      expect(Tina4::Swagger.enabled?).to be false
    end
  end
end
