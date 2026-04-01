# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Static file serving" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_static_test") }
  let(:pub_dir) { File.join(tmp_dir, "public") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    FileUtils.mkdir_p(pub_dir)
  end

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def mock_env(method, path, headers: {})
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new("")
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  # ── Basic file serving ─────────────────────────────────────────

  describe "serving files" do
    it "serves a plain text file" do
      File.write(File.join(pub_dir, "hello.txt"), "Hello World")
      status, headers, body = app.call(mock_env("GET", "/hello.txt"))
      expect(status).to eq(200)
      expect(body.join).to eq("Hello World")
    end

    it "serves an HTML file" do
      File.write(File.join(pub_dir, "page.html"), "<h1>Page</h1>")
      status, headers, body = app.call(mock_env("GET", "/page.html"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/html")
    end

    it "serves a CSS file with correct content type" do
      File.write(File.join(pub_dir, "style.css"), "body { color: red; }")
      status, headers, _body = app.call(mock_env("GET", "/style.css"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/css")
    end

    it "serves a JavaScript file with correct content type" do
      File.write(File.join(pub_dir, "app.js"), "console.log('hi');")
      status, headers, _body = app.call(mock_env("GET", "/app.js"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/javascript")
    end

    it "serves a JSON file with correct content type" do
      File.write(File.join(pub_dir, "data.json"), '{"key":"value"}')
      status, headers, _body = app.call(mock_env("GET", "/data.json"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
    end

    it "serves an SVG file with correct content type" do
      File.write(File.join(pub_dir, "icon.svg"), '<svg></svg>')
      status, headers, _body = app.call(mock_env("GET", "/icon.svg"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("image/svg+xml")
    end

    it "serves binary files" do
      binary_content = "\x89PNG\r\n\x1A\n" + ("\x00" * 20)
      File.binwrite(File.join(pub_dir, "image.png"), binary_content)
      status, headers, body = app.call(mock_env("GET", "/image.png"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("image/png")
      expect(body.join.bytes).to eq(binary_content.bytes)
    end

    it "serves files from subdirectories" do
      sub_dir = File.join(pub_dir, "assets", "css")
      FileUtils.mkdir_p(sub_dir)
      File.write(File.join(sub_dir, "main.css"), "body{}")
      status, _headers, body = app.call(mock_env("GET", "/assets/css/main.css"))
      expect(status).to eq(200)
      expect(body.join).to eq("body{}")
    end

    it "returns unknown content type as application/octet-stream" do
      File.write(File.join(pub_dir, "data.xyz"), "unknown format")
      status, headers, _body = app.call(mock_env("GET", "/data.xyz"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/octet-stream")
    end
  end

  # ── Index files ────────────────────────────────────────────────

  describe "index.html serving" do
    it "serves index.html for directory paths ending with /" do
      File.write(File.join(pub_dir, "index.html"), "<h1>Index</h1>")
      status, _headers, body = app.call(mock_env("GET", "/"))
      expect(status).to eq(200)
      expect(body.join).to include("Index")
    end

    it "serves index.html for directory-like paths without extension" do
      sub = File.join(pub_dir, "about")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, "index.html"), "<h1>About</h1>")
      status, _headers, body = app.call(mock_env("GET", "/about"))
      expect(status).to eq(200)
      expect(body.join).to include("About")
    end
  end

  # ── Security ───────────────────────────────────────────────────

  describe "security" do
    it "blocks path traversal with .." do
      status, _headers, _body = app.call(mock_env("GET", "/../../../etc/passwd"))
      expect(status).to eq(404)
    end

    it "blocks encoded path traversal" do
      status, _headers, _body = app.call(mock_env("GET", "/..%2F..%2Fetc/passwd"))
      # Either 404 or the path won't resolve
      expect(status).to eq(404)
    end

    it "blocks double-dot in middle of path" do
      status, _headers, _body = app.call(mock_env("GET", "/public/../secret.txt"))
      expect(status).to eq(404)
    end
  end

  # ── 404 handling ───────────────────────────────────────────────

  describe "404 for missing files" do
    it "returns 404 for nonexistent file" do
      status, _headers, _body = app.call(mock_env("GET", "/nonexistent.txt"))
      expect(status).to eq(404)
    end

    it "returns 404 for nonexistent directory" do
      status, _headers, _body = app.call(mock_env("GET", "/no/such/path/file.txt"))
      expect(status).to eq(404)
    end
  end

  # ── Multiple static directories ────────────────────────────────

  describe "static directory priority" do
    it "serves from public/ directory" do
      File.write(File.join(pub_dir, "from_public.txt"), "from public")
      status, _headers, body = app.call(mock_env("GET", "/from_public.txt"))
      expect(status).to eq(200)
      expect(body.join).to eq("from public")
    end

    it "serves from src/public/ directory" do
      src_pub = File.join(tmp_dir, "src", "public")
      FileUtils.mkdir_p(src_pub)
      File.write(File.join(src_pub, "from_src.txt"), "from src public")

      # Need a fresh app to pick up the new directory
      fresh_app = Tina4::RackApp.new(root_dir: tmp_dir)
      status, _headers, body = fresh_app.call(mock_env("GET", "/from_src.txt"))
      expect(status).to eq(200)
      expect(body.join).to eq("from src public")
    end
  end

  # ── Route priority over static ─────────────────────────────────

  describe "routes vs static" do
    it "routes take priority over static files for /api/ paths" do
      # Static files under /api/ are not checked due to fast-path
      Tina4.get("/api/data") { |_req, res| res.json({ source: "route" }) }
      FileUtils.mkdir_p(File.join(pub_dir, "api"))
      File.write(File.join(pub_dir, "api", "data"), '{"source":"static"}')

      status, _headers, body = app.call(mock_env("GET", "/api/data"))
      expect(status).to eq(200)
      parsed = JSON.parse(body.join)
      expect(parsed["source"]).to eq("route")
    end
  end
end
