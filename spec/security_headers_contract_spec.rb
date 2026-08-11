# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Security headers conformance - secure-by-default register + HTTPS-guarded HSTS.
#
# Feature 36. See SECHDR-DEC-01/02 and
# tina4-documentation/plan/v3/fixtures/securityheaders_contract.json.
#
# Two rules, driven through the REAL Rack app (Tina4::RackApp#call) with real Rack
# envs - the same object Puma calls. NO MOCKS.
#
# 1. SECURE-BY-DEFAULT. Tina4::SecurityHeadersMiddleware.attach - the SAME call
#    Tina4.initialize! makes at boot - registers it in the default chain, so a
#    default app response carries the canonical header set with byte-identical
#    VALUES to Python/PHP/Node, and CSP is default-src 'self'. Before SECHDR-DEC-01
#    the middleware was never registered, so a default app had none of these.
#
# 2. HSTS IS HTTPS-ONLY. Strict-Transport-Security is emitted only when TINA4_HSTS
#    is set AND the request is HTTPS (x-forwarded-proto honoured); ABSENT on plain
#    HTTP even with TINA4_HSTS set.
#
# Mutation-proved: unregister the middleware and the canonical-set case goes RED;
# drop the HTTPS guard and the plain-http HSTS case goes RED.
#
# Same case names in all four:
#   tina4-python/tests/test_security_headers_contract.py
#   tina4-php/tests/SecurityHeadersContractTest.php
#   tina4-nodejs/test/securityHeadersContract.test.ts
RSpec.describe "Security headers conformance" do
  # The canonical set every framework emits, byte-identical values (compared
  # case-insensitively - HTTP header names are case-insensitive).
  let(:canonical) do
    {
      "x-frame-options" => "SAMEORIGIN",
      "x-content-type-options" => "nosniff",
      "content-security-policy" => "default-src 'self'",
      "referrer-policy" => "strict-origin-when-cross-origin",
      "x-xss-protection" => "0",
      "permissions-policy" => "camera=(), microphone=(), geolocation=()"
    }
  end
  let(:hsts_value) { "31536000" }

  let(:tmp_dir) { Dir.mktmpdir("tina4_sec_headers") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    clear_env
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    Tina4::Router.get("/sec-probe") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
    # The SAME registration Tina4.initialize! performs at boot - secure-by-default.
    Tina4::SecurityHeadersMiddleware.attach
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    clear_env
    FileUtils.rm_rf(tmp_dir)
  end

  def clear_env
    %w[TINA4_HSTS TINA4_CSP TINA4_FRAME_OPTIONS TINA4_REFERRER_POLICY
       TINA4_PERMISSIONS_POLICY TINA4_CSRF].each { |k| ENV.delete(k) }
  end

  # Drive a REAL request through the REAL Rack app; return lower-cased headers.
  def request(https: false)
    env = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/sec-probe", "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new(""), "rack.url_scheme" => "http"
    }
    # A TLS-terminating proxy forwards plain HTTP to the app with this header;
    # Request.secure_scheme? honours it. This is how HTTPS is expressed.
    env["HTTP_X_FORWARDED_PROTO"] = "https" if https
    _status, headers, _body = app.call(env)
    headers.transform_keys { |k| k.to_s.downcase }
  end

  # ---------------------------------------------------- secure-by-default set

  it "a default app response carries the canonical security header set" do
    headers = request
    canonical.each do |name, value|
      expect(headers[name]).to eq(value),
        "default app must emit #{name}: #{value} (SECHDR-OFF-BY-DEFAULT regression)"
    end
    # The middleware IS in the default chain - a real registration, not a
    # per-test hand-wire a real app would not do.
    expect(Tina4::Middleware.post_match_middleware).to include(Tina4::SecurityHeadersMiddleware)
    # HSTS must NOT be emitted by default (TINA4_HSTS unset).
    expect(headers["strict-transport-security"]).to be_nil
  end

  it "csp defaults to default src self" do
    expect(request["content-security-policy"]).to eq("default-src 'self'")
  end

  # ------------------------------------------------------- HSTS HTTPS-guarded

  it "hsts is present on an https request" do
    ENV["TINA4_HSTS"] = hsts_value
    expect(request(https: true)["strict-transport-security"])
      .to eq("max-age=#{hsts_value}; includeSubDomains")
  end

  it "hsts is absent on a plain http request" do
    # The guard: even with TINA4_HSTS set, a plain-HTTP request gets NO HSTS.
    # Dropping the scheme guard (emit on any scheme) turns this red.
    ENV["TINA4_HSTS"] = hsts_value
    expect(request(https: false)["strict-transport-security"]).to be_nil,
      "HSTS on plain HTTP is downgrade-protection on an unencrypted scheme - guard it"
  end
end
