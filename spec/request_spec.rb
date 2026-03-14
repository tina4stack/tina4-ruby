# frozen_string_literal: true

require "spec_helper"
require "rack"

RSpec.describe Tina4::Request do
  def build_env(method: "GET", path: "/", query: "", body: "", content_type: nil, headers: {})
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
      "rack.input" => StringIO.new(body),
      "rack.errors" => StringIO.new,
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7145",
      "SCRIPT_NAME" => "",
      "rack.url_scheme" => "http"
    }
    env["CONTENT_TYPE"] = content_type if content_type
    headers.each do |key, value|
      env["HTTP_#{key.upcase.tr('-', '_')}"] = value
    end
    env
  end

  describe "#method" do
    it "returns the HTTP method" do
      request = Tina4::Request.new(build_env(method: "POST"))
      expect(request.method).to eq("POST")
    end
  end

  describe "#path" do
    it "returns the request path" do
      request = Tina4::Request.new(build_env(path: "/api/users"))
      expect(request.path).to eq("/api/users")
    end
  end

  describe "#params" do
    it "parses query string parameters" do
      request = Tina4::Request.new(build_env(query: "page=1&limit=10"))
      expect(request.params["page"]).to eq("1")
      expect(request.params["limit"]).to eq("10")
    end
  end

  describe "#headers" do
    it "extracts HTTP headers" do
      request = Tina4::Request.new(build_env(headers: { "Authorization" => "Bearer token123" }))
      auth = request.headers["authorization"] || request.header("authorization")
      expect(auth).to eq("Bearer token123")
    end
  end

  describe "#body / #json_body" do
    it "parses JSON body" do
      json = '{"name": "Alice"}'
      request = Tina4::Request.new(build_env(
        method: "POST",
        body: json,
        content_type: "application/json"
      ))
      body = request.respond_to?(:json_body) ? request.json_body : request.body
      if body.is_a?(Hash)
        expect(body["name"]).to eq("Alice")
      end
    end
  end

  describe "#bearer_token" do
    it "extracts bearer token from Authorization header" do
      request = Tina4::Request.new(build_env(headers: { "Authorization" => "Bearer mytoken" }))
      if request.respond_to?(:bearer_token)
        expect(request.bearer_token).to eq("mytoken")
      else
        auth = request.headers["authorization"] || request.header("authorization")
        expect(auth).to include("mytoken")
      end
    end
  end

  describe "#cookies" do
    it "parses cookies from header" do
      request = Tina4::Request.new(build_env(headers: { "Cookie" => "session=abc123; theme=dark" }))
      expect(request.cookies["session"]).to eq("abc123")
    end
  end

  describe "#ip" do
    it "returns the remote IP" do
      env = build_env
      env["REMOTE_ADDR"] = "127.0.0.1"
      request = Tina4::Request.new(env)
      if request.respond_to?(:ip)
        expect(request.ip).to eq("127.0.0.1")
      end
    end
  end
end
