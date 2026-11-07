# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# #342 — the auth-gate 401 and a throwing middleware's 500 go through the SAME
# negotiated error renderer as 404/403/500 (ERR-DEC-02).
#
# The defect: a browser that hit a protected route without a valid token, or a
# route whose middleware hook threw, got a raw JSON body instead of the HTML
# error PAGE every other framework error already negotiated. Fixed: a browser
# gets errors/{401,500}.twig; an API client gets the JSON envelope
# {error, code, message, status, request_id}. The 500 keeps CWE-209.
#
# Driven through the REAL front controller via Tina4::TestClient — no mocks.
# Same case names in all four:
#   tina4-python/tests/test_error_negotiation_401_500.py
#   tina4-php/tests/ErrorNegotiation401Middleware500Test.php
#   tina4-nodejs/test/errorNegotiation401Middleware500.test.ts
require "spec_helper"

ERRNEG342_SECRET = "ERRNEG342-secret-stack-detail-do-not-leak"

# A class middleware whose before* hook throws — the #342 500 path.
class ErrNeg342ThrowingMiddleware
  def self.before_explode(_request, _response)
    raise "middleware exploded: #{ERRNEG342_SECRET}"
  end
end

RSpec.describe "#342 error negotiation — 401 gate + middleware 500" do
  before do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Log.clear_request_id
    ENV["TINA4_SECRET"] = "err-neg-342-secret-0123456789abcdef"
    ENV.delete("TINA4_API_KEY")
    ENV.delete("TINA4_DEBUG")
  end

  after do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Log.clear_request_id
    ENV.delete("TINA4_SECRET")
  end

  # ----------------------------------------------------- 401 auth gate

  context "the secured-route 401" do
    before do
      # POST is auth-required by default (secure-by-default).
      Tina4::Router.post("/errneg342-secure") { |_req, res| res.call({ secret: true }, 201) }
    end

    it "gives a browser the HTML 401 page" do
      r = Tina4::TestClient.new.post("/errneg342-secure", json: { x: 1 }, headers: { "Accept" => "text/html" })
      expect(r.status).to eq(401)
      expect(r.headers["content-type"]).to include("text/html")
      expect(r.body).to include("error-code")
      expect(r.body).to include(">401<")
    end

    it "gives an API client the JSON envelope" do
      r = Tina4::TestClient.new.post("/errneg342-secure", json: { x: 1 }, headers: { "Accept" => "application/json" })
      expect(r.status).to eq(401)
      expect(r.headers["content-type"]).to include("application/json")
      body = r.json
      expect(body["error"]).to be(true)
      expect(body["code"]).to eq("UNAUTHORIZED")
      expect(body["status"]).to eq(401)
      expect(body["request_id"]).not_to be_nil
    end
  end

  # --------------------------------------------- middleware-throw 500

  context "a throwing before-middleware" do
    before do
      Tina4::Router.get("/errneg342-boom", middleware: [ErrNeg342ThrowingMiddleware]) do |_req, res|
        res.call({ never: true }, 200)
      end
    end

    it "gives a browser the HTML 500 page without the exception text" do
      r = Tina4::TestClient.new.get("/errneg342-boom", headers: { "Accept" => "text/html" })
      expect(r.status).to eq(500)
      expect(r.headers["content-type"]).to include("text/html")
      expect(r.body).to include("\"error-code\">500<")
      expect(r.body).not_to include(ERRNEG342_SECRET) # CWE-209
    end

    it "gives an API client the JSON envelope without the exception text" do
      r = Tina4::TestClient.new.get("/errneg342-boom", headers: { "Accept" => "application/json" })
      expect(r.status).to eq(500)
      expect(r.headers["content-type"]).to include("application/json")
      body = r.json
      expect(body["error"]).to be(true)
      expect(body["code"]).to eq("INTERNAL_SERVER_ERROR")
      expect(body["status"]).to eq(500)
      expect(body["request_id"]).not_to be_nil
      expect(JSON.generate(body)).not_to include(ERRNEG342_SECRET) # CWE-209
    end
  end
end
