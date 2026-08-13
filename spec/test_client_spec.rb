require_relative "spec_helper"

RSpec.describe Tina4::TestClient do
  before(:each) do
    # Register test routes (re-registered each test since spec_helper clears routes).
    # The write routes below are marked .no_auth on purpose: this spec exercises the
    # TestClient PLUMBING (JSON body, path params, query, headers), not auth. Since
    # the TestClient now routes through the real secure-by-default gate (#PY2 parity),
    # an auth-required write with no token would 401 before the handler runs — which
    # is exactly the contract locked in by test_client_auth_spec.rb.
    Tina4::Router.get("/api/test/hello") do |request, response|
      response.json({ message: "hello" })
    end

    Tina4::Router.post("/api/test/echo") do |request, response|
      response.json(request.json_body || {}, 201)
    end.no_auth

    Tina4::Router.get("/api/test/users/{id:int}") do |id, request, response|
      response.json({ id: id, name: "User #{id}" })
    end

    Tina4::Router.put("/api/test/items/{id:int}") do |id, request, response|
      data = request.json_body || {}
      response.json({ id: id, updated: true, name: data["name"] })
    end.no_auth

    Tina4::Router.delete("/api/test/items/{id:int}") do |id, request, response|
      response.json({ id: id, deleted: true })
    end.no_auth

    Tina4::Router.get("/api/test/query") do |request, response|
      # Query-string values live in `query`, not the route-only `params`
      # (REQ-PARAM-POLLUTION, 3.13.99) -- this route has no {} segments.
      response.json({ search: request.query["q"], page: request.query["page"] })
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
      # An unmatched path now returns the framework's REAL 404 — the rendered
      # HTML error page the live server sends — because TestClient dispatches
      # through Tina4::RackApp instead of hand-building a response of its own
      # (feature-recount D6). This assertion used to read
      #   expect(r.json["error"]).to eq("Not found")
      # which only ever passed because the old TestClient short-circuited on a
      # Router.match miss and fabricated {"error":"Not found"} — a body the
      # server never sends. It asserted the test client's own fiction.
      r = client.get("/api/test/nonexistent")
      expect(r.status).to eq(404)
      expect(r.content_type).to include("text/html")
      expect(r.json).to be_nil
      expect(r.text).to include("404")
    end
  end
end
