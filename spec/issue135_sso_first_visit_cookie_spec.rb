# frozen_string_literal: true
#
# Issue #135 parity (tina4-python #135): on a visitor's FIRST request,
# Sso.login stores the pending state (state, nonce, PKCE verifier) in a NEW
# session. Python's save stage skipped a new session whose all() was empty -
# and all() hides _tina4_sso / _tina4_sso_pending - so no session cookie was
# sent, the IdP redirected back to a callback with no session, and sign-in
# failed for every first-time visitor.
#
# Ruby is NOT affected: DispatchPipeline#session_save saves any session the
# request touched and sends its cookie whenever the id differs from the one the
# browser sent - it never asks whether all() is empty. This spec LOCKS THAT IN
# with a complete, real sign-in:
#
#   * a REAL local OpenID provider (spec/support/local_oidc_provider.rb, a stdlib
#     TCPServer on a real port) serving discovery, /authorize, a PKCE-checked /token and
#     /introspect;
#   * a REAL Tina4::WebServer whose routes call Tina4::Sso#login / #callback;
#   * a browser walk over real HTTP starting with NO cookie.
#
# NO MOCKS: every hop is a real socket; Sso talks to the provider over
# Net::HTTP exactly as it does in production.

require "spec_helper"
require "json"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require_relative "support/local_oidc_provider"

RSpec.describe "Issue #135: SSO login on a first visit sends the session cookie" do
  def issue135_boot_app(port)
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

  def issue135_get(url, cookie = nil)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(uri.request_uri)
      req["Cookie"] = cookie if cookie
      http.request(req)
    end
  end

  before(:all) do
    @saved_env = %w[TINA4_SESSION_PATH TINA4_SESSION_BACKEND TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT].to_h { |k| [k, ENV[k]] }
    @dir = Dir.mktmpdir("tina4-issue135")
    ENV["TINA4_SESSION_PATH"] = File.join(@dir, "sessions")
    ENV.delete("TINA4_SESSION_BACKEND")
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"

    @idp = LocalOidcProvider.new(client_id: "tina4-issue135", client_secret: "issue135-secret",
                                 subject: "user-135").start
    @issuer = @idp.issuer
    @app_port = LocalOidcProvider.free_port
    @app, @app_thread = issue135_boot_app(@app_port)
  end

  after(:all) do
    @app&.stop
    @app_thread&.join(5)
    @idp&.stop
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before(:each) do
    sso = Tina4::Sso.new(issuer: @issuer, client_id: @idp.client_id, client_secret: @idp.client_secret,
                         redirect_uri: "http://127.0.0.1:#{@app_port}/issue135/callback")
    Tina4::Router.get("/issue135/login") do |request, response|
      url = sso.login(request, "/dashboard")
      # The ONLY thing in this brand-new session is the SSO pending state, which
      # Session#all hides - exactly the case Python's save stage skipped.
      response.header("X-Issue135-All-Empty", request.session.all.empty?.to_s)
      response.redirect(url)
    end
    Tina4::Router.get("/issue135/callback") do |request, response|
      result = sso.callback(request)
      response.json({ "subject" => result.dig("identity", "subject"), "return_to" => result["return_to"] })
    rescue Tina4::SsoError => e
      response.json({ "error" => e.message }, 400)
    end
  end

  it "a first visit (no cookie) gets a session cookie holding only SSO state, and the callback signs in" do
    login = issue135_get("http://127.0.0.1:#{@app_port}/issue135/login")
    expect(login.code.to_i).to eq(302)
    expect(login["X-Issue135-All-Empty"]).to eq("true")
    set_cookie = login["set-cookie"].to_s
    expect(set_cookie).to start_with("#{Tina4::Session.cookie_name}="),
                          "the first-visit login response carried no session cookie: #{set_cookie.inspect}"
    cookie = set_cookie.split(";").first
    expect(login["location"]).to start_with("#{@issuer}/authorize?")

    # The browser goes to the provider, which sends it back with code + state.
    authorize = issue135_get(login["location"])
    expect(authorize.code.to_i).to eq(302)
    expect(authorize["location"]).to start_with("http://127.0.0.1:#{@app_port}/issue135/callback?")

    callback = issue135_get(authorize["location"], cookie)
    expect(callback.code.to_i).to eq(200), "callback failed: #{callback.body}"
    expect(JSON.parse(callback.body)).to eq({ "subject" => "user-135", "return_to" => "/dashboard" })
  end

  it "the callback fails without that cookie - it is what carries the pending state (control)" do
    login = issue135_get("http://127.0.0.1:#{@app_port}/issue135/login")
    authorize = issue135_get(login["location"])

    callback = issue135_get(authorize["location"])
    expect(callback.code.to_i).to eq(400)
    expect(JSON.parse(callback.body)["error"]).to include("state is invalid")
  end
end
