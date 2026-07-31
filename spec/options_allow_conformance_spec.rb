# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Every successful OPTIONS response carries Allow (RFC 9110 s9.3.7).
#
# There are TWO OPTIONS paths and they used to answer different questions:
#
#   bare OPTIONS  (no Origin)  - protocol introspection. Link checkers,
#                                monitoring probes, `curl -X OPTIONS`.
#   CORS preflight (Origin)    - a browser asking "may I send this?".
#
# A preflight IS an OPTIONS response, so it should carry Allow too. Measured
# 2026-07-31: Ruby, Python and Node all dropped it on a preflight, and PHP
# dropped it on BOTH as soon as CorsMiddleware was registered.
#
# Allow and Access-Control-Allow-Methods are NOT interchangeable and this suite
# asserts both: Allow is what the RESOURCE supports (derived from the router),
# ACAM is what the CORS POLICY permits cross-origin (a configured static list,
# as in every mainstream CORS library). A policy naming DELETE on a GET-only
# route is still a 405, so a client that reads only ACAM is misled.
#
# NO MOCKS: a real RackApp over a real temp directory, real routes.
#
# Same case names in all four frameworks:
#   tina4-python/tests/test_options_allow_conformance.py
#   tina4-php/tests/OptionsAllowConformanceTest.php
#   tina4-nodejs/test/optionsAllowConformance.test.ts
RSpec.describe "OPTIONS Allow conformance" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_options_allow") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  PREFLIGHT = {
    "ORIGIN" => "https://example.com",
    "ACCESS-CONTROL-REQUEST-METHOD" => "POST"
  }.freeze

  before(:each) do
    Tina4::Router.clear!
    # ADR-0014 made the CORS default deny; this suite is about the CORS
    # POLICY headers, so it declares the policy it used to inherit.
    ENV["TINA4_CORS_ORIGINS"] = "*"
    Tina4::CorsMiddleware.reset!
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    Tina4::Router.get("/only-get") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
    Tina4::Router.post("/only-get") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
  end

  after(:each) do
    ENV.delete("TINA4_CORS_ORIGINS")
    Tina4::CorsMiddleware.reset!
    Tina4::Router.clear!
    FileUtils.rm_rf(tmp_dir)
  end

  def options(headers = {})
    env = {
      "REQUEST_METHOD" => "OPTIONS", "PATH_INFO" => "/only-get", "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147", "rack.input" => StringIO.new("")
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    status, response_headers, = app.call(env)
    [status, response_headers]
  end

  def header(headers, name)
    headers.find { |k, _| k.to_s.downcase == name.downcase }&.last
  end

  it "a bare options carries allow" do
    status, headers = options
    expect(status).to eq(204)
    expect(header(headers, "allow")).to eq("GET, POST, HEAD, OPTIONS")
  end

  it "a cors preflight also carries allow" do
    # The gap this suite was written for.
    status, headers = options(PREFLIGHT)
    expect(status).to eq(204)
    expect(header(headers, "allow")).to eq("GET, POST, HEAD, OPTIONS"),
                                          "a CORS preflight returned 204 without Allow"
  end

  it "a real preflight is still answered by cors" do
    # NEGATIVE: the fix must not break CORS itself.
    _status, headers = options(PREFLIGHT)
    expect(header(headers, "access-control-allow-origin")).not_to be_nil
    expect(header(headers, "access-control-allow-methods")).not_to be_nil
  end

  it "allow describes the resource not the policy" do
    # Allow describes the RESOURCE; ACAM describes the POLICY. They are
    # different values on purpose, and conflating them is the bug this pins:
    # the policy names methods the route does not implement.
    _status, headers = options(PREFLIGHT)
    allow = header(headers, "allow").to_s
    acam = header(headers, "access-control-allow-methods").to_s

    expect(allow).not_to include("DELETE"),
                         "Allow named a method the route does not implement"
    expect(acam).to include("DELETE"),
                    "the policy list is expected to be broader than the resource"
    expect(allow).not_to eq(acam)
  end
end
