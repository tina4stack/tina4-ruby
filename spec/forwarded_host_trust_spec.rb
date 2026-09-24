# frozen_string_literal: true

# Medium security finding F6 — X-Forwarded-Host must only be honoured when the
# raw socket peer is a trusted proxy (TINA4_TRUSTED_PROXIES).
#
# An untrusted client can otherwise forge X-Forwarded-Host and control the
# absolute request.url the app builds — the base for password-reset links,
# cache keys and open-redirect targets. The existing trusted-proxy gate covered
# X-Forwarded-For only; this pins the same rule for the host. Case names match
# the sibling regressions in tina4-nodejs/test/forwardedHostTrust.test.ts,
# tina4-python/tests/test_forwarded_host_trust.py and
# tina4-php/tests/ForwardedHostTrustTest.php.
#
# Real Tina4::Request built from a real Rack env with a real socket peer. No mocks.
require "spec_helper"
require "stringio"

RSpec.describe "X-Forwarded-Host trust (F6)" do
  def rack_env(headers: {})
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/reset-link",
      "QUERY_STRING" => "",
      "HTTP_HOST" => "127.0.0.1",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.input" => StringIO.new("")
    }
    headers.each { |k, v| env[k] = v }
    env
  end

  after do
    ENV.delete("TINA4_TRUSTED_PROXIES")
  end

  def request_url(forwarded_host)
    Tina4::Request.new(rack_env(headers: { "HTTP_X_FORWARDED_HOST" => forwarded_host })).url
  end

  it "forwarded host ignored from an untrusted peer" do
    ENV.delete("TINA4_TRUSTED_PROXIES")
    expect(request_url("evil.com")).not_to include("evil.com")
  end

  it "forwarded host honoured from a trusted proxy" do
    ENV["TINA4_TRUSTED_PROXIES"] = "127.0.0.1/8"
    expect(request_url("app.example.com")).to include("app.example.com")
  end
end
