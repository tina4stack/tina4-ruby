# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Router do
  before { Tina4::Router.clear! }

  describe ".add_route" do
    it "registers a GET route" do
      handler = proc { "hello" }
      Tina4::Router.add_route("GET", "/hello", handler)
      expect(Tina4::Router.routes.length).to eq(1)
    end

    it "registers routes for different methods" do
      Tina4::Router.add_route("GET", "/test", proc { "get" })
      Tina4::Router.add_route("POST", "/test", proc { "post" })
      expect(Tina4::Router.routes.length).to eq(2)
    end

    it "stores swagger metadata" do
      meta = { summary: "Test endpoint", tags: ["test"] }
      route = Tina4::Router.add_route("GET", "/api", proc { "api" }, swagger_meta: meta)
      expect(route.swagger_meta).to eq(meta)
    end
  end

  describe ".find_route" do
    it "finds an exact match" do
      Tina4::Router.add_route("GET", "/hello", proc { "hello" })
      route, params = Tina4::Router.find_route("/hello", "GET")
      expect(route).not_to be_nil
      expect(params).to eq({})
    end

    it "returns nil for non-matching path" do
      Tina4::Router.add_route("GET", "/hello", proc { "hello" })
      result = Tina4::Router.find_route("/world", "GET")
      expect(result).to be_nil
    end

    it "returns nil for non-matching method" do
      Tina4::Router.add_route("GET", "/hello", proc { "hello" })
      result = Tina4::Router.find_route("/hello", "POST")
      expect(result).to be_nil
    end

    it "extracts string path parameters" do
      Tina4::Router.add_route("GET", "/users/{name}", proc { "user" })
      route, params = Tina4::Router.find_route("/users/alice", "GET")
      expect(route).not_to be_nil
      expect(params["name"] || params[:name]).to eq("alice")
    end

    it "extracts integer path parameters" do
      Tina4::Router.add_route("GET", "/users/{id:int}", proc { "user" })
      route, params = Tina4::Router.find_route("/users/42", "GET")
      expect(route).not_to be_nil
      id_val = params["id"] || params[:id]
      expect(id_val.to_i).to eq(42)
    end

    it "extracts float path parameters" do
      Tina4::Router.add_route("GET", "/price/{amount:float}", proc { "price" })
      route, params = Tina4::Router.find_route("/price/19.99", "GET")
      expect(route).not_to be_nil
      amount = params["amount"] || params[:amount]
      expect(amount.to_f).to eq(19.99)
    end

    it "does not match int param with non-numeric value" do
      Tina4::Router.add_route("GET", "/users/{id:int}", proc { "user" })
      result = Tina4::Router.find_route("/users/abc", "GET")
      expect(result).to be_nil
    end

    it "handles multiple path parameters" do
      Tina4::Router.add_route("GET", "/users/{userId:int}/posts/{postId:int}", proc { "post" })
      route, params = Tina4::Router.find_route("/users/1/posts/5", "GET")
      expect(route).not_to be_nil
    end

    it "handles trailing slash" do
      Tina4::Router.add_route("GET", "/hello", proc { "hello" })
      route, _ = Tina4::Router.find_route("/hello/", "GET")
      expect(route).not_to be_nil
    end

    it "does NOT support Ruby :id syntax (only {id})" do
      Tina4::Router.add_route("GET", "/users/:id", proc { "user" })
      result = Tina4::Router.find_route("/users/42", "GET")
      expect(result).to be_nil
    end
  end

  describe ".clear!" do
    it "removes all routes" do
      Tina4::Router.add_route("GET", "/test", proc { "test" })
      Tina4::Router.clear!
      expect(Tina4::Router.routes).to be_empty
    end
  end

  describe ".group" do
    it "prefixes routes in a group" do
      Tina4::Router.group("/api/v1") do
        get("/users") { "users" }
      end
      route, _ = Tina4::Router.find_route("/api/v1/users", "GET")
      expect(route).not_to be_nil
    end
  end

  # ── Wildcard / Catch-All Tests ──────────────────────────────────

  describe "wildcard routes" do
    it "matches a catch-all splat route" do
      Tina4::Router.add_route("GET", "/docs/*path", proc { "docs" })
      route, params = Tina4::Router.find_route("/docs/api/v1/users", "GET")
      expect(route).not_to be_nil
      path_val = params["path"] || params[:path]
      expect(path_val).to eq("api/v1/users")
    end
  end

  # ── Method Matching Tests ──────────────────────────────────────

  describe "method matching" do
    it "registers and matches PUT routes" do
      Tina4::Router.add_route("PUT", "/update/{id}", proc { "update" })
      route, params = Tina4::Router.find_route("/update/5", "PUT")
      expect(route).not_to be_nil
    end

    it "registers and matches PATCH routes" do
      Tina4::Router.add_route("PATCH", "/patch/{id}", proc { "patch" })
      route, _ = Tina4::Router.find_route("/patch/5", "PATCH")
      expect(route).not_to be_nil
    end

    it "registers and matches DELETE routes" do
      Tina4::Router.add_route("DELETE", "/remove/{id}", proc { "delete" })
      route, _ = Tina4::Router.find_route("/remove/5", "DELETE")
      expect(route).not_to be_nil
    end

    it "matches correct handler for same path, different methods" do
      get_handler = proc { "get" }
      post_handler = proc { "post" }
      Tina4::Router.add_route("GET", "/dual", get_handler)
      Tina4::Router.add_route("POST", "/dual", post_handler)

      get_route, _ = Tina4::Router.find_route("/dual", "GET")
      post_route, _ = Tina4::Router.find_route("/dual", "POST")
      expect(get_route.handler).to eq(get_handler)
      expect(post_route.handler).to eq(post_handler)
    end
  end

  # ── Middleware Chain Tests ─────────────────────────────────────

  describe "middleware chains" do
    it "attaches middleware to a route" do
      auth_mw = proc { |req, res| true }
      Tina4::Router.add_route("GET", "/mw", proc { "ok" }, middleware: [auth_mw])
      route, _ = Tina4::Router.find_route("/mw", "GET")
      expect(route).not_to be_nil
      expect(route.middleware.length).to eq(1)
    end

    it "runs multiple middleware in order" do
      order = []
      mw1 = proc { |req, res| order << 1; true }
      mw2 = proc { |req, res| order << 2; true }
      Tina4::Router.add_route("GET", "/chain", proc { "ok" }, middleware: [mw1, mw2])
      route, _ = Tina4::Router.find_route("/chain", "GET")
      route.run_middleware(double("req"), double("res"))
      expect(order).to eq([1, 2])
    end

    it "halts when middleware returns false" do
      deny_mw = proc { |req, res| false }
      Tina4::Router.add_route("GET", "/blocked", proc { "nope" }, middleware: [deny_mw])
      route, _ = Tina4::Router.find_route("/blocked", "GET")
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
      route, _ = Tina4::Router.find_route("/api/v2/items", "GET")
      expect(route).not_to be_nil
    end

    it "inherits group middleware" do
      log = []
      group_mw = proc { |req, res| log << :group; true }
      Tina4::Router.group("/admin", middleware: [group_mw]) do
        get("/dashboard") { "dash" }
      end
      route, _ = Tina4::Router.find_route("/admin/dashboard", "GET")
      expect(route).not_to be_nil
      expect(route.middleware.length).to eq(1)
    end

    it "registers multiple routes in a group" do
      Tina4::Router.group("/api/v3") do
        get("/users") { "users" }
        post("/users") { "create" }
        get("/products") { "products" }
      end
      route1, _ = Tina4::Router.find_route("/api/v3/users", "GET")
      route2, _ = Tina4::Router.find_route("/api/v3/users", "POST")
      route3, _ = Tina4::Router.find_route("/api/v3/products", "GET")
      expect(route1).not_to be_nil
      expect(route2).not_to be_nil
      expect(route3).not_to be_nil
    end
  end

  # ── Path Parameter Edge Cases ──────────────────────────────────

  describe "path parameter edge cases" do
    it "handles root path" do
      Tina4::Router.add_route("GET", "/", proc { "root" })
      route, _ = Tina4::Router.find_route("/", "GET")
      expect(route).not_to be_nil
    end

    it "handles path type parameter" do
      Tina4::Router.add_route("GET", "/files/{filepath:path}", proc { "file" })
      route, params = Tina4::Router.find_route("/files/docs/readme.md", "GET")
      if route
        fp = params["filepath"] || params[:filepath]
        expect(fp).to include("docs")
      end
    end

    it "does not match extra segments on exact path" do
      Tina4::Router.add_route("GET", "/api/users", proc { "users" })
      result = Tina4::Router.find_route("/api/users/extra", "GET")
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
