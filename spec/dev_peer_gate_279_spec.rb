# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Regression for tina4-ruby#279: the dev-admin peer gate behind a non-loopback
# peer (a Docker dev box publishes its port, so the browser's requests arrive
# from the container-network gateway, never loopback).
#
# No mocks. The gate is driven through the REAL handler, Tina4::DevAdmin
# .handle_request(env) (the same surface spec/dev_admin_spec.rb uses), with a
# genuine non-loopback REMOTE_ADDR; the CIDR matcher is a pure function.
#
# Expected (what 3.13.136 did and the gate must restore):
#   - /__dev/toolbar.css and /__dev/toolbar.js load for any peer (static, no
#     secrets) - they must not sit behind the peer gate.
#   - /__dev stays 403 for a non-loopback peer by default (the security boundary).
#   - TINA4_DEV_ALLOWED_PEERS admits that raw peer to /__dev (explicit opt-in).
#   - the toolbar is NOT injected for a viewer the gate would refuse.

require "spec_helper"

RSpec.describe "Dev-admin peer gate (#279)" do
  GATEWAY = "172.22.0.1" # a Docker-network gateway: non-loopback

  around do |example|
    saved = ENV.to_h.slice("TINA4_DEBUG", "TINA4_DEV_ALLOWED_PEERS", "TINA4_HOST")
    ENV["TINA4_DEBUG"] = "true"
    ENV.delete("TINA4_DEV_ALLOWED_PEERS")
    ENV.delete("TINA4_HOST")
    example.run
  ensure
    %w[TINA4_DEBUG TINA4_DEV_ALLOWED_PEERS TINA4_HOST].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  def env_for(path, remote_ip, host: "localhost")
    { "REMOTE_ADDR" => remote_ip, "PATH_INFO" => path, "REQUEST_METHOD" => "GET", "HTTP_HOST" => host }
  end

  # ── ip_in_cidr?: pure ──────────────────────────────────────────────────────

  it "matches IPs and CIDRs across families" do
    expect(Tina4::DevAdmin.ip_in_cidr?("172.22.0.1", "172.22.0.1")).to be true   # bare IP
    expect(Tina4::DevAdmin.ip_in_cidr?("172.22.0.1", "172.16.0.0/12")).to be true # Docker range
    expect(Tina4::DevAdmin.ip_in_cidr?("192.168.88.148", "192.168.0.0/16")).to be true
    expect(Tina4::DevAdmin.ip_in_cidr?("10.0.0.5", "172.16.0.0/12")).to be false
    expect(Tina4::DevAdmin.ip_in_cidr?("fd00::1", "fd00::/8")).to be true
    expect(Tina4::DevAdmin.ip_in_cidr?("::ffff:172.22.0.1", "172.16.0.0/12")).to be true # mapped -> v4
    expect(Tina4::DevAdmin.ip_in_cidr?("172.22.0.1", "fd00::/8")).to be false # family mismatch
    expect(Tina4::DevAdmin.ip_in_cidr?("not-an-ip", "172.16.0.0/12")).to be false
  end

  # ── the gate, through the real handler ─────────────────────────────────────

  it "serves the static toolbar assets to a non-loopback peer" do
    css = Tina4::DevAdmin.handle_request(env_for("/__dev/toolbar.css", GATEWAY))
    js  = Tina4::DevAdmin.handle_request(env_for("/__dev/toolbar.js", GATEWAY))
    expect(css[0]).to eq(200), "toolbar.css must load for any peer, got #{css[0]}"
    expect(js[0]).to eq(200),  "toolbar.js must load for any peer, got #{js[0]}"
  end

  it "refuses the dashboard for a non-loopback peer by default" do
    status, _headers, body = Tina4::DevAdmin.handle_request(env_for("/__dev", GATEWAY))
    expect(status).to eq(403)
    expect(body.first).to include("non-loopback peer")
  end

  it "admits the raw peer to the dashboard with TINA4_DEV_ALLOWED_PEERS" do
    ENV["TINA4_DEV_ALLOWED_PEERS"] = "172.16.0.0/12"
    status, = Tina4::DevAdmin.handle_request(env_for("/__dev", GATEWAY))
    expect(status).to eq(200), "the opt-in CIDR must admit the Docker gateway"
  end

  it "does not admit a peer outside the opt-in range" do
    ENV["TINA4_DEV_ALLOWED_PEERS"] = "10.0.0.0/8"
    status, = Tina4::DevAdmin.handle_request(env_for("/__dev", GATEWAY))
    expect(status).to eq(403)
  end

  # ── injection decision ─────────────────────────────────────────────────────

  it "withholds the toolbar from a refused viewer, allows it for an admitted one" do
    expect(Tina4::DevAdmin.dev_toolbar_allowed?(env_for("/", GATEWAY))).to be false
    expect(Tina4::DevAdmin.dev_toolbar_allowed?(env_for("/", "127.0.0.1"))).to be true
    ENV["TINA4_DEV_ALLOWED_PEERS"] = "172.16.0.0/12"
    expect(Tina4::DevAdmin.dev_toolbar_allowed?(env_for("/", GATEWAY))).to be true
  end
end
