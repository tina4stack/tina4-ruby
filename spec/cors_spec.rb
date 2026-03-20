# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::CorsMiddleware do
  after { Tina4::CorsMiddleware.reset! }

  describe ".config" do
    it "returns default config when no env vars set" do
      config = Tina4::CorsMiddleware.config
      expect(config[:origins]).to eq("*")
      expect(config[:methods]).to include("GET")
      expect(config[:methods]).to include("POST")
      expect(config[:headers]).to include("Content-Type")
      expect(config[:max_age]).to eq("86400")
    end

    it "reads from TINA4_CORS_ORIGINS env var" do
      ENV["TINA4_CORS_ORIGINS"] = "https://example.com,https://other.com"
      Tina4::CorsMiddleware.reset!

      config = Tina4::CorsMiddleware.config
      expect(config[:origins]).to eq("https://example.com,https://other.com")

      ENV.delete("TINA4_CORS_ORIGINS")
    end

    it "reads from TINA4_CORS_METHODS env var" do
      ENV["TINA4_CORS_METHODS"] = "GET, POST"
      Tina4::CorsMiddleware.reset!

      config = Tina4::CorsMiddleware.config
      expect(config[:methods]).to eq("GET, POST")

      ENV.delete("TINA4_CORS_METHODS")
    end

    it "reads from TINA4_CORS_HEADERS env var" do
      ENV["TINA4_CORS_HEADERS"] = "X-Custom-Header"
      Tina4::CorsMiddleware.reset!

      config = Tina4::CorsMiddleware.config
      expect(config[:headers]).to eq("X-Custom-Header")

      ENV.delete("TINA4_CORS_HEADERS")
    end

    it "reads from TINA4_CORS_MAX_AGE env var" do
      ENV["TINA4_CORS_MAX_AGE"] = "3600"
      Tina4::CorsMiddleware.reset!

      config = Tina4::CorsMiddleware.config
      expect(config[:max_age]).to eq("3600")

      ENV.delete("TINA4_CORS_MAX_AGE")
    end
  end

  describe ".preflight_response" do
    it "returns a 204 status" do
      status, _headers, _body = Tina4::CorsMiddleware.preflight_response
      expect(status).to eq(204)
    end

    it "includes CORS headers" do
      _status, headers, _body = Tina4::CorsMiddleware.preflight_response
      expect(headers["access-control-allow-origin"]).to eq("*")
      expect(headers["access-control-allow-methods"]).to include("GET")
      expect(headers["access-control-allow-headers"]).to include("Content-Type")
      expect(headers["access-control-max-age"]).to eq("86400")
    end
  end

  describe ".origin_allowed?" do
    it "allows all origins with wildcard" do
      expect(Tina4::CorsMiddleware.origin_allowed?("https://anything.com")).to be true
    end

    it "checks specific origins" do
      ENV["TINA4_CORS_ORIGINS"] = "https://example.com,https://other.com"
      Tina4::CorsMiddleware.reset!

      expect(Tina4::CorsMiddleware.origin_allowed?("https://example.com")).to be true
      expect(Tina4::CorsMiddleware.origin_allowed?("https://other.com")).to be true
      expect(Tina4::CorsMiddleware.origin_allowed?("https://evil.com")).to be false

      ENV.delete("TINA4_CORS_ORIGINS")
    end
  end

  describe ".apply_headers" do
    it "adds CORS headers to a response hash" do
      headers = {}
      Tina4::CorsMiddleware.apply_headers(headers)

      expect(headers["access-control-allow-origin"]).to eq("*")
      expect(headers["access-control-allow-methods"]).to include("GET")
    end

    it "reflects the request origin when specific origins are configured" do
      ENV["TINA4_CORS_ORIGINS"] = "https://example.com,https://other.com"
      Tina4::CorsMiddleware.reset!

      headers = {}
      env = { "HTTP_ORIGIN" => "https://example.com" }
      Tina4::CorsMiddleware.apply_headers(headers, env)

      expect(headers["access-control-allow-origin"]).to eq("https://example.com")

      ENV.delete("TINA4_CORS_ORIGINS")
    end
  end
end
