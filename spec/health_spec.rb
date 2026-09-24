# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"

RSpec.describe Tina4::Health do
  # ADR-0078: the body carries the version in debug mode only; these cases
  # characterise the debug body (spec/dev_surface_contract_spec.rb covers both).
  around(:each) do |example|
    saved = ENV["TINA4_DEBUG"]
    ENV["TINA4_DEBUG"] = "true"
    example.run
  ensure
    saved.nil? ? ENV.delete("TINA4_DEBUG") : ENV["TINA4_DEBUG"] = saved
  end

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

    it "wires the registered GET /health route to Health.handle" do
      Tina4::Health.register!

      route, _params = Tina4::Router.find_route("GET", "/health")
      expect(route).not_to be_nil

      # Dispatch the registered route's handler and assert it actually
      # produces the health payload — not merely that the route exists.
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/health",
        "QUERY_STRING" => "",
        "rack.input" => StringIO.new("")
      }
      request = Tina4::Request.new(env)
      response = Tina4::Response.new

      route.handler.call(request, response)

      expect(response.status).to eq(200)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["framework"]).to eq("tina4-ruby")
      expect(body["version"]).to eq(Tina4::VERSION)
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
