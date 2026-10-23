# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# RTC config + signalling require auth by default (ADR-0101, tina4-python#252).
#
# The /api/rtc/config route mints a fresh TURN credential on every call and the
# /ws/rtc/{room} signalling socket relays a call. Left public, anyone can use the
# operator's TURN server as a relay. Both are secured by default; an app that
# genuinely wants anonymous calling opts out with TINA4_RTC_REQUIRE_AUTH=false.
#
# Answer key: tina4-documentation/plan/v3/fixtures/rtc_auth_contract.json. NO
# MOCKS - a real Tina4::Realtime.mount registration, auth_required read straight
# off the registered route.

require "spec_helper"

RSpec.describe "RTC require-auth (ADR-0101)" do
  around(:each) do |example|
    prev = ENV["TINA4_RTC_REQUIRE_AUTH"]
    Tina4::Router.clear!
    example.run
    Tina4::Router.clear!
    ENV["TINA4_RTC_REQUIRE_AUTH"] = prev
  end

  def mount(value)
    if value.nil?
      ENV.delete("TINA4_RTC_REQUIRE_AUTH")
    else
      ENV["TINA4_RTC_REQUIRE_AUTH"] = value
    end
    Tina4::Realtime.mount(prefix: "/rtc-t", features: ["calls"])
  end

  def http_auth(path_contains)
    route = Tina4::Router.routes.find { |r| r.path.to_s.include?(path_contains) }
    raise "no HTTP route containing #{path_contains}" unless route

    route.auth_required
  end

  def ws_auth(path_contains)
    route = Tina4::Router.ws_routes.find { |r| r.path.to_s.include?(path_contains) }
    raise "no WS route containing #{path_contains}" unless route

    route.auth_required
  end

  it "config route requires auth by default" do
    mount(nil)
    expect(http_auth("api/rtc/config")).to be true
  end

  it "signalling socket requires auth by default" do
    mount(nil)
    expect(ws_auth("ws/rtc")).to be true
  end

  it "require auth false opens the config route" do
    mount("false")
    expect(http_auth("api/rtc/config")).to be false
  end

  it "require auth false opens the signalling socket" do
    mount("false")
    expect(ws_auth("ws/rtc")).to be false
  end

  it "require auth explicit true secures both" do
    mount("true")
    expect(http_auth("api/rtc/config")).to be true
    expect(ws_auth("ws/rtc")).to be true
  end

  it "only explicit falsey opens the route" do
    mount("yes-please")
    expect(http_auth("api/rtc/config")).to be true
  end
end
