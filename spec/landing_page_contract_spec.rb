# frozen_string_literal: true
#
# Default landing page — dev-only welcome page, 404-in-prod info-leak guard.
#
# Feature 46. See LAND-DEC-01/LAND-DEC-02 and
# tina4-documentation/plan/v3/fixtures/landing_page_contract.json.
#
# Driven through the REAL front controller (Tina4::RackApp#call) - NO mocks.
# Real GET /, TINA4_DEBUG toggled for real.
#
# Cases (shared names, all four):
#   1. dev_mode_serves_the_branded_landing_page - TINA4_DEBUG on, no user /
#      route -> 200 + the branded banner.
#   2. production_returns_404_and_leaks_nothing - TINA4_DEBUG off -> 404, and
#      the body carries NO framework version, NO /__dev link, NO gallery (the
#      SECURITY case - LAND-PROD-DECIDED).
#   3. a_user_root_route_always_wins - a registered GET / handler wins in BOTH
#      dev and prod.
#   4. a_pages_index_template_suppresses_the_landing - a
#      src/templates/pages/index.* is served at / instead of the landing.
#      This already worked (#resolve_template/#try_serve_template, called
#      FIRST in #handle_404, already resolves "/" -> pages/index.*) - proven
#      here, not fixed. The DEAD should_show_landing_page?/
#      try_serve_index_template pair (deleted alongside this fixture, LAND-
#      DEADCODE) checked a DIFFERENT, never-wired src/templates/index.*
#      convention (no pages/ subdirectory) and was unreachable from
#      #handle_404 in the main checkout.
#
# Same case names in all four:
#   tina4-python/tests/test_landing_page_contract.py
#   tina4-php/tests/LandingPageContractTest.php
#   tina4-nodejs/test/landingPageContract.test.ts

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Feature 46 - default landing page" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_landing_contract") }

  before(:each) do
    Tina4::Router.clear!
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
    ENV.delete("TINA4_DEBUG")
  end

  def mock_env(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new("")
    }
  end

  # Build the app fresh per call so a route registered just before it is seen.
  def fresh_app
    Tina4::RackApp.new(root_dir: tmp_dir)
  end

  it "dev_mode_serves_the_branded_landing_page" do
    ENV["TINA4_DEBUG"] = "true"
    status, _headers, body = fresh_app.call(mock_env("GET", "/"))
    expect(status).to eq(200)
    expect(body.join).to include("Tina4Ruby")
  end

  it "production_returns_404_and_leaks_nothing" do
    ENV.delete("TINA4_DEBUG")
    status, _headers, body = fresh_app.call(mock_env("GET", "/"))
    full_body = body.join
    expect(status).to eq(404)
    expect(full_body).not_to include("Tina4Ruby")
    expect(full_body).not_to include(Tina4::VERSION)
    expect(full_body).not_to include("/__dev")
    expect(full_body).not_to include('id="gallery"')
  end

  it "a_user_root_route_always_wins" do
    Tina4::Router.get("/") { |_request, response| response.html("USER-ROOT-MARKER-RUBY") }

    [true, false].each do |dev|
      dev ? (ENV["TINA4_DEBUG"] = "true") : ENV.delete("TINA4_DEBUG")
      status, _headers, body = fresh_app.call(mock_env("GET", "/"))
      full_body = body.join
      expect(status).to eq(200), "dev=#{dev}"
      expect(full_body).to include("USER-ROOT-MARKER-RUBY")
      expect(full_body).not_to include("Tina4Ruby")
    end
  end

  it "a_pages_index_template_suppresses_the_landing" do
    ENV["TINA4_DEBUG"] = "true"
    FileUtils.mkdir_p(File.join(tmp_dir, "src/templates/pages"))
    File.write(File.join(tmp_dir, "src/templates/pages/index.twig"), "PAGES-INDEX-MARKER-RUBY")

    status, _headers, body = fresh_app.call(mock_env("GET", "/"))
    full_body = body.join
    expect(status).to eq(200)
    expect(full_body).to include("PAGES-INDEX-MARKER-RUBY")
    expect(full_body).not_to include("Tina4Ruby")
  end
end
