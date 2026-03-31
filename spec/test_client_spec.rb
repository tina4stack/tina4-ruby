require_relative "spec_helper"

RSpec.describe Tina4::TestClient do
  before(:each) do
    # Register test routes (re-registered each test since spec_helper clears routes)
    Tina4::Router.get("/api/test/hello") do |request, response|
      response.json({ message: "hello" })
    end

    Tina4::Router.post("/api/test/echo") do |request, response|
      response.json(request.json_body || {}, 201)
    end

    Tina4::Router.get("/api/test/users/{id:int}") do |id, request, response|
      response.json({ id: id, name: "User #{id}" })
    end

    Tina4::Router.put("/api/test/items/{id:int}") do |id, request, response|
      data = request.json_body || {}
      response.json({ id: id, updated: true, name: data["name"] })
    end

    Tina4::Router.delete("/api/test/items/{id:int}") do |id, request, response|
      response.json({ id: id, deleted: true })
    end

    Tina4::Router.get("/api/test/query") do |request, response|
      response.json({ search: request.params["q"], page: request.params["page"] })
    end

    Tina4::Router.get("/api/test/headers") do |request, response|
      response.json({ auth: request.header("authorization"), custom: request.header("x-custom") })
    end
  end

  let(:client) { Tina4::TestClient.new }

  describe "#get" do
    it "returns 200 for a matched route" do
      r = client.get("/api/test/hello")
      expect(r.status).to eq(200)
      expect(r.json["message"]).to eq("hello")
    end

    it "returns 404 for unmatched routes" do
      r = client.get("/api/test/nonexistent")
      expect(r.status).to eq(404)
    end

    it "extracts path parameters" do
      r = client.get("/api/test/users/42")
      expect(r.status).to eq(200)
      expect(r.json["id"]).to eq(42)
      expect(r.json["name"]).to eq("User 42")
    end

    it "passes query string parameters" do
      r = client.get("/api/test/query?q=hello&page=2")
      expect(r.status).to eq(200)
      expect(r.json["search"]).to eq("hello")
      expect(r.json["page"]).to eq("2")
    end

    it "passes custom headers" do
      r = client.get("/api/test/headers", headers: { "Authorization" => "Bearer abc123", "X-Custom" => "test" })
      expect(r.status).to eq(200)
      expect(r.json["auth"]).to eq("Bearer abc123")
      expect(r.json["custom"]).to eq("test")
    end
  end

  describe "#post" do
    it "sends JSON body" do
      r = client.post("/api/test/echo", json: { name: "Alice", age: 30 })
      expect(r.status).to eq(201)
      expect(r.json["name"]).to eq("Alice")
      expect(r.json["age"]).to eq(30)
    end
  end

  describe "#put" do
    it "sends JSON body with path params" do
      r = client.put("/api/test/items/5", json: { name: "Updated Widget" })
      expect(r.status).to eq(200)
      expect(r.json["id"]).to eq(5)
      expect(r.json["updated"]).to eq(true)
      expect(r.json["name"]).to eq("Updated Widget")
    end
  end

  describe "#delete" do
    it "sends DELETE request with path params" do
      r = client.delete("/api/test/items/7")
      expect(r.status).to eq(200)
      expect(r.json["id"]).to eq(7)
      expect(r.json["deleted"]).to eq(true)
    end
  end

  describe Tina4::TestResponse do
    it "provides text() method" do
      r = client.get("/api/test/hello")
      expect(r.text).to include("hello")
    end

    it "provides content_type" do
      r = client.get("/api/test/hello")
      expect(r.content_type).to include("application/json")
    end

    it "returns nil json for non-JSON content" do
      r = client.get("/api/test/nonexistent")
      # 404 still returns JSON error
      expect(r.json["error"]).to eq("Not found")
    end
  end
end
