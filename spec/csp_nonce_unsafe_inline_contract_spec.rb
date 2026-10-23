# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# CSP nonce respects a user's 'unsafe-inline' (ADR-0100, refines ADR-0088).
#
# A browser ignores 'unsafe-inline' in any directive that also lists a nonce
# (CSP Level 2+). Since 3.13.143 the framework appended its per-response nonce to
# script-src/style-src unconditionally - including an app's own TINA4_CSP - so an
# app that deliberately allowed inline through 'unsafe-inline' had it silently
# blocked (tina4-php#330). The rule now: a directive (present, or derived from
# default-src) that already carries 'unsafe-inline' gets NO nonce; the app's
# explicit choice wins. The strict default policy is unchanged and still nonced.
#
# Answer key: tina4-documentation/plan/v3/fixtures/securityheaders_contract.json,
# invariant csp-nonce-respects-unsafe-inline. NO MOCKS - the real injector, a
# pure string transform.

require "spec_helper"

RSpec.describe "CSP nonce respects unsafe-inline (ADR-0100)" do
  NONCE = "abc123"
  TOKEN = "'nonce-abc123'"

  def directive(csp, name)
    csp.split(";").map(&:strip).find { |p| p.split(/\s+/, 2)[0].downcase == name } || ""
  end

  it "explicit unsafe-inline script-src keeps unsafe-inline and gets no nonce" do
    out = Tina4::Csp.inject_nonce_into_csp("default-src 'self'; script-src 'self' 'unsafe-inline'", NONCE)
    expect(directive(out, "script-src")).to include("'unsafe-inline'")
    expect(directive(out, "script-src")).not_to include(TOKEN)
  end

  it "explicit unsafe-inline style-src keeps unsafe-inline and gets no nonce" do
    out = Tina4::Csp.inject_nonce_into_csp("default-src 'self'; style-src 'self' 'unsafe-inline'", NONCE)
    expect(directive(out, "style-src")).to include("'unsafe-inline'")
    expect(directive(out, "style-src")).not_to include(TOKEN)
  end

  it "unsafe-inline default-src does not spawn a nonced directive" do
    out = Tina4::Csp.inject_nonce_into_csp("default-src 'self' 'unsafe-inline'", NONCE)
    expect(out).not_to include(TOKEN)
    expect(directive(out, "script-src")).to eq("")
    expect(directive(out, "style-src")).to eq("")
  end

  it "mixed unsafe-inline script but strict style nonces only style" do
    out = Tina4::Csp.inject_nonce_into_csp("default-src 'self'; script-src 'self' 'unsafe-inline'", NONCE)
    expect(directive(out, "script-src")).not_to include(TOKEN)
    expect(directive(out, "style-src")).to include(TOKEN)
  end

  it "strict default policy still gets the nonce" do
    out = Tina4::Csp.inject_nonce_into_csp("default-src 'self'", NONCE)
    expect(directive(out, "script-src")).to include(TOKEN)
    expect(directive(out, "style-src")).to include(TOKEN)
  end

  it "explicit non-unsafe-inline directive still gets the nonce" do
    out = Tina4::Csp.inject_nonce_into_csp("default-src 'self'; script-src 'self' https://cdn.example", NONCE)
    expect(directive(out, "script-src")).to include(TOKEN)
  end
end
