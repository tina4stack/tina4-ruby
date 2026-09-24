# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Security headers on every response, from every entry point (ADR-0066).
#
# The runner for the three ADR-0066 invariants in
# tina4-documentation/plan/v3/fixtures/securityheaders_contract.json; the
# Python, PHP and Node suites carry the same case names.
#
#   * static files, the 404 and 405 fallbacks and the framework's own refusals
#     carry the canonical security header set (tina4-python #137);
#   * a header a route already set is kept - only missing headers are filled in;
#   * every Ruby entry point - app.rb (Tina4.initialize! + Tina4::WebServer),
#     Tina4.run! (production, Puma), config.ru under the real `puma` executable
#     and `tina4ruby serve` - attaches the security headers and CSRF and mounts
#     the configured SSO routes (tina4-python #134).
#
# NO MOCKS: each entry point boots the same project in its own REAL subprocess
# on a REAL port, and the SSO mount discovers a REAL local OpenID provider
# (spec/support/local_oidc_provider.rb) over HTTP at boot.

require "spec_helper"
require "net/http"
require "rbconfig"
require "socket"
require "tmpdir"
require "fileutils"
require "timeout"
require_relative "support/local_oidc_provider"

module SecurityHeadersEveryResponseContract
  CANONICAL = %w[x-frame-options x-content-type-options content-security-policy
                 referrer-policy x-xss-protection permissions-policy].freeze
  ROUTE_CSP = "default-src 'none'; img-src 'self'"
  ENTRIES = ["app.rb", "Tina4.run!", "config.ru", "tina4ruby serve"].freeze

  def self.free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def self.write_project(dir)
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    FileUtils.mkdir_p(File.join(dir, "src", "public"))
    File.write(File.join(dir, "src", "public", "hello.html"), "<!doctype html><title>static</title><p>static</p>")
    File.write(File.join(dir, "src", "routes", "secure_contract.rb"), <<~RUBY)
      Tina4::Router.get("/secure-contract/page") { |_request, response| response.html("<p>page</p>") }
      Tina4::Router.get("/secure-contract/own-headers") do |_request, response|
        response.header("Content-Security-Policy", #{ROUTE_CSP.inspect})
        response.header("X-Frame-Options", "DENY")
        response.html("<p>shaped by the route</p>")
      end
      Tina4::Router.post("/secure-contract/write") { |_request, response| response.json({ "written" => true }) }
    RUBY
    File.write(File.join(dir, "app.rb"), <<~RUBY)
      require "tina4"
      Tina4.initialize!(__dir__)
      app = Tina4::RackApp.new(root_dir: __dir__)
      Tina4::WebServer.new(app, host: "127.0.0.1", port: ENV["TINA4_PORT"].to_i).start
    RUBY
    File.write(File.join(dir, "run.rb"), "require \"tina4\"\nTina4.run!(__dir__)\n")
    File.write(File.join(dir, "config.ru"), <<~RUBY)
      require "tina4"
      Tina4.initialize!(__dir__)
      run Tina4::RackApp.new(root_dir: __dir__)
    RUBY
  end

  def self.command(entry, dir, port)
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

  def self.env(port, idp)
    {
      "TINA4_SSO_ISSUER" => idp.issuer, "TINA4_SSO_CLIENT_ID" => idp.client_id,
      "TINA4_SSO_CLIENT_SECRET" => idp.client_secret,
      "TINA4_SSO_REDIRECT_URI" => "http://127.0.0.1:#{port}/auth/callback",
      "TINA4_PORT" => port.to_s, "TINA4_HOST" => "127.0.0.1", "PORT" => nil, "HOST" => nil,
      "TINA4_CSRF" => "true", "TINA4_SECRET" => "secure-contract-secret-#{port}",
      "TINA4_DEBUG" => "false", "TINA4_LOG_LEVEL" => "NONE", "TINA4_SUPPRESS" => "true",
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_AI_PORT" => "true", "TINA4_NO_BROWSER" => "true",
      "TINA4_AUTO_MIGRATE" => "false", "TINA4_DATABASE_URL" => nil, "TINA4_CSP" => nil,
      "TINA4_FRAME_OPTIONS" => nil, "TINA4_PUBLIC_DIR" => nil
    }
  end

  def self.request(port, verb, path)
    Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 5) do |http|
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(verb)
      req = klass.new(path)
      unless verb == :get
        req.body = "{}"
        req["Content-Type"] = "application/json"
      end
      res = http.request(req)
      lowered = {}
      res.each_header { |key, value| lowered[key.downcase] = value }
      [res.code.to_i, lowered, res.body.to_s]
    end
  end
