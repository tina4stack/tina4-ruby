# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "Request v3 features" do
  def make_env(overrides = {})
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/test",
      "QUERY_STRING" => "",
      "CONTENT_TYPE" => "",
      "REMOTE_ADDR" => "192.168.1.1",
      "rack.input" => StringIO.new(""),
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "example.com",
      "SERVER_PORT" => "443"
    }.merge(overrides)
  end

  describe "#query" do
    it "parses query string into hash" do
      env = make_env("QUERY_STRING" => "page=2&limit=10&search=ruby")
      req = Tina4::Request.new(env)
      expect(req.query["page"]).to eq("2")
      expect(req.query["limit"]).to eq("10")
      expect(req.query["search"]).to eq("ruby")
    end

    it "returns empty hash for no query string" do
      env = make_env("QUERY_STRING" => "")
      req = Tina4::Request.new(env)
      expect(req.query).to eq({})
    end

    it "decodes URL-encoded values" do
      env = make_env("QUERY_STRING" => "name=hello+world&tag=%23ruby")
      req = Tina4::Request.new(env)
      expect(req.query["name"]).to eq("hello world")
      expect(req.query["tag"]).to eq("#ruby")
    end
  end

  describe "#ip with X-Forwarded-For" do
    it "uses X-Forwarded-For when present" do
      env = make_env(
        "HTTP_X_FORWARDED_FOR" => "203.0.113.50, 70.41.3.18",
        "REMOTE_ADDR" => "127.0.0.1"
      )
      req = Tina4::Request.new(env)
      expect(req.ip).to eq("203.0.113.50")
    end

    it "uses X-Real-IP as fallback" do
      env = make_env(
        "HTTP_X_REAL_IP" => "10.0.0.5",
        "REMOTE_ADDR" => "127.0.0.1"
      )
      req = Tina4::Request.new(env)
      expect(req.ip).to eq("10.0.0.5")
    end

    it "falls back to REMOTE_ADDR" do
      env = make_env("REMOTE_ADDR" => "192.168.1.100")
      req = Tina4::Request.new(env)
      expect(req.ip).to eq("192.168.1.100")
    end
  end

  describe "#url" do
    it "reconstructs full URL" do
      env = make_env(
        "PATH_INFO" => "/api/users",
        "QUERY_STRING" => "page=1"
      )
      req = Tina4::Request.new(env)
      expect(req.url).to eq("https://example.com/api/users?page=1")
    end

    it "omits query string when empty" do
      env = make_env("PATH_INFO" => "/api/users", "QUERY_STRING" => "")
      req = Tina4::Request.new(env)
      expect(req.url).to eq("https://example.com/api/users")
    end
  end

  describe "#body and #body_parsed" do
    it "parses JSON body" do
      json_body = '{"name":"Alice","age":30}'
      env = make_env(
        "REQUEST_METHOD" => "POST",
        "CONTENT_TYPE" => "application/json",
        "rack.input" => StringIO.new(json_body)
      )
      req = Tina4::Request.new(env)
      expect(req.body).to eq(json_body)
      expect(req.body_parsed["name"]).to eq("Alice")
      expect(req.body_parsed["age"]).to eq(30)
    end

    it "parses form-encoded body" do
      form_body = "name=Bob&email=bob%40test.com"
      env = make_env(
        "REQUEST_METHOD" => "POST",
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "rack.input" => StringIO.new(form_body)
      )
      req = Tina4::Request.new(env)
      expect(req.body_parsed["name"]).to eq("Bob")
      expect(req.body_parsed["email"]).to eq("bob@test.com")
    end
  end

  describe "#params (merged)" do
    it "merges query, body, and path params" do
      json_body = '{"from_body":"yes"}'
      env = make_env(
        "REQUEST_METHOD" => "POST",
        "CONTENT_TYPE" => "application/json",
        "QUERY_STRING" => "from_query=yes",
        "rack.input" => StringIO.new(json_body)
      )
      path_params = { from_path: "yes" }
      req = Tina4::Request.new(env, path_params)

      expect(req.params["from_query"]).to eq("yes")
      expect(req.params["from_body"]).to eq("yes")
      expect(req.params["from_path"]).to eq("yes")
    end

    it "path params take highest priority" do
      json_body = '{"name":"from_body"}'
      env = make_env(
        "REQUEST_METHOD" => "POST",
        "CONTENT_TYPE" => "application/json",
        "QUERY_STRING" => "name=from_query",
        "rack.input" => StringIO.new(json_body)
      )
      path_params = { name: "from_path" }
      req = Tina4::Request.new(env, path_params)
      expect(req.params["name"]).to eq("from_path")
    end
  end

  describe "#headers" do
    it "extracts HTTP headers" do
      env = make_env(
        "HTTP_AUTHORIZATION" => "Bearer abc123",
        "HTTP_ACCEPT" => "application/json"
      )
      req = Tina4::Request.new(env)
      expect(req.headers["authorization"]).to eq("Bearer abc123")
      expect(req.headers["accept"]).to eq("application/json")
    end

    it "accesses header by name" do
      env = make_env("HTTP_X_CUSTOM_HEADER" => "custom_value")
      req = Tina4::Request.new(env)
      expect(req.header("X-Custom-Header")).to eq("custom_value")
    end
  end

  describe "#method and #path" do
    it "returns request method and path" do
      env = make_env("REQUEST_METHOD" => "POST", "PATH_INFO" => "/api/data")
      req = Tina4::Request.new(env)
      expect(req.method).to eq("POST")
      expect(req.path).to eq("/api/data")
    end
  end

  describe "#bearer_token" do
    it "extracts bearer token from Authorization header" do
      env = make_env("HTTP_AUTHORIZATION" => "Bearer my_token_123")
      req = Tina4::Request.new(env)
      expect(req.bearer_token).to eq("my_token_123")
    end

    it "returns nil when no bearer token" do
      env = make_env
      req = Tina4::Request.new(env)
      expect(req.bearer_token).to be_nil
    end
  end
end
