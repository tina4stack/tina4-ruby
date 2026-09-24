# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# SSRF guard (ADR-0084) - the Ruby runner for ssrf_guard_contract.json.
#
# spec/fixtures/ssrf_guard_contract.json is a copy of
# tina4-documentation/plan/v3/fixtures/ssrf_guard_contract.json. Every address in
# the fixture is fed to the real classifier; the request cases drive the real Api
# client and the real Push sender against a REAL loopback TCPServer - no mocks.
# 127.0.0.1 is blocked by default, so the listener is reached via the explicit
# allow-list; the opt-out has a positive twin.

require "spec_helper"
require "json"
require "socket"
require "tina4/api"
require "tina4/push"

FIXTURE = JSON.parse(File.read(File.expand_path("fixtures/ssrf_guard_contract.json", __dir__)))

# A tiny real HTTP listener on 127.0.0.1 that answers 200/201, or 302s to a
# fixed target. No web server gem - a raw TCPServer speaking minimal HTTP.
class SsrfTestServer
  attr_reader :port

  def initialize(redirect_to: nil)
    @redirect_to = redirect_to
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @running = true
    @thread = Thread.new { serve_loop }
  end

  def stop
    @running = false
    @thread.kill if @thread&.alive?
    @server.close unless @server.closed?
  end

  private

  def serve_loop
    while @running
      client = begin
        @server.accept
      rescue StandardError
        nil
      end
      break if client.nil?

      handle(client)
    end
  end

  def handle(client)
    method = "GET"
    while (line = client.gets)
      method = line.split(" ", 2).first if line.start_with?(/GET|POST|PUT|DELETE|PATCH/)
      break if line == "\r\n"
    end
    if @redirect_to
      client.write("HTTP/1.1 302 Found\r\nLocation: #{@redirect_to}\r\nConnection: close\r\n\r\n")
    elsif method == "POST"
      client.write("HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    else
      body = '{"ok":true}'
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end
    client.close
  rescue StandardError
    client.close rescue nil
  end
end

RSpec.describe "SSRF guard (ADR-0084)" do
  before(:each) { ENV.delete("TINA4_ALLOW_PRIVATE_REQUESTS") }

  # ── SSRF-CLASSIFY ──────────────────────────────────────────────────────────

  it "blocks loopback by default" do
    expect(Tina4::Ssrf.blocked_address?("127.0.0.1")).to be true
    expect(Tina4::Ssrf.blocked_address?("::1")).to be true
  end

  it "blocks cloud metadata address" do
    expect(Tina4::Ssrf.blocked_address?("169.254.169.254")).to be true
  end

  it "blocks private and cgnat ranges" do
    FIXTURE["addresses"].each do |case_|
      expect(Tina4::Ssrf.blocked_address?(case_["ip"])).to eq(case_["blocked"]), case_["ip"]
    end
  end

  it "allows a public address" do
    expect(Tina4::Ssrf.blocked_address?("8.8.8.8")).to be false
    expect(Tina4::Ssrf.blocked_address?("2606:4700:4700::1111")).to be false
  end

  it "rejects a non http scheme" do
    FIXTURE["schemes"].reject { |s| s["allowed"] }.each do |case_|
      expect { Tina4::Ssrf.guard_url!("#{case_['scheme']}://example.com/x") }
        .to raise_error(Tina4::SsrfError)
    end
  end

  # ── SSRF-REQUEST ───────────────────────────────────────────────────────────

  it "api blocks request to loopback by default" do
    server = SsrfTestServer.new
    begin
      resp = Tina4::API.new("http://127.0.0.1:#{server.port}").get("/")
      expect(resp.status).to eq(0)
      expect(resp.error).to include("TINA4_ALLOW_PRIVATE_REQUESTS")
    ensure
      server.stop
    end
  end

  it "api allows request with opt out" do
    server = SsrfTestServer.new
    begin
      ENV["TINA4_ALLOW_PRIVATE_REQUESTS"] = "true"
      resp = Tina4::API.new("http://127.0.0.1:#{server.port}").get("/")
      expect(resp.status).to eq(200)

      # and the explicit allow-list works with the opt-out OFF
      ENV.delete("TINA4_ALLOW_PRIVATE_REQUESTS")
      allowed = Tina4::API.new("http://127.0.0.1:#{server.port}", allow_hosts: ["127.0.0.1"]).get("/")
      expect(allowed.status).to eq(200)
    ensure
      server.stop
    end
  end

  it "api blocks redirect hop to private" do
    server = SsrfTestServer.new(redirect_to: "http://169.254.169.254/latest/meta-data/")
    begin
      # The loopback listener is allowed by the allow-list; its 302 target
      # (169.254.169.254) is NOT, so it is refused at the hop.
      resp = Tina4::API.new("http://127.0.0.1:#{server.port}", allow_hosts: ["127.0.0.1"]).get("/")
      expect(resp.status).to eq(0)
      expect(resp.error).to include("169.254.169.254")
    ensure
      server.stop
    end
  end

  it "web push blocked to private endpoint unless opted in" do
    keys = Tina4::Push.generate_vapid_keys
    subscription = {
      "endpoint" => "http://169.254.169.254/push/AAA",
      "keys" => { "p256dh" => Tina4::Push.generate_vapid_keys["publicKey"], "auth" => "AAAAAAAAAAAAAAAAAAAAAA" }
    }
    push = Tina4::Push.new(subject: "mailto:ops@example.com",
                           public_key: keys["publicKey"], private_key: keys["privateKey"])
    expect { push.send(subscription, { "title" => "hi" }) }
      .to raise_error(Tina4::PushError, /TINA4_ALLOW_PRIVATE_REQUESTS/)
  end
end
