# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Every REFUSAL carries the security headers when SecurityHeadersMiddleware is
# attached - not just the 200s (found in tina4-php: a CSRF 403 went out with
# no CSP, nosniff or X-Frame-Options).
#
# In Ruby the header middleware is ordinary post-match global middleware, and
# Tina4.initialize! attaches CsrfMiddleware BEFORE it. A middleware that halts
# stops the before-pass, so every refusal produced ahead of the security hook
# - the CSRF 403, a legacy auth_handler 403, a pre-match middleware's refusal
# - left without the headers, while the auth-gate 401 (which merges the
# response headers built so far) happened to keep them.
#
# NO MOCKS: a REAL Tina4::WebServer on a REAL port, REAL HTTP requests, the
# REAL CsrfMiddleware / SecurityHeadersMiddleware attached the way
# Tina4.initialize! attaches them.

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"

# A pre-match global middleware that refuses everything carrying the header -
# the shape a rate limiter or IP block list takes. Defined once at top level
# (not inside the describe block) so it cannot clobber anything.
module SecurityRefusalSpec
  class PreMatchBlocker
    def self.pre_match?
      true
    end

    def self.before_block(request, response)
      return [request, response] unless request.headers["x-block-me"]

      response.json({ "error" => "blocked" }, 429)
    end
  end
end

RSpec.describe "Security headers on middleware and auth refusals" do
  def refusal_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def refusal_request(verb, path, headers = {})
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      req = verb == :post ? Net::HTTP::Post.new(path) : Net::HTTP::Get.new(path)
      headers.each { |key, value| req[key] = value }
      if verb == :post
        req.body = "{}"
        req["Content-Type"] = "application/json"
      end
      res = http.request(req)
      lowered = {}
      res.each_header { |key, value| lowered[key.downcase] = value }
      [res.code.to_i, lowered, res.body.to_s]
    end
  end

  def expect_security_headers(headers, what)
    expect(headers["content-security-policy"]).to eq("default-src 'self'"), "#{what}: no CSP"
    expect(headers["x-content-type-options"]).to eq("nosniff"), "#{what}: no nosniff"
    expect(headers["x-frame-options"]).to eq("SAMEORIGIN"), "#{what}: no X-Frame-Options"
  end

  before(:all) do
    keys = %w[TINA4_CSRF TINA4_SECRET TINA4_CSP TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT]
    @saved_env = keys.to_h { |key| [key, ENV[key]] }
    ENV["TINA4_SECRET"] = "refusal-secret"
    ENV["TINA4_CSP"] = "default-src 'self'"
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    @dir = Dir.mktmpdir("tina4-refusals")
    @port = refusal_free_port
    @server = Tina4::WebServer.new(Tina4::RackApp.new(root_dir: @dir), host: "127.0.0.1", port: @port)
    @thread = Thread.new { @server.start }
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", @port).close
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise "server never came up" if Time.now > deadline

      sleep 0.05
      retry
    end
  end

  after(:all) do
    @server&.stop
    @thread&.join(5)
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # spec_helper clears Router + Middleware before each example. Re-attach in
  # Tina4.initialize!'s order: CSRF (when enabled) first, then the headers.
  def attach_like_initialize(csrf:)
    ENV["TINA4_CSRF"] = csrf ? "true" : "false"
    Tina4::CsrfMiddleware.attach_from_env
    Tina4::SecurityHeadersMiddleware.attach
  end

  before(:each) do
    Tina4::Router.get("/refusal/page") { |_request, response| response.html("<p>ok</p>") }
    Tina4::Router.post("/refusal/write") { |_request, response| response.json({ "written" => true }) }
    Tina4::Router.add("GET", "/refusal/legacy", ->(_request, response) { response.html("<p>never</p>") },
                      auth_handler: ->(_env) { false })
  end

  after(:each) { Tina4::Middleware.clear! }

  it "a CSRF 403 carries CSP, nosniff and X-Frame-Options" do
    attach_like_initialize(csrf: true)
    status, headers, body = refusal_request(:post, "/refusal/write")
    expect(status).to eq(403)
    expect(body).to include("CSRF_INVALID")
    expect_security_headers(headers, "CSRF 403")
  end

  it "an auth-gate 401 (secured write, no token) carries them" do
    attach_like_initialize(csrf: false)
    status, headers, = refusal_request(:post, "/refusal/write")
    expect(status).to eq(401)
    expect_security_headers(headers, "auth 401")
  end

  it "a legacy auth_handler 403 carries them" do
    attach_like_initialize(csrf: false)
    status, headers, = refusal_request(:get, "/refusal/legacy")
    expect(status).to eq(403)
    expect_security_headers(headers, "auth_handler 403")
  end

  it "a pre-match middleware refusal carries them" do
    Tina4::Middleware.use(SecurityRefusalSpec::PreMatchBlocker)
    attach_like_initialize(csrf: false)
    status, headers, body = refusal_request(:get, "/refusal/page", "X-Block-Me" => "1")
    expect(status).to eq(429)
    expect(body).to include("blocked")
    expect_security_headers(headers, "pre-match 429")
  end

  it "a 404 carries them too" do
    attach_like_initialize(csrf: false)
    status, headers, = refusal_request(:get, "/refusal/nowhere")
    expect(status).to eq(404)
    expect_security_headers(headers, "404")
  end

  it "the success path is unchanged, and a detached middleware still means no headers (controls)" do
    attach_like_initialize(csrf: true)
    status, headers, = refusal_request(:get, "/refusal/page")
    expect(status).to eq(200)
    expect_security_headers(headers, "200")

    Tina4::Middleware.clear!
    status, headers, = refusal_request(:post, "/refusal/write")
    expect(status).to eq(401)
    expect(headers).not_to have_key("content-security-policy")
  end
end
