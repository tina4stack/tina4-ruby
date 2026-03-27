# frozen_string_literal: true

require "spec_helper"

RSpec.describe "POST route protection" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_post_protection_test") }

  before(:each) do
    Tina4::Router.clear!
    # Set up Auth keys for token generation
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)
  end

  after(:each) do
    Tina4::Router.clear!
    FileUtils.rm_rf(tmp_dir)
  end

  # Helper to build a minimal Rack env
  def rack_env(method, path, auth_header: nil)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(""),
      "REMOTE_ADDR" => "127.0.0.1",
    }
    env["HTTP_AUTHORIZATION"] = auth_header if auth_header
    env
  end

  # ── POST route with auth_handler rejects unauthenticated requests ──

  describe "POST with bearer_auth" do
    it "returns 403 when no token is provided" do
      Tina4::Router.add_route("POST", "/api/items",
        ->(req, res) { res.json({ created: true }, 201) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("POST", "/api/items"))
      expect(status).to eq(403)
    end

    it "succeeds with a valid token" do
      Tina4::Router.add_route("POST", "/api/items",
        ->(req, res) { res.json({ created: true }, 201) },
        auth_handler: Tina4::Auth.bearer_auth)

      token = Tina4::Auth.create_token({ "user_id" => 1 })
      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("POST", "/api/items", auth_header: "Bearer #{token}"))
      expect(status).to eq(201)
    end

    it "returns 403 with an invalid token" do
      Tina4::Router.add_route("POST", "/api/items",
        ->(req, res) { res.json({ created: true }, 201) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("POST", "/api/items", auth_header: "Bearer invalid.token.here"))
      expect(status).to eq(403)
    end

    it "returns 403 with a malformed Authorization header" do
      Tina4::Router.add_route("POST", "/api/items",
        ->(req, res) { res.json({ created: true }, 201) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("POST", "/api/items", auth_header: "Basic dXNlcjpwYXNz"))
      expect(status).to eq(403)
    end
  end

  # ── GET route without auth_handler is public ────────────────────

  describe "GET without auth_handler" do
    it "works without a token" do
      Tina4::Router.add_route("GET", "/api/items",
        ->(req, res) { res.json({ items: [] }) })

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("GET", "/api/items"))
      expect(status).to eq(200)
    end
  end

  # ── GET route with bearer_auth requires token ───────────────────

  describe "GET with bearer_auth" do
    it "returns 403 without a token" do
      Tina4::Router.add_route("GET", "/api/admin/stats",
        ->(req, res) { res.json({ secret: true }) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("GET", "/api/admin/stats"))
      expect(status).to eq(403)
    end

    it "succeeds with a valid token" do
      Tina4::Router.add_route("GET", "/api/admin/stats",
        ->(req, res) { res.json({ secret: true }) },
        auth_handler: Tina4::Auth.bearer_auth)

      token = Tina4::Auth.create_token({ "user_id" => 1 })
      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("GET", "/api/admin/stats", auth_header: "Bearer #{token}"))
      expect(status).to eq(200)
    end
  end

  # ── PUT/PATCH/DELETE with auth_handler ──────────────────────────

  describe "PUT with bearer_auth" do
    it "returns 403 without a token" do
      Tina4::Router.add_route("PUT", "/api/items/{id}",
        ->(req, res) { res.json({ updated: true }) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("PUT", "/api/items/1"))
      expect(status).to eq(403)
    end

    it "succeeds with a valid token" do
      Tina4::Router.add_route("PUT", "/api/items/{id}",
        ->(req, res) { res.json({ updated: true }) },
        auth_handler: Tina4::Auth.bearer_auth)

      token = Tina4::Auth.create_token({ "user_id" => 1 })
      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("PUT", "/api/items/1", auth_header: "Bearer #{token}"))
      expect(status).to eq(200)
    end
  end

  describe "PATCH with bearer_auth" do
    it "returns 403 without a token" do
      Tina4::Router.add_route("PATCH", "/api/items/{id}",
        ->(req, res) { res.json({ patched: true }) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("PATCH", "/api/items/1"))
      expect(status).to eq(403)
    end
  end

  describe "DELETE with bearer_auth" do
    it "returns 403 without a token" do
      Tina4::Router.add_route("DELETE", "/api/items/{id}",
        ->(req, res) { res.json({ deleted: true }) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("DELETE", "/api/items/1"))
      expect(status).to eq(403)
    end
  end

  # ── POST without auth_handler works without token ───────────────

  describe "POST without auth_handler (public via no_auth)" do
    it "works without a token when opted out with no_auth" do
      Tina4::Router.add_route("POST", "/api/webhook",
        ->(req, res) { res.json({ ok: true }) }).no_auth

      app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, _body = app.call(rack_env("POST", "/api/webhook"))
      expect(status).to eq(200)
    end
  end

  # ── Mixed secure and non-secure on same path ────────────────────

  describe "mixed secure and non-secure routes" do
    it "GET is public, POST requires auth" do
      Tina4::Router.add_route("GET", "/api/items",
        ->(req, res) { res.json({ items: [] }) })

      Tina4::Router.add_route("POST", "/api/items",
        ->(req, res) { res.json({ created: true }, 201) },
        auth_handler: Tina4::Auth.bearer_auth)

      app = Tina4::RackApp.new(root_dir: tmp_dir)

      # GET should succeed
      get_status, _, _ = app.call(rack_env("GET", "/api/items"))
      expect(get_status).to eq(200)

      # POST without token should fail
      post_status, _, _ = app.call(rack_env("POST", "/api/items"))
      expect(post_status).to eq(403)
    end
  end

  # ── Tina4.secure_post convenience method (if available) ─────────

  describe "Tina4.secure_post" do
    it "registers a POST with bearer_auth" do
      if Tina4.respond_to?(:secure_post)
        Tina4.secure_post("/api/secure-items") do |req, res|
          res.json({ created: true }, 201)
        end

        app = Tina4::RackApp.new(root_dir: tmp_dir)
        status, _, _ = app.call(rack_env("POST", "/api/secure-items"))
        expect(status).to eq(403)
      else
        skip "Tina4.secure_post not available"
      end
    end
  end
end
