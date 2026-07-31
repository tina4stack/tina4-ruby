# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# CORS policy conformance - deny by default, no wildcard+credentials, Vary: Origin.
#
# Feature 10 (CORS middleware) conformance suite. See ADR-0018.
#
# Three rules, each pinned positive AND negative, driven through the REAL Rack
# app (Tina4::RackApp#call) with real Rack envs - the same object Puma calls.
# NO MOCKS.
#
# 1. DENY BY DEFAULT. With TINA4_CORS_ORIGINS unset, no
#    Access-Control-Allow-Origin is emitted at all and the browser's own CORS
#    check blocks the request. "*" still works, but must be asked for.
#
# 2. NEVER ACAO: * WITH CREDENTIALS. The Fetch Standard's CORS check treats "*"
#    as a literal once the request's credentials mode is "include", so the pair
#    is rejected by every browser and a server emitting it is broken. Ruby
#    emitted exactly this pair before 2026-07-31 - it was the only one of the
#    four without the guard.
#
# 3. VARY: ORIGIN WHENEVER ACAO IS COMPUTED FROM THE REQUEST. RFC 9110 s12.5.5:
#    a Vary field name list tells cache recipients they "MUST NOT use this
#    response to satisfy a later request unless the later request has the same
#    values for the listed header fields as the original request". Emitted on
#    an allow-list MISS as well as a match. NOT emitted for a constant "*".
#
# Access-Control-Allow-Methods / -Allow-Headers are static configured lists
# here, never derived from the request's Access-Control-Request-* headers, so
# those field names deliberately do NOT appear in Vary.
#
# Same case names in all four:
#   tina4-python/tests/test_cors_policy_conformance.py
#   tina4-php/tests/CorsPolicyConformanceTest.php
#   tina4-nodejs/test/corsPolicyConformance.test.ts
RSpec.describe "CORS policy conformance" do
  GOOD_ORIGIN = "https://good.example"
  EVIL_ORIGIN = "https://evil.example"

  let(:tmp_dir) { Dir.mktmpdir("tina4_cors_policy") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    Tina4::Router.get("/api/thing") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
    configure(nil, nil)
  end

  after(:each) do
    Tina4::Router.clear!
    configure(nil, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def configure(origins, credentials)
    origins.nil?     ? ENV.delete("TINA4_CORS_ORIGINS")     : ENV["TINA4_CORS_ORIGINS"] = origins
    credentials.nil? ? ENV.delete("TINA4_CORS_CREDENTIALS") : ENV["TINA4_CORS_CREDENTIALS"] = credentials
    Tina4::CorsMiddleware.reset!
  end

  # Drive a REAL request through the REAL Rack app.
  def request(method, origin, extra_headers = {})
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => "/api/thing", "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new(""), "rack.url_scheme" => "http"
    }.merge(extra_headers)
    env["HTTP_ORIGIN"] = origin unless origin.nil?
    env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"] = "GET" if method == "OPTIONS"
    status, headers, _body = app.call(env)
    @last_status = status
    headers.transform_keys { |k| k.to_s.downcase }
  end

  attr_reader :last_status

  # ---------------------------------------------------------- deny by default

  it "deny by default emits no allow origin" do
    configure(nil, nil)
    headers = request("GET", EVIL_ORIGIN)
    expect(headers["access-control-allow-origin"]).to be_nil,
      "an unconfigured app must not hand out Access-Control-Allow-Origin"
  end

  it "deny by default still serves non browser clients" do
    # CORS is a BROWSER mechanism. curl and server-to-server are unaffected.
    configure(nil, nil)
    headers = request("GET", nil)
    expect(last_status).to eq(200)
    expect(headers["access-control-allow-origin"]).to be_nil
  end

  it "explicit wildcard still allows any origin" do
    # The default changed; the capability did not.
    configure("*", nil)
    expect(request("GET", EVIL_ORIGIN)["access-control-allow-origin"]).to eq("*")
  end

  it "preflight status is unchanged when denied" do
    # Denying must not change the status code - the browser does the blocking.
    configure(nil, nil)
    denied = request("OPTIONS", EVIL_ORIGIN)
    denied_status = last_status

    configure(GOOD_ORIGIN, nil)
    request("OPTIONS", GOOD_ORIGIN)

    expect(denied_status).to eq(204)
    expect(last_status).to eq(denied_status)
    expect(denied["access-control-allow-origin"]).to be_nil
  end

  # ------------------------------------------------ wildcard never + credentials

  it "wildcard never pairs with credentials" do
    configure("*", "true")
    headers = request("GET", EVIL_ORIGIN)
    expect(headers["access-control-allow-origin"]).to eq("*")
    expect(headers["access-control-allow-credentials"]).to be_nil,
      "Access-Control-Allow-Origin: * with Access-Control-Allow-Credentials: true is " \
      "rejected by every browser - the framework must never emit the pair"
  end

  it "wildcard never pairs with credentials on a preflight" do
    # Ruby's ACTUAL shipped bug was on the PREFLIGHT path, where the
    # credentials header was written unconditionally from config.
    configure("*", "true")
    headers = request("OPTIONS", EVIL_ORIGIN)
    expect(headers["access-control-allow-origin"]).to eq("*")
    expect(headers["access-control-allow-credentials"]).to be_nil
  end

  it "allow list match reflects origin and credentials" do
    # The positive case: a named origin DOES get credentials.
    configure("#{GOOD_ORIGIN},https://other.example", "true")
    headers = request("GET", GOOD_ORIGIN)
    expect(headers["access-control-allow-origin"]).to eq(GOOD_ORIGIN)
    expect(headers["access-control-allow-credentials"]).to eq("true")
  end

  it "allow list miss emits no allow origin" do
    configure(GOOD_ORIGIN, "true")
    headers = request("GET", EVIL_ORIGIN)
    expect(headers["access-control-allow-origin"]).to be_nil
    expect(headers["access-control-allow-credentials"]).to be_nil
  end

  # ------------------------------------------------------------------ Vary

  it "allow list always varies on origin" do
    configure(GOOD_ORIGIN, nil)
    expect(request("GET", GOOD_ORIGIN)["vary"]).to eq("Origin"), "match must vary"

    configure(GOOD_ORIGIN, nil)
    expect(request("GET", EVIL_ORIGIN)["vary"]).to eq("Origin"),
      "a MISS must vary too - otherwise a shared cache can serve this no-ACAO " \
      "response to an origin that should have been allowed"
  end

  it "constant wildcard does not vary on origin" do
    # A constant '*' is identical for everyone; Vary would only fragment caches.
    configure("*", nil)
    expect(request("GET", EVIL_ORIGIN)["vary"]).to be_nil
  end

  it "vary origin does not clobber an existing vary" do
    # Appending, not overwriting - a pre-existing Vary must survive.
    configure(GOOD_ORIGIN, nil)
    headers = { "vary" => "Accept-Encoding" }
    Tina4::CorsMiddleware.apply_headers(headers, "HTTP_ORIGIN" => GOOD_ORIGIN)
    expect(headers["vary"]).to eq("Accept-Encoding, Origin")

    Tina4::CorsMiddleware.apply_headers(headers, "HTTP_ORIGIN" => GOOD_ORIGIN)
    expect(headers["vary"]).to eq("Accept-Encoding, Origin"), "idempotent"
  end

  # -------------------------------------- the response path, not just preflight

  it "cors headers are emitted on the actual response not only the preflight" do
    # THE RUBY HEADLINE BUG. CorsMiddleware.apply_headers was never called from
    # the dispatch path - only preflight_response was - so a preflight answered
    # "yes you may" and the real request came back with no ACAO and was blocked
    # by the browser. Cross-origin access did not work in ANY configuration.
    configure(GOOD_ORIGIN, nil)

    preflight = request("OPTIONS", GOOD_ORIGIN)
    expect(preflight["access-control-allow-origin"]).to eq(GOOD_ORIGIN)

    actual = request("GET", GOOD_ORIGIN)
    expect(actual["access-control-allow-origin"]).to eq(GOOD_ORIGIN),
      "the preflight allowed this origin but the real response carried no " \
      "Access-Control-Allow-Origin, so the browser blocks it anyway"
  end
end
