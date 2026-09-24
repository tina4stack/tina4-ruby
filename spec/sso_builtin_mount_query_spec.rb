# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# The BUILT-IN SSO routes (Tina4::Sso.mount_configured) complete a real sign-in
# and honour return_to.
#
# Found while proving tina4-python #135 parity: Sso#callback read the provider's
# code/state from request.params, and the mounted /auth/login and /auth/logout
# read return_to from request.params. Tina4::Request#params carries ROUTE path
# params only (REQ-PARAM-POLLUTION) - the query string is request.query - so:
#
#   * GET /auth/callback never saw code/state and ALWAYS failed with
#     "OIDC callback state is invalid or already consumed": the configuration-
#     first SSO mount could not sign anybody in;
#   * return_to was silently ignored on login and on logout.
#
# The Python master reads `request.query` in all three places (sso.py callback
# and mount_configured). Nothing is hand-passed here: the routes are the
# framework's own, driven by a browser walk over real HTTP.
#
# NO MOCKS: a REAL local OpenID provider (spec/support/local_oidc_provider.rb,
# a stdlib TCPServer on a real port), a REAL Tina4::WebServer, REAL file sessions.

require "spec_helper"
require "json"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require_relative "support/local_oidc_provider"

RSpec.describe "Built-in SSO mount: /auth/login, /auth/callback and /auth/logout read the query string" do
  def sso_mount_boot(port)
    server = Tina4::WebServer.new(Tina4::RackApp.new(root_dir: @dir), host: "127.0.0.1", port: port)
    thread = Thread.new { server.start }
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", port).close
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise "server never came up on port #{port}" if Time.now > deadline

      sleep 0.05
      retry
    end
    [server, thread]
  end

  def sso_mount_request(url, verb: :get, cookie: nil, bearer: nil)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
      req = verb == :post ? Net::HTTP::Post.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
      req["Cookie"] = cookie if cookie
      req["Authorization"] = "Bearer #{bearer}" if bearer
      http.request(req)
    end
  end

  # A server may absolutise a relative Location (RFC 7231 allows either), so
  # the redirect target is compared by path.
  def sso_mount_target(response)
    location = URI(response["location"].to_s)
    location.query ? "#{location.path}?#{location.query}" : location.path
  end

  def sso_mount_app(path)
    "http://127.0.0.1:#{@port}#{path}"
  end

  before(:all) do
    keys = %w[TINA4_SESSION_PATH TINA4_SESSION_BACKEND TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT TINA4_SECRET
              TINA4_SSO_ISSUER TINA4_SSO_CLIENT_ID TINA4_SSO_CLIENT_SECRET TINA4_SSO_REDIRECT_URI]
    @saved_env = keys.to_h { |key| [key, ENV[key]] }
    @dir = Dir.mktmpdir("tina4-sso-mount")
    @provider = LocalOidcProvider.new(client_id: "tina4-mount", client_secret: "mount-secret",
                                      subject: "user-mount").start
    @port = LocalOidcProvider.free_port

    ENV["TINA4_SESSION_PATH"] = File.join(@dir, "sessions")
    ENV.delete("TINA4_SESSION_BACKEND")
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    ENV["TINA4_SECRET"] = "sso-mount-secret"
    ENV["TINA4_SSO_ISSUER"] = @provider.issuer
    ENV["TINA4_SSO_CLIENT_ID"] = @provider.client_id
    ENV["TINA4_SSO_CLIENT_SECRET"] = @provider.client_secret
    ENV["TINA4_SSO_REDIRECT_URI"] = sso_mount_app("/auth/callback")

    @server, @thread = sso_mount_boot(@port)
  end

  after(:all) do
    @server&.stop
    @thread&.join(5)
    @provider&.stop
    Tina4::Sso.instance_variable_set(:@mounted, false)
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # spec_helper clears the router before every example; the mount's one-shot
  # flag must be reset with it, exactly as a fresh boot would find it.
  before(:each) do
    Tina4::Sso.instance_variable_set(:@mounted, false)
    expect(Tina4::Sso.mount_configured).to be(true)
  end

  # Walk the browser from the built-in login to the built-in callback.
  def sso_mount_sign_in(return_to)
    login = sso_mount_request(sso_mount_app("/auth/login?#{URI.encode_www_form(return_to: return_to)}"))
    expect(login.code.to_i).to eq(302)
    expect(login["location"]).to start_with("#{@provider.issuer}/authorize?")
    cookie = login["set-cookie"].to_s.split(";").first
    expect(cookie).to start_with("#{Tina4::Session.cookie_name}=")

    authorize = sso_mount_request(login["location"])
    expect(authorize.code.to_i).to eq(302)
    expect(authorize["location"]).to start_with(sso_mount_app("/auth/callback?code="))

    callback = sso_mount_request(authorize["location"], cookie: cookie)
    [callback, callback["set-cookie"].to_s.split(";").first || cookie]
  end

  it "GET /auth/callback completes a real sign-in and redirects to the return_to given to /auth/login" do
    callback, = sso_mount_sign_in("/dashboard")
    expect(callback.code.to_i).to eq(302), "the built-in callback failed: #{callback.code} #{callback.body}"
    expect(sso_mount_target(callback)).to eq("/dashboard")
  end

  it "a callback that did not come from the provider (no code/state) is still refused" do
    login = sso_mount_request(sso_mount_app("/auth/login"))
    cookie = login["set-cookie"].to_s.split(";").first
    refused = sso_mount_request(sso_mount_app("/auth/callback"), cookie: cookie)
    expect(refused.code.to_i).to eq(400)
    expect(refused.body).to include("SSO_CALLBACK_FAILED")
  end

  it "an unsafe return_to on /auth/login falls back to /" do
    callback, = sso_mount_sign_in("https://evil.example/steal")
    expect(callback.code.to_i).to eq(302)
    expect(sso_mount_target(callback)).to eq("/")
  end

  it "POST /auth/logout ends the session and redirects to its return_to" do
    _, cookie = sso_mount_sign_in("/dashboard")
    token = Tina4::Auth.get_token({ "sub" => "user-mount" })
    logout = sso_mount_request(sso_mount_app("/auth/logout?return_to=%2Fsigned-out"),
                               verb: :post, cookie: cookie, bearer: token)
    expect(logout.code.to_i).to eq(302), "logout failed: #{logout.code} #{logout.body}"
    expect(sso_mount_target(logout)).to eq("/signed-out")
  end
end
