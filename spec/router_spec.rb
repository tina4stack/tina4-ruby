# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Router do
  before { Tina4::Router.clear! }

  describe ".add_route" do
    it "registers a GET route" do
      handler = proc { "hello" }
      Tina4::Router.add("GET", "/hello", handler)
      expect(Tina4::Router.routes.length).to eq(1)
    end

    it "registers routes for different methods" do
      Tina4::Router.add("GET", "/test", proc { "get" })
      Tina4::Router.add("POST", "/test", proc { "post" })
      expect(Tina4::Router.routes.length).to eq(2)
    end

    it "stores swagger metadata" do
      meta = { summary: "Test endpoint", tags: ["test"] }
      route = Tina4::Router.add("GET", "/api", proc { "api" }, swagger_meta: meta)
      expect(route.swagger_meta).to eq(meta)
    end
  end

  describe ".find_route" do
    it "finds an exact match" do
      Tina4::Router.add("GET", "/hello", proc { "hello" })
      route, params = Tina4::Router.match("GET", "/hello")
      expect(route).not_to be_nil
      expect(params).to eq({})
    end

    it "returns nil for non-matching path" do
      Tina4::Router.add("GET", "/hello", proc { "hello" })
      result = Tina4::Router.match("GET", "/world")
      expect(result).to be_nil
    end

    it "returns nil for non-matching method" do
      Tina4::Router.add("GET", "/hello", proc { "hello" })
      result = Tina4::Router.match("POST", "/hello")
      expect(result).to be_nil
    end

    it "extracts string path parameters" do
      Tina4::Router.add("GET", "/users/{name}", proc { "user" })
      route, params = Tina4::Router.match("GET", "/users/alice")
      expect(route).not_to be_nil
      expect(params["name"] || params[:name]).to eq("alice")
    end

    it "extracts integer path parameters" do
      Tina4::Router.add("GET", "/users/{id:int}", proc { "user" })
      route, params = Tina4::Router.match("GET", "/users/42")
      expect(route).not_to be_nil
      id_val = params["id"] || params[:id]
      expect(id_val.to_i).to eq(42)
    end

    it "extracts float path parameters" do
      Tina4::Router.add("GET", "/price/{amount:float}", proc { "price" })
      route, params = Tina4::Router.match("GET", "/price/19.99")
      expect(route).not_to be_nil
      amount = params["amount"] || params[:amount]
      expect(amount.to_f).to eq(19.99)
    end

    it "does not match int param with non-numeric value" do
      Tina4::Router.add("GET", "/users/{id:int}", proc { "user" })
      result = Tina4::Router.match("GET", "/users/abc")
      expect(result).to be_nil
    end

    it "handles multiple path parameters" do
      Tina4::Router.add("GET", "/users/{userId:int}/posts/{postId:int}", proc { "post" })
      route, params = Tina4::Router.match("GET", "/users/1/posts/5")
      expect(route).not_to be_nil
    end

    it "handles trailing slash" do
      Tina4::Router.add("GET", "/hello", proc { "hello" })
      route, _ = Tina4::Router.match("GET", "/hello/")
      expect(route).not_to be_nil
    end

    it "does NOT support Ruby :id syntax (only {id})" do
      Tina4::Router.add("GET", "/users/:id", proc { "user" })
      result = Tina4::Router.match("GET", "/users/42")
      expect(result).to be_nil
    end
  end

  describe ".clear!" do
    it "removes all routes" do
      Tina4::Router.add("GET", "/test", proc { "test" })
      Tina4::Router.clear!
      expect(Tina4::Router.routes).to be_empty
    end
  end

  describe ".group" do
    it "prefixes routes in a group" do
      Tina4::Router.group("/api/v1") do
        get("/users") { "users" }
      end
      route, _ = Tina4::Router.match("GET", "/api/v1/users")
      expect(route).not_to be_nil
    end
  end

  # ── Wildcard / Catch-All Tests ──────────────────────────────────

  describe "wildcard routes" do
    it "matches a catch-all splat route" do
      Tina4::Router.add("GET", "/docs/*path", proc { "docs" })
      route, params = Tina4::Router.match("GET", "/docs/api/v1/users")
      expect(route).not_to be_nil
      path_val = params["path"] || params[:path]
      expect(path_val).to eq("api/v1/users")
    end

    it "matches a bare /* wildcard and exposes capture under '*' key (parity with Python/PHP/Node)" do
      Tina4::Router.add("GET", "/docs/*", proc { "docs" })
      route, params = Tina4::Router.match("GET", "/docs/getting-started")
      expect(route).not_to be_nil
      expect(params[:"*"] || params["*"]).to eq("getting-started")
    end

    it "matches a root /* catch-all" do
      Tina4::Router.add("GET", "/*", proc { "fallback" })
      route, params = Tina4::Router.match("GET", "/random/path")
      expect(route).not_to be_nil
      expect(params[:"*"] || params["*"]).to eq("random/path")
    end
  end

  # ── Method Matching Tests ──────────────────────────────────────

  describe "method matching" do
    it "registers and matches PUT routes" do
      Tina4::Router.add("PUT", "/update/{id}", proc { "update" })
      route, params = Tina4::Router.match("PUT", "/update/5")
      expect(route).not_to be_nil
    end

    it "registers and matches PATCH routes" do
      Tina4::Router.add("PATCH", "/patch/{id}", proc { "patch" })
      route, _ = Tina4::Router.match("PATCH", "/patch/5")
      expect(route).not_to be_nil
    end

    it "registers and matches DELETE routes" do
      Tina4::Router.add("DELETE", "/remove/{id}", proc { "delete" })
      route, _ = Tina4::Router.match("DELETE", "/remove/5")
      expect(route).not_to be_nil
    end

    it "matches correct handler for same path, different methods" do
      get_handler = proc { "get" }
      post_handler = proc { "post" }
      Tina4::Router.add("GET", "/dual", get_handler)
      Tina4::Router.add("POST", "/dual", post_handler)

      get_route, _ = Tina4::Router.match("GET", "/dual")
      post_route, _ = Tina4::Router.match("POST", "/dual")
      expect(get_route.handler).to eq(get_handler)
      expect(post_route.handler).to eq(post_handler)
    end
  end

  # ── Middleware Chain Tests ─────────────────────────────────────

  describe "middleware chains" do
    it "attaches middleware to a route" do
      auth_mw = proc { |req, res| true }
      Tina4::Router.add("GET", "/mw", proc { "ok" }, middleware: [auth_mw])
      route, _ = Tina4::Router.match("GET", "/mw")
      expect(route).not_to be_nil
      expect(route.middleware.length).to eq(1)
    end

    it "runs multiple middleware in order" do
      order = []
      mw1 = proc { |req, res| order << 1; true }
      mw2 = proc { |req, res| order << 2; true }
      Tina4::Router.add("GET", "/chain", proc { "ok" }, middleware: [mw1, mw2])
      route, _ = Tina4::Router.match("GET", "/chain")
      route.run_middleware(double("req"), double("res"))
      expect(order).to eq([1, 2])
    end

    it "halts when middleware returns false" do
      deny_mw = proc { |req, res| false }
      Tina4::Router.add("GET", "/blocked", proc { "nope" }, middleware: [deny_mw])
      route, _ = Tina4::Router.match("GET", "/blocked")
      result = route.run_middleware(double("req"), double("res"))
      expect(result).to be false
    end
  end

  # ── Route Group Tests ──────────────────────────────────────────

  describe ".group advanced" do
    it "supports nested groups" do
      Tina4::Router.group("/api") do
        group("/v2") do
          get("/items") { "items" }
        end
      end
      route, _ = Tina4::Router.match("GET", "/api/v2/items")
      expect(route).not_to be_nil
    end

    it "inherits group middleware" do
      log = []
      group_mw = proc { |req, res| log << :group; true }
      Tina4::Router.group("/admin", middleware: [group_mw]) do
        get("/dashboard") { "dash" }
      end
      route, _ = Tina4::Router.match("GET", "/admin/dashboard")
      expect(route).not_to be_nil
      expect(route.middleware.length).to eq(1)
    end

    it "registers multiple routes in a group" do
      Tina4::Router.group("/api/v3") do
        get("/users") { "users" }
        post("/users") { "create" }
        get("/products") { "products" }
      end
      route1, _ = Tina4::Router.match("GET", "/api/v3/users")
      route2, _ = Tina4::Router.match("POST", "/api/v3/users")
      route3, _ = Tina4::Router.match("GET", "/api/v3/products")
      expect(route1).not_to be_nil
      expect(route2).not_to be_nil
      expect(route3).not_to be_nil
    end
  end

  # ── Path Parameter Edge Cases ──────────────────────────────────

  describe "path parameter edge cases" do
    it "handles root path" do
      Tina4::Router.add("GET", "/", proc { "root" })
      route, _ = Tina4::Router.match("GET", "/")
      expect(route).not_to be_nil
    end

    it "handles path type parameter" do
      Tina4::Router.add("GET", "/files/{filepath:path}", proc { "file" })
      route, params = Tina4::Router.match("GET", "/files/docs/readme.md")
      if route
        fp = params["filepath"] || params[:filepath]
        expect(fp).to include("docs")
      end
    end

    it "does not match extra segments on exact path" do
      Tina4::Router.add("GET", "/api/users", proc { "users" })
      result = Tina4::Router.match("GET", "/api/users/extra")
      expect(result).to be_nil
    end
  end
end

RSpec.describe Tina4::Route do
  describe "#match?" do
    it "matches exact paths" do
      route = Tina4::Route.new("GET", "/hello", proc { "hello" })
      result = route.match?("/hello", "GET")
      expect(result).not_to be false
    end

    it "does not match different methods" do
      route = Tina4::Route.new("GET", "/hello", proc { "hello" })
      result = route.match?("/hello", "POST")
      expect(result).to be false
    end

    it "extracts path parameters" do
      route = Tina4::Route.new("GET", "/users/{id}", proc { "user" })
      result = route.match?("/users/123", "GET")
      expect(result).to be_a(Hash)
    end
  end
end
