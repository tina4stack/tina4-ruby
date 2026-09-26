# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Issue #134 parity (tina4-python #134): in Python, run() attached the
# security-header middleware and (with TINA4_CSRF=true) CsrfMiddleware, while
# the alternate server entry asgi() attached neither - so the same app served
# by uvicorn shipped no CSP/nosniff/frame headers and accepted cross-site
# forged writes.
#
# Ruby is NOT affected: both attaches live in Tina4.initialize!
# (lib/tina4.rb), which every entry point calls before it builds the Rack app,
# and the middleware registry is process-wide, so every server that dispatches
# through Tina4::RackApp#call runs the same chain. This spec LOCKS THAT IN by
# booting the SAME project through each real entry point, each in its own REAL
# subprocess on a REAL port:
#
#   * app.rb        - the scaffolded entry: Tina4.initialize! + Tina4::WebServer
#   * Tina4.run!    - production mode (TINA4_DEBUG=false), i.e. Puma
#   * config.ru     - the Rack entry, served by the real `puma` executable
#   * tina4ruby serve - the CLI
#
# and asserting, over HTTP, that each sends the security headers and refuses a
# token-less write with 403 CSRF_INVALID while a Bearer-authenticated write
# still succeeds (so the 403 is CSRF, not the auth gate).
#
# SSO too: with TINA4_SSO_* configured, Tina4.initialize! mounts
# /auth/login, /auth/callback and /auth/logout (Sso.mount_configured), so every
# entry point must serve them. Each subprocess is pointed at a REAL local
# OpenID provider (spec/support/local_oidc_provider.rb) running in this
# process; discovery happens over real HTTP at boot.

require "spec_helper"
require "json"
require "net/http"
require "rbconfig"
require "socket"
require "tmpdir"
require "fileutils"
require "timeout"
require_relative "support/local_oidc_provider"

