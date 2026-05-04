# frozen_string_literal: true
#
# Regression specs for issue #39 — landing page, template auto-routing,
# SPA index serving, and the 404 status line.
#
# Covers:
# - Template auto-routing only fires from src/templates/pages/; partials,
#   layouts, base.twig, errors, and _* files never auto-serve.
# - TINA4_TEMPLATE_ROUTING=off|false|0|no|disabled is a hard kill switch.
# - src/public/index.html auto-serves at / (the SPA case).
# - The framework landing page only renders when TINA4_DEBUG=true.
# - HTTP reason phrases match the actual status code (no more "404 OK").

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Issue #39 — landing page, template auto-routing, 404 status line" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_landing_test") }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Log.configure(tmp_dir) if Tina4::Log.respond_to?(:configure)
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "templates", "pages"))
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "templates", "partials"))
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
    ENV.delete("TINA4_DEBUG")
    ENV.delete("TINA4_TEMPLATE_ROUTING")
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

  # Build the app fresh per test so any new src/public/ etc. is picked up
  def fresh_app
    Tina4::RackApp.new(root_dir: tmp_dir)
  end

  # ── 1. Template auto-routing scope ────────────────────────────

  describe "template auto-routing scope" do
    before(:each) { ENV["TINA4_DEBUG"] = "true" }

    it "serves a file in src/templates/pages/index.twig at /" do
      File.write(File.join(tmp_dir, "src/templates/pages/index.twig"), "ok")
      app = fresh_app
      expect(app.send(:resolve_template, "/")).to eq("pages/index.twig")
    end

    it "serves a file in src/templates/pages/about.twig at /about" do
      File.write(File.join(tmp_dir, "src/templates/pages/about.twig"), "ok")
      app = fresh_app
      expect(app.send(:resolve_template, "/about")).to eq("pages/about.twig")
    end

    it "serves nested files like /products/list" do
      FileUtils.mkdir_p(File.join(tmp_dir, "src/templates/pages/products"))
      File.write(File.join(tmp_dir, "src/templates/pages/products/list.twig"), "ok")
      app = fresh_app
      expect(app.send(:resolve_template, "/products/list")).to eq("pages/products/list.twig")
    end

    it "never serves files in partials/" do
      File.write(File.join(tmp_dir, "src/templates/partials/nav.twig"), "partial")
      app = fresh_app
      expect(app.send(:resolve_template, "/partials/nav")).to be_nil
    end

    it "never serves files in layouts/" do
      FileUtils.mkdir_p(File.join(tmp_dir, "src/templates/layouts"))
      File.write(File.join(tmp_dir, "src/templates/layouts/main.twig"), "layout")
      app = fresh_app
      expect(app.send(:resolve_template, "/layouts/main")).to be_nil
    end

    it "never serves base.twig at /base" do
      File.write(File.join(tmp_dir, "src/templates/base.twig"), "base")
      app = fresh_app
      expect(app.send(:resolve_template, "/base")).to be_nil
    end

    it "never serves files in errors/" do
      FileUtils.mkdir_p(File.join(tmp_dir, "src/templates/errors"))
      File.write(File.join(tmp_dir, "src/templates/errors/404.twig"), "err")
      app = fresh_app
      expect(app.send(:resolve_template, "/errors/404")).to be_nil
    end

    it "skips underscore-prefixed files even within pages/" do
      File.write(File.join(tmp_dir, "src/templates/pages/_helper.twig"), "private")
      app = fresh_app
      expect(app.send(:resolve_template, "/_helper")).to be_nil
    end

    it "skips underscore-prefixed segments inside nested paths" do
      FileUtils.mkdir_p(File.join(tmp_dir, "src/templates/pages/_internal"))
      File.write(File.join(tmp_dir, "src/templates/pages/_internal/secret.twig"), "secret")
      app = fresh_app
      expect(app.send(:resolve_template, "/_internal/secret")).to be_nil
    end
  end

  # ── 1b. Production-mode template cache ────────────────────────

  describe "template auto-routing in production mode" do
    before(:each) { ENV.delete("TINA4_DEBUG") }

    it "indexes only files under pages/ in the cache" do
      File.write(File.join(tmp_dir, "src/templates/pages/about.twig"), "page")
      File.write(File.join(tmp_dir, "src/templates/partials/nav.twig"), "partial")
      File.write(File.join(tmp_dir, "src/templates/base.twig"), "base")

      app = fresh_app
      cache = app.send(:build_template_cache)
      expect(cache).to have_key("about")
      expect(cache).not_to have_key("partials/nav")
      expect(cache).not_to have_key("base")
    end

    it "skips underscore-prefixed files when building the cache" do
      File.write(File.join(tmp_dir, "src/templates/pages/_helper.twig"), "private")
      File.write(File.join(tmp_dir, "src/templates/pages/about.twig"), "page")
      app = fresh_app
      cache = app.send(:build_template_cache)
      expect(cache).to have_key("about")
      expect(cache).not_to have_key("_helper")
    end

    it "resolves /contact via the cached lookup" do
      File.write(File.join(tmp_dir, "src/templates/pages/contact.twig"), "page")
      app = fresh_app
      expect(app.send(:resolve_template, "/contact")).to eq("pages/contact.twig")
    end
  end

  # ── 2. TINA4_TEMPLATE_ROUTING kill switch ─────────────────────

  describe "TINA4_TEMPLATE_ROUTING kill switch" do
    %w[off OFF false FALSE 0 no disabled].each do |value|
      it "disables auto-routing when set to #{value.inspect}" do
        ENV["TINA4_DEBUG"] = "true"
        ENV["TINA4_TEMPLATE_ROUTING"] = value
        File.write(File.join(tmp_dir, "src/templates/pages/about.twig"), "ok")
        app = fresh_app
        expect(app.send(:resolve_template, "/about")).to be_nil
        expect(app.send(:template_auto_routing_enabled?)).to be(false)
      end
    end

    %w[on true 1 yes].each do |value|
      it "keeps auto-routing on when set to #{value.inspect}" do
        ENV["TINA4_DEBUG"] = "true"
        ENV["TINA4_TEMPLATE_ROUTING"] = value
        File.write(File.join(tmp_dir, "src/templates/pages/about.twig"), "ok")
        app = fresh_app
        expect(app.send(:resolve_template, "/about")).to eq("pages/about.twig")
        expect(app.send(:template_auto_routing_enabled?)).to be(true)
      end
    end

    it "keeps auto-routing on when TINA4_TEMPLATE_ROUTING is unset" do
      ENV["TINA4_DEBUG"] = "true"
      ENV.delete("TINA4_TEMPLATE_ROUTING")
      File.write(File.join(tmp_dir, "src/templates/pages/about.twig"), "ok")
      app = fresh_app
      expect(app.send(:resolve_template, "/about")).to eq("pages/about.twig")
      expect(app.send(:template_auto_routing_enabled?)).to be(true)
    end
  end

  # ── 3. src/public/index.html SPA auto-serve ───────────────────

  describe "src/public/index.html SPA auto-serve" do
    it "serves src/public/index.html at /" do
      File.write(File.join(tmp_dir, "src/public/index.html"), "<!doctype html><h1>SPA</h1>")
      app = fresh_app
      status, _headers, body = app.call(mock_env("GET", "/"))
      expect(status).to eq(200)
      expect(body.join).to include("SPA")
    end

    it "serves src/public/admin/index.html at /admin/" do
      FileUtils.mkdir_p(File.join(tmp_dir, "src/public/admin"))
      File.write(File.join(tmp_dir, "src/public/admin/index.html"), "<h1>admin</h1>")
      app = fresh_app
      status, _headers, body = app.call(mock_env("GET", "/admin/"))
      expect(status).to eq(200)
      expect(body.join).to include("admin")
    end

    it "falls through to landing/404 if no index.html exists" do
      ENV.delete("TINA4_DEBUG") # production — landing hidden
      app = fresh_app
      status, _headers, _body = app.call(mock_env("GET", "/"))
      expect(status).to eq(404)
    end
  end

  # ── 4. Landing page hidden in production ──────────────────────

  describe "landing page only in dev mode" do
    %w[true 1 yes].each do |value|
      it "renders landing at / when TINA4_DEBUG=#{value.inspect}" do
        ENV["TINA4_DEBUG"] = value
        app = fresh_app
        status, _headers, body = app.call(mock_env("GET", "/"))
        expect(status).to eq(200)
        expect(body.join).to include("Tina4Ruby")
      end
    end

    %w[false 0 no].each do |value|
      it "returns 404 at / when TINA4_DEBUG=#{value.inspect}" do
        ENV["TINA4_DEBUG"] = value
        app = fresh_app
        status, _headers, body = app.call(mock_env("GET", "/"))
        expect(status).to eq(404)
        # Ensure the framework landing markup never leaks
        expect(body.join).not_to include("Tina4Ruby")
      end
    end

    it "returns 404 at / when TINA4_DEBUG is unset" do
      ENV.delete("TINA4_DEBUG")
      app = fresh_app
      status, _headers, body = app.call(mock_env("GET", "/"))
      expect(status).to eq(404)
      expect(body.join).not_to include("Tina4Ruby")
    end

    it "returns 404 at / with empty TINA4_DEBUG" do
      ENV["TINA4_DEBUG"] = ""
      app = fresh_app
      status, _headers, _body = app.call(mock_env("GET", "/"))
      expect(status).to eq(404)
    end
  end

  # ── 5. HTTP/1.1 reason phrases ────────────────────────────────

  describe "Tina4.http_reason — canonical reason phrases" do
    it "200 -> OK" do
      expect(Tina4.http_reason(200)).to eq("OK")
    end

    it "404 -> Not Found (NOT 'OK')" do
      expect(Tina4.http_reason(404)).to eq("Not Found")
    end

    it "500 -> Internal Server Error" do
      expect(Tina4.http_reason(500)).to eq("Internal Server Error")
    end

    it "302 -> Found" do
      expect(Tina4.http_reason(302)).to eq("Found")
    end

    it "401 -> Unauthorized" do
      expect(Tina4.http_reason(401)).to eq("Unauthorized")
    end

    it "403 -> Forbidden" do
      expect(Tina4.http_reason(403)).to eq("Forbidden")
    end

    it "429 -> Too Many Requests" do
      expect(Tina4.http_reason(429)).to eq("Too Many Requests")
    end

    it "unknown 2xx falls back to OK" do
      expect(Tina4.http_reason(299)).to eq("OK")
    end

    it "unknown 5xx falls back to a non-empty phrase" do
      expect(Tina4.http_reason(599)).not_to be_nil
      expect(Tina4.http_reason(599)).not_to eq("")
    end

    it "never returns an empty string for any common status code" do
      (200..599).each do |code|
        phrase = Tina4.http_reason(code)
        expect(phrase).not_to be_nil
        expect(phrase).not_to eq("")
      end
    end
  end
end
