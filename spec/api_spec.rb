# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::API do
  describe "#initialize" do
    it "stores base URL and default headers" do
      api = Tina4::API.new("https://api.example.com")
      expect(api.base_url).to eq("https://api.example.com")
      expect(api.headers).to include("Content-Type" => "application/json")
    end

    it "strips trailing slash from base URL" do
      api = Tina4::API.new("https://api.example.com/")
      expect(api.base_url).to eq("https://api.example.com")
    end

    it "merges custom headers" do
      api = Tina4::API.new("https://api.example.com", headers: { "X-Custom" => "value" })
      expect(api.headers["X-Custom"]).to eq("value")
    end
  end
end

RSpec.describe Tina4::APIResponse do
  describe "#success?" do
    it "returns true for 2xx status" do
      resp = Tina4::APIResponse.new(status: 200, body: "{}", headers: {})
      expect(resp.success?).to be true
    end

    it "returns true for 201 status" do
      resp = Tina4::APIResponse.new(status: 201, body: "{}", headers: {})
      expect(resp.success?).to be true
    end

    it "returns false for 4xx status" do
      resp = Tina4::APIResponse.new(status: 404, body: "", headers: {})
      expect(resp.success?).to be false
    end

    it "returns false for 0 status (connection error)" do
      resp = Tina4::APIResponse.new(status: 0, body: "", headers: {}, error: "Connection refused")
      expect(resp.success?).to be false
    end
  end

  describe "#json" do
    it "parses JSON body" do
      resp = Tina4::APIResponse.new(status: 200, body: '{"key":"value"}', headers: {})
      expect(resp.json).to eq({ "key" => "value" })
    end

    it "returns empty hash for invalid JSON" do
      resp = Tina4::APIResponse.new(status: 200, body: "not json", headers: {})
      expect(resp.json).to eq({})
    end
  end

  describe "#to_s" do
    it "returns a string representation" do
      resp = Tina4::APIResponse.new(status: 200, body: "", headers: {})
      expect(resp.to_s).to eq("APIResponse(status=200)")
    end
  end
end
