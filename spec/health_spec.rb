# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Health do
  describe ".status" do
    it "returns a hash with status ok" do
      result = Tina4::Health.status
      expect(result[:status]).to eq("ok")
    end

    it "includes the framework version" do
      result = Tina4::Health.status
      expect(result[:version]).to eq(Tina4::VERSION)
    end

    it "includes uptime as a number" do
      result = Tina4::Health.status
      expect(result[:uptime]).to be_a(Float)
      expect(result[:uptime]).to be >= 0
    end

    it "includes framework name" do
      result = Tina4::Health.status
      expect(result[:framework]).to eq("tina4-ruby")
    end
  end

  describe ".register!" do
    before { Tina4::Router.clear! }

    it "registers a GET /health route" do
      Tina4::Health.register!
      result = Tina4::Router.find_route("GET", "/health")
      expect(result).not_to be_nil
    end
  end

  describe ".handle" do
    it "returns JSON health response" do
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/health",
        "QUERY_STRING" => "",
        "rack.input" => StringIO.new("")
      }
      request = Tina4::Request.new(env)
      response = Tina4::Response.new

      Tina4::Health.handle(request, response)

      expect(response.status).to eq(200)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["framework"]).to eq("tina4-ruby")
      expect(body["version"]).to eq(Tina4::VERSION)
      expect(body["uptime"]).to be_a(Numeric)
    end
  end
end
