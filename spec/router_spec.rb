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
