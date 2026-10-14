# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "cgi"

# errors/302.twig puts redirect_url into both an <a href> and a
# <meta http-equiv="refresh"> url. A tainted value must not be able to run
# script (javascript:/data:/vbscript:) or bounce the user off-site via a
# scheme-relative //host target. The template collapses anything that is not a
# same-site relative path or an explicit http/https URL to "/".
#
# Real Frond render against the shipped framework template — no mocks. Case
# names match the sibling regression in tina4-php/tests/RedirectTemplateSafetyTest.php.
RSpec.describe "errors/302.twig redirect safety" do
  let(:frond) { Tina4::Frond.new(template_dir: "lib/tina4/templates") }

  def rendered_urls(redirect_url)
    html = frond.render("errors/302.twig", { "redirect_url" => redirect_url, "title" => "t" })
    [html[/<a href="([^"]*)"/, 1], html[/url=([^"]*)">/, 1]]
  end

  dangerous = [
    "javascript:alert(1)",
    "JAVASCRIPT:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "vbscript:msgbox(1)",
    "//evil.example.com/pwn",
    "",
    "evilsite",
  ]

  dangerous.each do |url|
    it "neutralises a dangerous redirect: #{url.inspect}" do
      href, meta = rendered_urls(url)
      expect(href).to eq("/")
      expect(meta).to eq("/")
    end
  end

  safe = {
    "/dashboard?x=1" => "/dashboard?x=1",
    "/" => "/",
    "https://tina4.com/ok" => "https://tina4.com/ok",
    "http://tina4.com/ok" => "http://tina4.com/ok",
  }

  safe.each do |url, expected|
    it "preserves a safe redirect: #{url.inspect}" do
      escaped = CGI.escapeHTML(expected)
      href, meta = rendered_urls(url)
      expect(href).to eq(escaped)
      expect(meta).to eq(escaped)
    end
  end

  it "escapes a relative path carrying metacharacters instead of breaking out" do
    href, = rendered_urls('/search?q="><img src=x onerror=alert(1)>')
    expect(href).to start_with("/search?q=")
    expect(href).not_to include("<img")
    expect(href).not_to include('"')
    expect(href).to include("&quot;")
  end
end
