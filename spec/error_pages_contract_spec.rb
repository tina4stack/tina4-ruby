# frozen_string_literal: true

# Configurable error pages — Accept-based negotiation, converged 403, request-id, escaping.
#
# Feature 42. See ERR-DEC-01/ERR-DEC-02 and
# tina4-documentation/plan/v3/fixtures/error_pages_contract.json.
#
# Driven through the REAL front controller (Tina4::RackApp#call, via
# Tina4::TestClient) - NO mocks. Real Accept headers, a real GLOBAL class-based
# middleware denial AND a real per-route filter-closure denial for the 403 case
# (both go through Tina4::Middleware.forbid - the gap this feature closes), a
# real malicious path.
#
# Cases (shared names, all four):
#   1. prod_500_has_no_stack_and_a_request_id  - the LOCKED CWE-209 guarantee (do
#      not reopen; re-proven here as part of this feature's negotiated 500 path).
#   2. json_accept_yields_a_json_error_body    - Accept: application/json on
#      404/403/500 -> {error,code,message,status,request_id}.
#   3. browser_accept_yields_the_html_error_page - Accept: text/html or */* ->
#      the HTML errors/{code}.twig page.
#   4. the_403_renders_identically_across_the_four - a middleware denial (global
#      class-based AND per-route filter-closure) now renders through the SAME
#      negotiated path as 404/500.
#   5. a_custom_error_template_overrides_the_builtin - src/templates/errors/
#      {code}.twig wins over the framework default, for 404 AND 500.
#   6. a_reflected_path_in_an_error_page_is_escaped - a <script> path on
#      404/403/500 never appears unescaped in the HTML body (Ruby's Frond does
#      NOT auto-escape {{ }} - each handler escapes explicitly; feature 127
#      already fixed #handle_404, this proves 403 too - it had NOT been fixed).
#   7. the_404_carries_a_request_id - the negotiated JSON body carries request_id.
#
# Same case names in all four:
#   tina4-python/tests/test_error_pages_contract.py
#   tina4-php/tests/ErrorPagesContractTest.php
#   tina4-nodejs/test/errorPagesContract.test.ts

require "spec_helper"
require "tmpdir"
require "fileutils"

SECRET_500_MARKER = "SECRET-500-TRACE-do-not-leak-e42a-ruby"
MALICIOUS_PATH = "/<script>alert(1)</script>"

# A GLOBAL class-based middleware that denies without setting its own response -
# one of the two gaps this feature closes (Tina4::Middleware.forbid's old
# un-negotiated bare JSON fallback).
class ErrorPagesDenyAllGlobal
  def self.before_deny(_request, _response)
    false
  end
end

