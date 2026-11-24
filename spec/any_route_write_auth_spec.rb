# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "tmpdir"
require "fileutils"

# A bare any() route keeps writes secure by default (ADR-0019).
#
# Every route answers GET publicly and needs a token for POST, PUT, PATCH and
# DELETE unless it says otherwise. Router.any registers ONE "ANY" route, and
# Route set auth_required from the method alone, so an ANY route was public for
# every method: Router.any("/x") took anonymous writes Router.post("/x")
# refused. tina4-php and tina4-nodejs register any() as one route per method,
# so their writes were already gated; this is the same contract for Ruby.
#
# REAL requests through the in-process TestClient (the same
# RackApp.enforce_route_auth the live server runs) with REAL tokens. NO MOCKS.
RSpec.describe "any() routes keep writes secure by default" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_any_auth") }
  let(:client) { Tina4::TestClient.new }
  writes = %w[post put patch delete]

  before(:each) do
    Tina4::Router.clear!
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    # HS256 with TINA4_SECRET: an empty keys dir means no RSA keys, so tokens
    # are HMAC-signed (the default for an app that never generated keys).
    Tina4::Auth.instance_variable_set(:@keys_dir, tmp_dir)
    @saved_env = %w[TINA4_API_KEY TINA4_CSRF TINA4_SECRET].to_h { |k| [k, ENV[k]] }
    ENV.delete("TINA4_API_KEY")
    ENV["TINA4_SECRET"] = "any-write-auth-secret-0123456789"
    # CSRF is a separate gate; switch it off so the status is the auth gate's.
    ENV["TINA4_CSRF"] = "false"

    ok = ->(_request, response) { response.json({ ok: true }) }
    Tina4::Router.any("/anyauth/bare", &ok)
    Tina4::Router.any("/anyauth/open", &ok).no_auth
    Tina4::Router.any("/anyauth/locked", &ok).secure
    Tina4::Router.group("/anyauth/grp") { any("/bare") { |_req, res| res.json({ ok: true }) } }
    Tina4.any("/anyauth/dsl") { |_req, res| res.json({ ok: true }) }
  end

  after(:each) do
    Tina4::Router.clear!
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    FileUtils.rm_rf(tmp_dir)
  end

  def call(method, path, token: false)
    headers = token ? { "Authorization" => "Bearer #{Tina4::Auth.get_token({ "sub" => "u" })}" } : {}
    case method
    when "get" then client.get(path, headers: headers)
    when "delete" then client.delete(path, headers: headers)
    else client.public_send(method, path, json: {}, headers: headers)
    end
  end

  %w[/anyauth/bare /anyauth/grp/bare /anyauth/dsl].each do |path|
    it "answers GET #{path} publicly" do
      expect(call("get", path).status).to eq(200)
    end

    writes.each do |method|
      it "needs a token for #{method.upcase} #{path}" do
        expect(call(method, path).status).to eq(401), "anonymous #{method.upcase} #{path} was let through"
        expect(call(method, path, token: true).status).to eq(200)
      end
    end
  end

  (["get"] + writes).each do |method|
    it "keeps an any() route opened with .no_auth public for #{method.upcase}" do
      expect(call(method, "/anyauth/open").status).to eq(200)
    end

    it "needs a token for #{method.upcase} on an any() route marked .secure" do
      expect(call(method, "/anyauth/locked").status).to eq(401)
      expect(call(method, "/anyauth/locked", token: true).status).to eq(200)
    end
  end
end