RSpec.describe "Issue #134: every server entry point sends security headers and enforces CSRF" do
  def issue134_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def issue134_project(dir)
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    File.write(File.join(dir, "src", "routes", "issue134.rb"), <<~RUBY)
      Tina4::Router.get("/issue134/page") { |_request, response| response.html("<p>page</p>") }
      Tina4::Router.get("/issue134/token") { |_request, response| response.json({ "token" => Tina4::Auth.get_token({ "sub" => "issue134" }) }) }
      Tina4::Router.post("/issue134/write") { |_request, response| response.json({ "written" => true }) }
    RUBY
    File.write(File.join(dir, "app.rb"), <<~RUBY)
      require "tina4"
      Tina4.initialize!(__dir__)
      app = Tina4::RackApp.new(root_dir: __dir__)
      Tina4::WebServer.new(app, host: "127.0.0.1", port: ENV["TINA4_PORT"].to_i).start
    RUBY
    File.write(File.join(dir, "run.rb"), <<~RUBY)
      require "tina4"
      Tina4.run!(__dir__)
    RUBY
    File.write(File.join(dir, "config.ru"), <<~RUBY)
      require "tina4"
      Tina4.initialize!(__dir__)
      run Tina4::RackApp.new(root_dir: __dir__)
    RUBY
  end

  def issue134_command(entry, dir, port)
    lib = File.expand_path("../lib", __dir__)
    case entry
    when "app.rb" then [RbConfig.ruby, "-I#{lib}", File.join(dir, "app.rb")]
    when "Tina4.run!" then [RbConfig.ruby, "-I#{lib}", File.join(dir, "run.rb")]
    when "config.ru" then [RbConfig.ruby, "-I#{lib}", Gem.bin_path("puma", "puma"),
                           "-b", "tcp://127.0.0.1:#{port}", "-t", "0:4", File.join(dir, "config.ru")]
    when "tina4ruby serve" then [RbConfig.ruby, "-I#{lib}", File.expand_path("../exe/tina4ruby", __dir__),
                                 "serve", "--port", port.to_s, "--host", "127.0.0.1"]
    end
  end

  before(:all) do
    @issue134_idp = LocalOidcProvider.new(client_id: "tina4-issue134", client_secret: "issue134-sso").start
  end

  after(:all) { @issue134_idp&.stop }

  def issue134_env(port)
    {
      "TINA4_SSO_ISSUER" => @issue134_idp.issuer, "TINA4_SSO_CLIENT_ID" => @issue134_idp.client_id,
      "TINA4_SSO_CLIENT_SECRET" => @issue134_idp.client_secret,
      "TINA4_SSO_REDIRECT_URI" => "http://127.0.0.1:#{port}/auth/callback",
      "TINA4_PORT" => port.to_s, "TINA4_HOST" => "127.0.0.1", "PORT" => nil, "HOST" => nil,
      "TINA4_CSRF" => "true", "TINA4_SECRET" => "issue134-entrypoints-secret-0123456789abcdef-#{port}",
      "TINA4_DEBUG" => "false", "TINA4_LOG_LEVEL" => "NONE", "TINA4_SUPPRESS" => "true",
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_AI_PORT" => "true", "TINA4_NO_BROWSER" => "true",
      "TINA4_AUTO_MIGRATE" => "false", "TINA4_DATABASE_URL" => nil, "TINA4_CSP" => "default-src 'self'"
    }
  end

  def issue134_wait(port, pid, log)
    deadline = Time.now + 30
    loop do
      begin
        res = Net::HTTP.start("127.0.0.1", port, open_timeout: 1, read_timeout: 2) { |http| http.get("/issue134/page") }
        return if res.code.to_i < 500
      rescue StandardError
        nil
      end
      if Process.waitpid(pid, Process::WNOHANG) || Time.now > deadline
        raise "server never answered on #{port}:\n#{File.read(log) rescue ''}"
      end

      sleep 0.2
    end
  end

  def issue134_request(port, verb, path, headers = {})
    Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 5) do |http|
      req = verb == :post ? Net::HTTP::Post.new(path) : Net::HTTP::Get.new(path)
      headers.each { |key, value| req[key] = value }
      req.body = "{}" if verb == :post
      req["Content-Type"] = "application/json" if verb == :post
      res = http.request(req)
      lowered = {}
      res.each_header { |key, value| lowered[key.downcase] = value }
      [res.code.to_i, lowered, res.body.to_s]
    end
  end

  ["app.rb", "Tina4.run!", "config.ru", "tina4ruby serve"].each do |entry|
    it "#{entry}: security headers, CSRF refuses a token-less write, SSO routes are mounted" do
      Dir.mktmpdir("tina4-issue134") do |dir|
        issue134_project(dir)
        port = issue134_free_port
        log = File.join(dir, "server.log")
        pid = Process.spawn(issue134_env(port), *issue134_command(entry, dir, port),
                            chdir: dir, out: log, err: log, pgroup: true)
        begin
          issue134_wait(port, pid, log)

          status, headers, = issue134_request(port, :get, "/issue134/page")
          expect(status).to eq(200)
          expect(headers["content-security-policy"]).to eq("default-src 'self'")
          expect(headers["x-content-type-options"]).to eq("nosniff")
          expect(headers["x-frame-options"]).to eq("SAMEORIGIN")

          # A cross-site forged write: no form token, no Bearer. CSRF must refuse
          # it BEFORE the auth gate, so the answer is 403 CSRF_INVALID, not 401.
          status, _, body = issue134_request(port, :post, "/issue134/write")
          expect(status).to eq(403), "#{entry}: a token-less write got #{status}: #{body}"
          expect(body).to include("CSRF_INVALID")

          # Positive control: an API client with a valid Bearer JWT passes CSRF
          # and the auth gate, so the 403 above really was CSRF.
          _, _, token_body = issue134_request(port, :get, "/issue134/token")
          token = JSON.parse(token_body)["token"]
          status, _, body = issue134_request(port, :post, "/issue134/write", "Authorization" => "Bearer #{token}")
          expect(status).to eq(200), "#{entry}: an authenticated write got #{status}: #{body}"
          expect(JSON.parse(body)).to eq({ "written" => true })

          # The configured SSO mount: login sends the browser to the provider,
          # the callback answers (and refuses a request carrying no state).
          status, headers, body = issue134_request(port, :get, "/auth/login?return_to=%2Fhome")
          expect(status).to eq(302), "#{entry}: /auth/login got #{status}: #{body}"
          expect(headers["location"]).to start_with("#{@issue134_idp.issuer}/authorize?")
          status, _, body = issue134_request(port, :get, "/auth/callback")
          expect(status).to eq(400), "#{entry}: /auth/callback got #{status}: #{body}"
          expect(body).to include("SSO_CALLBACK_FAILED")
        ensure
          begin
            Process.kill("TERM", -pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Timeout.timeout(10) { Process.wait(pid) }
          rescue Timeout::Error
            Process.kill("KILL", -pid) rescue nil
            Process.wait(pid) rescue nil
          rescue Errno::ECHILD
            nil
          end
        end
      end
    end
  end
end