RSpec.describe "Feature 42 - configurable error pages" do
  before do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Log.clear_request_id
    ENV["TINA4_DEBUG"] = "false"
  end

  after do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Log.clear_request_id
    ENV.delete("TINA4_DEBUG")
  end

  def register_boom(path = "/boom")
    Tina4::Router.get(path) { |_req, _res| raise SECRET_500_MARKER }
  end

  # Registers the path behind a GLOBAL class-based deny-all middleware -
  # Middleware.use is process-wide, so this must be the last route registered.
  def register_blocked_global(path = "/blocked-global")
    Tina4::Middleware.use(ErrorPagesDenyAllGlobal)
    Tina4::Router.get(path) { |_req, res| res.call({ should: "never get here" }, 200) }
  end

  # Registers the path behind a per-route FILTER (closure) middleware - the
  # OTHER entry point into Tina4::Middleware.forbid (Route#run_middleware's
  # 2-arg-callable branch).
  def register_blocked_filter(path = "/blocked-filter")
    Tina4::Router.get(path, middleware: [->(_req, _res) { false }]) do |_req, res|
      res.call({ should: "never get here" }, 200)
    end
  end

  # ------------------------------------------------------- 1. CWE-209, locked

  it "prod_500_has_no_stack_and_a_request_id" do
    register_boom
    client = Tina4::TestClient.new

    r = client.get("/boom")
    expect(r.status).to eq(500)
    [SECRET_500_MARKER, "backtrace", ".rb:", "RuntimeError"].each do |marker|
      expect(r.body).not_to include(marker), "CWE-209 regression: 500 body leaked #{marker.inspect}"
    end
    expect(r.headers["x-request-id"]).not_to be_nil

    r_json = client.get("/boom", headers: { "Accept" => "application/json" })
    expect(r_json.status).to eq(500)
    body = r_json.json
    expect(JSON.generate(body)).not_to include(SECRET_500_MARKER)
    expect(body["message"]).to eq("Server Error")
    expect(body["request_id"]).not_to be_nil
    expect(body["request_id"]).to eq(r_json.headers["x-request-id"])
  end

  # --------------------------------------------- 2 & 3. content negotiation

  [
    [404, "/does-not-exist", nil],
    [403, "/blocked-global", :register_blocked_global],
    [500, "/boom", :register_boom]
  ].each do |code, path, setup|
    it "json_accept_yields_a_json_error_body (#{code})" do
      send(setup, path) if setup
      r = Tina4::TestClient.new.get(path, headers: { "Accept" => "application/json" })
      expect(r.status).to eq(code)
      expect(r.headers["content-type"]).to include("application/json")
      body = r.json
      expect(body["error"]).to be(true)
      expect(body["code"]).not_to be_empty
      expect(body["message"]).not_to be_empty
      expect(body["status"]).to eq(code)
      expect(body["request_id"]).not_to be_nil
    end
  end

  [
    [404, "/does-not-exist", nil, "text/html"],
    [404, "/does-not-exist", nil, "*/*"],
    [403, "/blocked-global", :register_blocked_global, "text/html"],
    [500, "/boom", :register_boom, "text/html"]
  ].each do |code, path, setup, accept|
    it "browser_accept_yields_the_html_error_page (#{code} #{accept})" do
      send(setup, path) if setup
      r = Tina4::TestClient.new.get(path, headers: { "Accept" => accept })
      expect(r.status).to eq(code)
      expect(r.headers["content-type"]).to include("text/html")
      expect(r.body).to include("\"error-code\">#{code}<")
    end
  end

  # ------------------------------------------------------------ 4. 403 split

  it "the_403_renders_identically_across_the_four" do
    register_blocked_global("/blocked-global")
    register_blocked_filter("/blocked-filter")

    client = Tina4::TestClient.new
    ["/blocked-global", "/blocked-filter"].each do |path|
      r_json = client.get(path, headers: { "Accept" => "application/json" })
      expect(r_json.status).to eq(403), "#{path} did not 403"
      body = r_json.json
      expect(body).to eq(
        "error" => true, "code" => "FORBIDDEN", "message" => "Forbidden",
        "status" => 403, "request_id" => body["request_id"]
      )
      expect(body["request_id"]).not_to be_nil

      r_html = client.get(path, headers: { "Accept" => "text/html" })
      expect(r_html.status).to eq(403)
      expect(r_html.headers["content-type"]).to include("text/html")
      expect(r_html.body).to include("\"error-code\">403<")
    end
  end

  # ---------------------------------------------------- 5. override the built-in

  it "a_custom_error_template_overrides_the_builtin" do
    tmp_dir = Dir.mktmpdir("tina4_errpages_override")
    FileUtils.mkdir_p(File.join(tmp_dir, "src/templates/errors"))
    File.write(File.join(tmp_dir, "src/templates/errors/404.twig"), "CUSTOM-404-RUBY path={{ path }}")
    File.write(File.join(tmp_dir, "src/templates/errors/500.twig"), "CUSTOM-500-RUBY rid={{ request_id }}")

    register_boom
    client = Tina4::TestClient.new

    Dir.chdir(tmp_dir) do
      r404 = client.get("/nope")
      expect(r404.status).to eq(404)
      expect(r404.body).to include("CUSTOM-404-RUBY")

      r500 = client.get("/boom")
      expect(r500.status).to eq(500)
      expect(r500.body).to include("CUSTOM-500-RUBY")
    end
  ensure
    FileUtils.rm_rf(tmp_dir) if tmp_dir
  end

  # --------------------------------------------------- 6. reflected-path escaping

  [
    [404, MALICIOUS_PATH, nil],
    [403, MALICIOUS_PATH, :register_blocked_global],
    [500, MALICIOUS_PATH, :register_boom]
  ].each do |code, path, setup|
    it "a_reflected_path_in_an_error_page_is_escaped (#{code})" do
      send(setup, path) if setup
      r = Tina4::TestClient.new.get(path)
      expect(r.status).to eq(code)
      expect(r.body).not_to include("<script>alert(1)</script>"),
                            "XSS: raw <script> reflected in a #{code} page"
      next if code == 500 # 500.twig does not show {{ path }} - nothing to reflect

      expect(r.body).to include("&lt;script&gt;"),
                        "expected the escaped form (proves it WAS reflected, safely)"
    end
  end

  # ------------------------------------------------------- 7. 404 request-id

  it "the_404_carries_a_request_id" do
    r = Tina4::TestClient.new.get("/does-not-exist", headers: { "Accept" => "application/json" })
    expect(r.status).to eq(404)
    body = r.json
    expect(body["request_id"]).not_to be_nil
    expect(body["request_id"]).to eq(r.headers["x-request-id"])
  end
end
