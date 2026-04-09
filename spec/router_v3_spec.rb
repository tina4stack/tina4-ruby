# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Router v3 features" do
  before { Tina4::Router.clear! }

  describe "Tina4::Router convenience methods" do
    it "registers a GET route via .get" do
      Tina4::Router.get("/hello") { |req, res| res.text("hello") }
      expect(Tina4::Router.routes.length).to eq(1)
      route, _params = Tina4::Router.find_route("GET", "/hello")
      expect(route).not_to be_nil
      expect(route.method).to eq("GET")
    end

    it "registers a POST route via .post" do
      Tina4::Router.post("/data") { |req, res| res.json({ok: true}) }
      route, _params = Tina4::Router.find_route("POST", "/data")
      expect(route).not_to be_nil
      expect(route.method).to eq("POST")
    end

    it "registers a PUT route via .put" do
      Tina4::Router.put("/data/{id}") { |req, res| res.json({ok: true}) }
      route, params = Tina4::Router.find_route("PUT", "/data/5")
      expect(route).not_to be_nil
      expect(params[:id]).to eq("5")
    end

    it "registers a PATCH route via .patch" do
      Tina4::Router.patch("/data/{id}") { |req, res| res.json({ok: true}) }
      route, _params = Tina4::Router.find_route("PATCH", "/data/5")
      expect(route).not_to be_nil
    end

    it "registers a DELETE route via .delete" do
      Tina4::Router.delete("/data/{id}") { |req, res| res.json({ok: true}) }
      route, _params = Tina4::Router.find_route("DELETE", "/data/5")
      expect(route).not_to be_nil
    end

    it "registers an ANY route that matches all methods" do
      Tina4::Router.any("/wildcard") { |req, res| res.text("any") }
      %w[GET POST PUT PATCH DELETE].each do |method|
        route, _params = Tina4::Router.find_route(method, "/wildcard")
        expect(route).not_to be_nil
      end
    end
  end

  describe "Dynamic params with {id} style" do
    it "extracts {id} from /api/users/{id}" do
      Tina4::Router.get("/api/users/{id}") { |req, res| res.text("user") }
      route, params = Tina4::Router.find_route("GET", "/api/users/42")
      expect(route).not_to be_nil
      expect(params[:id]).to eq("42")
    end

    it "extracts multiple brace-style params" do
      Tina4::Router.get("/api/users/{user_id}/posts/{post_id}") { |req, res| "ok" }
      route, params = Tina4::Router.find_route("GET", "/api/users/1/posts/99")
      expect(route).not_to be_nil
      expect(params[:user_id]).to eq("1")
      expect(params[:post_id]).to eq("99")
    end
  end

  describe "Catch-all routes" do
    it "matches /docs/*path" do
      Tina4::Router.get("/docs/*path") { |req, res| res.text("docs") }
      route, params = Tina4::Router.find_route("GET", "/docs/api/v1/users")
      expect(route).not_to be_nil
      expect(params[:path]).to eq("api/v1/users")
    end
  end

  describe "Per-route middleware" do
    it "runs middleware on route match" do
      called = false
      auth_mw = proc { |req, res| called = true; true }
      Tina4::Router.get("/admin", middleware: [auth_mw]) { |req, res| "admin" }

      route, _params = Tina4::Router.find_route("GET", "/admin")
      expect(route).not_to be_nil
      expect(route.middleware.length).to eq(1)

      # Simulate middleware run
      req = double("request")
      res = double("response")
      result = route.run_middleware(req, res)
      expect(result).to be true
      expect(called).to be true
    end

    it "halts when middleware returns false" do
      deny_mw = proc { |req, res| false }
      Tina4::Router.get("/blocked", middleware: [deny_mw]) { |req, res| "nope" }

      route, _params = Tina4::Router.find_route("GET", "/blocked")
      req = double("request")
      res = double("response")
      result = route.run_middleware(req, res)
      expect(result).to be false
    end

    it "runs multiple middleware in order" do
      order = []
      mw1 = proc { |req, res| order << 1; true }
      mw2 = proc { |req, res| order << 2; true }
      Tina4::Router.get("/chain", middleware: [mw1, mw2]) { |req, res| "ok" }

      route, _params = Tina4::Router.find_route("GET", "/chain")
      route.run_middleware(double("req"), double("res"))
      expect(order).to eq([1, 2])
    end
  end

  describe "Route groups" do
    it "prefixes routes in a group" do
      Tina4::Router.group("/api/v1") do
        get("/users") { "users" }
        post("/users") { "create" }
      end
      route, _ = Tina4::Router.find_route("GET", "/api/v1/users")
      expect(route).not_to be_nil
      route2, _ = Tina4::Router.find_route("POST", "/api/v1/users")
      expect(route2).not_to be_nil
    end

    it "supports nested groups" do
      Tina4::Router.group("/api") do
        group("/v2") do
          get("/items") { "items" }
        end
      end
      route, _ = Tina4::Router.find_route("GET", "/api/v2/items")
      expect(route).not_to be_nil
    end

    it "inherits group middleware" do
      log = []
      group_mw = proc { |req, res| log << :group; true }
      Tina4::Router.group("/admin", middleware: [group_mw]) do
        get("/dashboard") { "dash" }
      end
      route, _ = Tina4::Router.find_route("GET", "/admin/dashboard")
      expect(route).not_to be_nil
      expect(route.middleware.length).to eq(1)
    end
  end

  describe "Route listing" do
    it "returns all registered routes" do
      Tina4::Router.get("/a") { "a" }
      Tina4::Router.post("/b") { "b" }
      Tina4::Router.put("/c") { "c" }
      expect(Tina4::Router.routes.length).to eq(3)
      methods = Tina4::Router.routes.map(&:method)
      expect(methods).to contain_exactly("GET", "POST", "PUT")
    end
  end

  describe "File-based route discovery" do
    it "loads routes from a directory" do
      dir = Dir.mktmpdir("tina4_routes")
      File.write(File.join(dir, "test_route.rb"), <<~RUBY)
        Tina4::Router.get("/from-file") { |req, res| res.text("loaded") }
      RUBY

      Tina4::Router.load_routes(dir)
      route, _ = Tina4::Router.find_route("GET", "/from-file")
      expect(route).not_to be_nil
      FileUtils.rm_rf(dir)
    end
  end

  describe "Mixed param styles" do
    it "handles {id:int} style params" do
      Tina4::Router.add("GET", "/items/{id:int}", proc { "item" })
      route, params = Tina4::Router.find_route("GET", "/items/42")
      expect(route).not_to be_nil
      expect(params[:id]).to eq(42)
    end

    it "handles {id} style params (string)" do
      Tina4::Router.add("GET", "/items/{id}", proc { "item" })
      route, params = Tina4::Router.find_route("GET", "/items/42")
      expect(route).not_to be_nil
      expect(params[:id]).to eq("42")
    end
  end
end
