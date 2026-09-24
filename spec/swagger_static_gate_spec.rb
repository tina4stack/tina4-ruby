# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# Lock-in: the BUNDLED Swagger UI static assets must honour the swagger gate.
#
# Regression this pins down
# -------------------------
# The framework ships the Swagger UI as static files under
# lib/tina4/public/swagger/ (index.html + oauth2-redirect.html). Static files
# are resolved by try_static INDEPENDENTLY of the gated /swagger handler, so
# before the fix a production server still served the Swagger UI on:
#
#   /swagger/index.html            -> 200 (direct file)
#   /swagger/oauth2-redirect.html  -> 200 (direct file)
#
# even with swagger disabled -- silently bypassing the documented
# TINA4_SWAGGER_ENABLED / TINA4_DEBUG switch. A bare /swagger (and /swagger/)
# was already intercepted by the gated handler, which is exactly why the leak
# stayed hidden: testing only /swagger looked clean.
#
# Real files on disk, the real try_static, real env vars. No doubles.

require "spec_helper"
require "uri"
require "stringio"

RSpec.describe "Swagger bundled-asset gate" do
  FRAMEWORK_PUBLIC = File.expand_path("../lib/tina4/public", __dir__)

  # The shipped assets that made up the leak surface.
  SWAGGER_ASSETS = %w[swagger/index.html swagger/oauth2-redirect.html].freeze

  # Request paths that MUST be gated.
  GATED_PATHS = %w[/swagger /swagger/ /swagger/index.html /swagger/oauth2-redirect.html].freeze

  # A bundled asset that is NOT swagger, to prove the gate is surgical.
  CONTROL_PATH = "/favicon.ico"

  let(:app) { Tina4::RackApp.new }

  def with_env(pairs)
    previous = {}
    pairs.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # GUARD: without the real files on disk the negative example below could pass
  # vacuously (nothing to serve means nothing to leak) and would keep passing
  # even if the gate were deleted.
  it "actually ships the swagger assets (else the negative example proves nothing)" do
    SWAGGER_ASSETS.each do |asset|
      expect(File.file?(File.join(FRAMEWORK_PUBLIC, asset)))
        .to be(true), "#{asset} missing from #{FRAMEWORK_PUBLIC}"
    end
    expect(File.file?(File.join(FRAMEWORK_PUBLIC, "favicon.ico"))).to be(true)
  end

  it "NEGATIVE: blocks every bundled swagger asset path when swagger is disabled" do
    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "false") do
      GATED_PATHS.each do |path|
        expect(app.send(:try_static, path))
          .to be_nil, "#{path} served the bundled Swagger UI with swagger disabled"
      end
    end
  end

  it "POSITIVE: still serves the bundled swagger assets when swagger is enabled" do
    with_env("TINA4_SWAGGER_ENABLED" => "true", "TINA4_DEBUG" => "true") do
      %w[/swagger/index.html /swagger/oauth2-redirect.html].each do |path|
        expect(app.send(:try_static, path))
          .not_to be_nil, "#{path} did not serve with swagger enabled"
      end
    end
  end

  it "falls back to TINA4_DEBUG when TINA4_SWAGGER_ENABLED is unset" do
    with_env("TINA4_SWAGGER_ENABLED" => nil, "TINA4_DEBUG" => "false") do
      expect(app.send(:try_static, "/swagger/index.html")).to be_nil
    end
    with_env("TINA4_SWAGGER_ENABLED" => nil, "TINA4_DEBUG" => "true") do
      expect(app.send(:try_static, "/swagger/index.html")).not_to be_nil
    end
  end

  it "honours an explicit TINA4_SWAGGER_ENABLED over TINA4_DEBUG in both directions" do
    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "true") do
      expect(app.send(:try_static, "/swagger/index.html")).to be_nil
    end
    with_env("TINA4_SWAGGER_ENABLED" => "true", "TINA4_DEBUG" => "false") do
      expect(app.send(:try_static, "/swagger/index.html")).not_to be_nil
    end
  end

  it "does not affect non-swagger bundled assets" do
    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "false") do
      expect(app.send(:try_static, CONTROL_PATH))
        .not_to be_nil, "the swagger gate must not block ordinary static assets"
    end
  end

  # The gate above answers "may this be served". It cannot answer "is what we
  # serve any use", and that turned out to matter: the bundled index.html asked
  # SwaggerUIBundle for
  #
  #   url: "{SWAGGER_ROUTE}/swagger.json"
  #
  # and SWAGGER_ROUTE was the only occurrence of that token in the gem, so
  # nothing ever substituted it -- while swagger.json is not a path this
  # framework routes either. Every gated path therefore answered 200 with a
  # Swagger UI that could never load its document, and the server logged its own
  # "404 Not Found: /swagger/swagger.json" behind it. /swagger and /swagger/ hid
  # it, because the gated handler intercepts those two and never reaches the
  # static file; the unguarded ways in were /swagger//, which index-resolves, and
  # /swagger/index.html by name.
  #
  # So this is not about status codes. For every path that hands a browser a
  # Swagger UI page, the document URL THAT PAGE NAMES must be one this app
  # answers. Asserting a 200 on a hardcoded /swagger/openapi.json would have
  # passed throughout. Real requests through the whole rack app, not try_static.
  describe "the page a browser actually receives" do
    # Every way to end up on a Swagger UI page. The first two are served by the
    # gated handler, the last two by the bundled asset -- which is the point: the
    # property must hold no matter which of the two answers.
    UI_PATHS = %w[/swagger /swagger/ /swagger// /swagger/index.html].freeze

    it "names a document that resolves, however the UI was reached" do
      with_env("TINA4_SWAGGER_ENABLED" => "true", "TINA4_DEBUG" => "true") do
        UI_PATHS.each do |path|
          page = get_through_app(path)
          expect(page.status).to eq(200), "#{path} returned #{page.status}, expected 200"

          document_url = page.body.to_s[/url:\s*['"]([^'"]+)['"]/, 1]
          expect(document_url).not_to be_nil, "#{path} served a page with no document url: to check"

          # Read out of the HTML that was actually served, then fetched. A page
          # naming an unsubstituted {SWAGGER_ROUTE} placeholder fails right here
          # -- and braces are not legal in a URI, so a placeholder makes the
          # request itself raise. Rescued to 0 so the failure reports the URL and
          # the reason rather than an opaque URI parse error.
          status = begin
            get_through_app(document_url).status
          rescue StandardError
            0
          end
          reason = status.zero? ? "is not even a fetchable URL" : "answered #{status}"
          expect(status).to eq(200),
                            "the page at #{path} asks for #{document_url.inspect}, which " \
                            "#{reason} -- that UI can never load"
        end
      end
    end
  end

  # A real GET through the whole app (every pipeline stage, not try_static).
  # URI() refuses what a client could not send, e.g. an unsubstituted
  # {SWAGGER_ROUTE} placeholder.
  def get_through_app(url)
    uri = URI(url)
    status, _headers, body = app.call(
      "REQUEST_METHOD" => "GET", "PATH_INFO" => uri.path, "QUERY_STRING" => uri.query.to_s,
      "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147", "HTTP_HOST" => "localhost",
      "REMOTE_ADDR" => "127.0.0.1", "rack.input" => StringIO.new(""), "rack.url_scheme" => "http"
    )
    Struct.new(:status, :body).new(status, body.respond_to?(:each) ? body.to_enum.map(&:to_s).join : body.to_s)
  end
end