end

RSpec.describe "Security headers on every response, from every entry point (ADR-0066)" do
  contract = SecurityHeadersEveryResponseContract

  before(:all) do
    @idp = LocalOidcProvider.new(client_id: "tina4-secure-contract", client_secret: "secure-contract-sso").start
  end

  after(:all) { @idp&.stop }

  contract::ENTRIES.each do |entry|
    context "served by #{entry}" do
      before(:all) do
        @dir = Dir.mktmpdir("tina4-secure-contract")
        contract.write_project(@dir)
        @port = contract.free_port
        @log = File.join(@dir, "server.log")
        @pid = Process.spawn(contract.env(@port, @idp), *contract.command(entry, @dir, @port),
                             chdir: @dir, out: @log, err: @log, pgroup: true)
        deadline = Time.now + 30
        loop do
          status = begin
            contract.request(@port, :get, "/secure-contract/page").first
          rescue StandardError
            nil
          end
          break if status && status < 500
          raise "#{entry} never answered on #{@port}:\n#{File.read(@log) rescue ''}" if Process.waitpid(@pid, Process::WNOHANG) || Time.now > deadline

          sleep 0.2
        end
      end

      after(:all) do
        begin
          Process.kill("TERM", -@pid)
          Timeout.timeout(10) { Process.wait(@pid) }
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        rescue Timeout::Error
          Process.kill("KILL", -@pid) rescue nil
          Process.wait(@pid) rescue nil
        end
        FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
      end

      def expect_the_set(entry, label, response, statuses)
        status, headers, body = response
        expect(statuses).to include(status), "#{entry}: #{label} answered #{status}: #{body[0, 200]}"
        expect(contract_missing(headers)).to eq([]), "#{entry}: #{label} (#{status}) went out without these"
        expect(headers["x-content-type-options"]).to eq("nosniff")
      end

      def contract_missing(headers)
        SecurityHeadersEveryResponseContract::CANONICAL.reject { |name| headers.key?(name) }
      end

      it "a static file carries the security headers" do
        expect_the_set(entry, "a static file", contract.request(@port, :get, "/hello.html"), [200])
      end

      it "a 404 carries the security headers" do
        expect_the_set(entry, "the 404", contract.request(@port, :get, "/secure-contract/nowhere"), [404])
      end

      it "a 405 carries the security headers" do
        expect_the_set(entry, "the 405", contract.request(@port, :put, "/secure-contract/page"), [405])
      end

      it "a refusal carries the security headers" do
        expect_the_set(entry, "the refused anonymous write", contract.request(@port, :post, "/secure-contract/write"), [401, 403])
      end

      it "a header the route already set is not overwritten" do
        status, headers, = contract.request(@port, :get, "/secure-contract/own-headers")
        expect(status).to eq(200)
        expect(headers["content-security-policy"]).to eq(contract::ROUTE_CSP), "#{entry}: the route's own CSP was overwritten"
        expect(headers["x-frame-options"]).to eq("DENY"), "#{entry}: the route's own X-Frame-Options was overwritten"
        expect(headers["x-content-type-options"]).to eq("nosniff"), "#{entry}: a header the route did not set was not filled in"
      end

      it "every entry point attaches the security headers and csrf" do
        expect_the_set(entry, "a routed page", contract.request(@port, :get, "/secure-contract/page"), [200])
        status, _, body = contract.request(@port, :post, "/secure-contract/write")
        expect(status).to eq(403), "#{entry}: a token-less write got #{status}: #{body}"
        expect(body).to include("CSRF_INVALID")
      end

      it "every entry point mounts the sso routes" do
        status, headers, body = contract.request(@port, :get, "/auth/login")
        expect(status).to eq(302), "#{entry}: /auth/login got #{status}: #{body}"
        expect(headers["location"]).to start_with("#{@idp.issuer}/authorize?")
      end
    end
  end
end
