# frozen_string_literal: true

# Error-overlay conformance — dead-code removal, redaction, frame cap, self-throw guard.
#
# Feature 126. See OVERLAY-DEC-01..04 and
# tina4-documentation/plan/v3/fixtures/overlay_contract.json.
#
# Four rules, driven through the REAL dispatcher (Tina4::RackApp#call) with a real
# thrown 500. NO MOCKS.
#
#   1. WIRED PRODUCTION NO-LEAK (OVERLAY-DEC-01). render_production_error is deleted;
#      the real production 500 renders the generic errors/500 page with an empty
#      error_message (CWE-209). A real production 500 leaks neither the message nor
#      a backtrace. This replaces the old unit test of the never-invoked sibling.
#   2. REDACTION (OVERLAY-DEC-02). The dev overlay masks the Authorization / Cookie
#      headers (Rack: HTTP_AUTHORIZATION / HTTP_COOKIE) and password-like body keys.
#   3. FRAME CAP (OVERLAY-DEC-03). A deep recursive stack renders a bounded page.
#   4. SELF-THROW GUARD (OVERLAY-DEC-03). If the overlay render raises (an
#      unrenderable request value), the dispatch still returns a safe 500.
#
# Mutation-proved: make #redact return the value and case 2 goes RED; drop the
# MAX_FRAMES slice and case 3 goes RED; drop the rescue around the overlay in
# handle_500 and case 4 goes RED (the overlay throw escapes dispatch).
#
# Same case names in all four:
#   tina4-python/tests/test_overlay_contract.py
#   tina4-php/tests/OverlayContractTest.php
#   tina4-nodejs/test/overlayContract.test.ts

require "spec_helper"

# Secret VALUES as file-top constants (unique names — no RSpec global-constant
# collision), referenced by name below so the literal never sits in a stack frame's
# rendered source window (the overlay shows a source window per frame and this spec is
# on the stack). The redaction is about the REQUEST table, not the spec's own source.
OVERLAY_LEAK_MARKER = "SECRET-MARKER-do-not-leak-9f3a"
OVERLAY_AUTH_SECRET = "sekret-auth-71c2"
OVERLAY_COOKIE_SECRET = "sekret-cookie-4d8e"
OVERLAY_PASSWORD_SECRET = "hunter2-9a1f"

# A real request value whose #to_s raises — the "malformed edge" the overlay guard
# exists for. NOT a mock: the real overlay really fails on it.
class OverlayToSPoison
  def to_s
    raise "poison to_s exploded"
  end
end

RSpec.describe "Error overlay contract (feature 126)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_overlay_contract") }
  let(:app)     { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Events.clear
    @saved_debug = ENV.delete("TINA4_DEBUG")
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
    Tina4::Router.clear!
    Tina4::Events.clear
    if @saved_debug
      ENV["TINA4_DEBUG"] = @saved_debug
    else
      ENV.delete("TINA4_DEBUG")
    end
  end

  def mock_env(method, path, extra = {})
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "SERVER_NAME"    => "localhost",
      "SERVER_PORT"    => "7147",
      "rack.input"     => StringIO.new("")
    }.merge(extra)
  end

  # ── 1. wired production no-leak ────────────────────────────────────

  it "a wired production 500 does not leak the exception" do
    ENV["TINA4_DEBUG"] = "false"
    Tina4.get("/overlay-boom") { |_req, _res| raise OVERLAY_LEAK_MARKER }

    status, _headers, body_parts = app.call(mock_env("GET", "/overlay-boom"))
    body = body_parts.join

    expect(status).to eq(500)
    [OVERLAY_LEAK_MARKER, "error_overlay.rb", ".rb:", "in `"].each do |marker|
      expect(body).not_to include(marker),
                           "CWE-209 regression: production 500 body leaked #{marker.inspect}"
    end
  end

  # ── 2. redaction (dev) ─────────────────────────────────────────────

  it "the dev overlay redacts authorization and secret body fields" do
    ENV["TINA4_DEBUG"] = "true"
    Tina4.get("/overlay-secret") { |_req, _res| raise "handler exploded" }

    # The router hands the raw env to the overlay. HTTP_AUTHORIZATION / HTTP_COOKIE are
    # real Rack header keys; the body hash exercises the password-key path (the overlay
    # expands any Hash value).
    env = mock_env("GET", "/overlay-secret",
                   "HTTP_AUTHORIZATION" => "Bearer #{OVERLAY_AUTH_SECRET}",
                   "HTTP_COOKIE"        => "session=#{OVERLAY_COOKIE_SECRET}",
                   "tina4.overlay.body" => { "password" => OVERLAY_PASSWORD_SECRET, "username" => "alice" })
    _status, _headers, body_parts = app.call(env)
    html = body_parts.join

    # The overlay DID render the request section (proves redaction is masking, not
    # merely hiding the whole section):
    expect(html).to include("Request Details")
    expect(html).to include("alice")
    expect(html).to include("[redacted]")
    # ...but every secret is masked:
    [OVERLAY_AUTH_SECRET, OVERLAY_COOKIE_SECRET, OVERLAY_PASSWORD_SECRET].each do |secret|
      expect(html).not_to include(secret), "dev overlay leaked a secret: #{secret.inspect}"
    end
  end

  # ── 3. frame cap ───────────────────────────────────────────────────

  def deep_recurse(n)
    raise "deep stack marker" if n <= 0

    deep_recurse(n - 1)
  end

  it "a deep recursive stack renders a frame capped page" do
    exc =
      begin
        deep_recurse(5000)
      rescue SystemStackError, StandardError => e
        e
      end

    html = Tina4::ErrorOverlay.render_error_overlay(exc)
    frame_blocks = html.scan('<div style="margin-bottom:16px;">').length
    expect(frame_blocks).to be <= 50,
                            "frame count #{frame_blocks} exceeds the cap 50 — unbounded render"
    expect(html).to include("more stack frames hidden")
  end

  # ── 4. self-throw guard ────────────────────────────────────────────

  it "a throwing overlay render still returns a safe 500" do
    ENV["TINA4_DEBUG"] = "true"
    Tina4.get("/overlay-poison") { |_req, _res| raise "handler boom marker" }

    # A Hash value whose element #to_s raises — the overlay throws while building the
    # request table, and the guard must still serve a safe 500.
    env = mock_env("GET", "/overlay-poison",
                   "tina4.overlay.body" => { "note" => OverlayToSPoison.new })
    status, _headers, body_parts = app.call(env)
    body = body_parts.join

    expect(status).to eq(500), "dispatch must still serve a 500 when the overlay throws"
    expect(body).not_to include("poison to_s exploded")
    expect(body).not_to include("handler boom marker")
  end
end
