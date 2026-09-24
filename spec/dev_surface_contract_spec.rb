# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

# Dev-surface gate contract (release security boundaries) -- REAL dispatch, NO mocks.
#
# Drives the existing dev-admin security decisions through the
# real front controller Tina4::RackApp#call with a controllable raw socket peer
# (REMOTE_ADDR), Host header and Sec-Fetch-Site header. The witness of every case
# is a real side effect: a secret that is not returned, a file that is not
# written, an upgrade that is refused. Each `it` description is a fixture case name.
RSpec.describe "Tina4 dev-surface gate contract (release security boundaries)" do
  SURFACE_SECRET = "dev-surface-secret-0078"
  SURFACE_ENV_KEYS = %w[
    TINA4_DEBUG TINA4_MCP TINA4_MCP_REMOTE TINA4_MCP_TOKEN TINA4_API_KEY TINA4_HOST TINA4_CSRF
  ].freeze

  around(:each) do |example|
    saved = SURFACE_ENV_KEYS.to_h { |k| [k, ENV[k]] }
    Dir.mktmpdir("tina4_surface") do |tmp|
      app_dir = File.join(tmp, "app")
      FileUtils.mkdir_p(File.join(app_dir, "src", "templates", "pages"))
      FileUtils.mkdir_p(File.join(app_dir, "src", "routes"))
      FileUtils.mkdir_p(File.join(tmp, "app-sibling"))
      File.write(File.join(app_dir, ".env"), "TINA4_SECRET=#{SURFACE_SECRET}\n")
      File.write(File.join(app_dir, "readme.txt"), "public-readme\n")
      File.write(File.join(app_dir, "src", "templates", "pages", "hello.twig"), "PAGE-OK")
      File.write(File.join(app_dir, "src", "templates", "partial_secret.twig"), "PARTIAL-LEAK")
      File.write(File.join(app_dir, "outside.twig"), "ROOT-LEAK")
      File.write(File.join(tmp, "app-sibling", "secret.txt"), "SIBLING-LEAK")
      SURFACE_ENV_KEYS.each { |k| ENV.delete(k) }
      ENV["TINA4_DEBUG"] = "true"
      Dir.chdir(app_dir) do
        Tina4::Router.clear!
        @app_dir = File.realpath(app_dir)
        example.run
      end
    end
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Tina4::Router.clear!
  end

  let(:app) { Tina4::RackApp.new(root_dir: Dir.pwd) }

  def dispatch(method, path, headers: {}, remote_addr: "127.0.0.1", json: nil)
    clean_path, _, query = path.partition("?")
    env = {
      "REQUEST_METHOD" => method.to_s.upcase, "PATH_INFO" => clean_path, "SCRIPT_NAME" => "",
      "QUERY_STRING" => query.to_s, "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "SERVER_PROTOCOL" => "HTTP/1.1", "REMOTE_ADDR" => remote_addr, "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new
    }
    unless json.nil?
      raw = JSON.generate(json)
      env["CONTENT_TYPE"] = "application/json"
      env["CONTENT_LENGTH"] = raw.bytesize.to_s
      env["rack.input"] = StringIO.new(raw)
    end
    headers.each { |k, v| env["HTTP_#{k.to_s.upcase.tr('-', '_')}"] = v }
    status, _headers, parts = app.call(env)
    body = +""
    parts.each { |chunk| body << chunk.to_s }
    [status, body]
  end

  # ── Resolve first, then check the secret denylist ─────────────────────────

  it "a dotenv path with a trailing dot segment is refused" do
    [".env/.", ".env/x/..", "src/../.env", "./.env"].each do |trick|
      ["/__dev/api/file", "/__dev/api/file/raw"].each do |endpoint|
        status, body = dispatch("GET", "#{endpoint}?path=#{trick}")
        expect([403, 404]).to include(status), "#{endpoint}?path=#{trick} -> #{status}"
        expect(body).not_to include(SURFACE_SECRET), "#{endpoint}?path=#{trick} served .env"
      end
    end
  end

  it "a symlink to dotenv is refused" do
    File.symlink(File.join(@app_dir, ".env"), File.join(@app_dir, "innocent.txt"))
    status, body = dispatch("GET", "/__dev/api/file?path=innocent.txt")
    expect(status).to eq(403)
    expect(body).not_to include(SURFACE_SECRET)
  end

  it "a sibling prefix directory is outside the project" do
    ["/__dev/api/file", "/__dev/api/file/raw"].each do |endpoint|
      status, body = dispatch("GET", "#{endpoint}?path=../app-sibling/secret.txt")
      expect(status).to eq(403), "#{endpoint} -> #{status}"
      expect(body).not_to include("SIBLING-LEAK")
    end
    status, = dispatch("POST", "/__dev/api/file/save", headers: { "Sec-Fetch-Site" => "same-origin" },
                                                        json: { path: "../app-sibling/written.txt", content: "x" })
    expect(status).to eq(403)
    expect(File.exist?(File.join(File.dirname(@app_dir), "app-sibling", "written.txt"))).to be(false)
  end

  it "metrics file refuses a path outside the project" do
    outside = File.join(File.dirname(@app_dir), "app-sibling", "secret.txt")
    expect(dispatch("GET", "/__dev/api/metrics/file?path=#{outside}")[0]).to eq(403)
    expect(dispatch("GET", "/__dev/api/metrics/file?path=../app-sibling/secret.txt")[0]).to eq(403)
  end

  # ── Reads carry the same gate as writes ───────────────────────────────────

  it "a cross origin read is refused" do
    status, body = dispatch("GET", "/__dev/api/file?path=readme.txt", headers: { "Sec-Fetch-Site" => "cross-site" })
    expect(status).to eq(403)
    expect(body).not_to include("public-readme")
    status, body = dispatch("GET", "/__dev/api/file?path=readme.txt", headers: { "Sec-Fetch-Site" => "same-origin" })
    expect(status).to eq(200)
    expect(body).to include("public-readme")
  end

  it "a same site fetch is refused" do
    status, body = dispatch("GET", "/__dev/api/file?path=readme.txt", headers: { "Sec-Fetch-Site" => "same-site" })
    expect(status).to eq(403)
    expect(body).not_to include("public-readme")
    status, = dispatch("POST", "/__dev/api/file/save", headers: { "Sec-Fetch-Site" => "same-site" },
                                                        json: { path: "same_site_probe.txt", content: "x" })
    expect(status).to eq(403)
    expect(File.exist?(File.join(@app_dir, "same_site_probe.txt"))).to be(false)
  end

  it "a non loopback peer cannot read" do
    status, body = dispatch("GET", "/__dev/api/file?path=readme.txt", remote_addr: "203.0.113.9")
    expect(status).to eq(403)
    expect(body).not_to include("public-readme")
  end

  # ── Host allow-list (DNS rebinding) ───────────────────────────────────────

  it "a foreign host header is refused" do
    ["/__dev", "/__dev/api/status", "/__dev/api/file?path=readme.txt"].each do |path|
      status, body = dispatch("GET", path, headers: { "Host" => "rebind.evil.example:7147" })
      expect(status).to eq(403), "#{path} with a foreign Host -> #{status}"
      expect(body).not_to include("public-readme")
    end
  end

  it "a loopback host header is allowed" do
    ["localhost:7147", "127.0.0.1:7147", "[::1]:7147", "localhost"].each do |host|
      expect(dispatch("GET", "/__dev/api/status", headers: { "Host" => host })[0]).to eq(200), "Host #{host}"
    end
    ENV["TINA4_HOST"] = "devbox.internal"
    expect(dispatch("GET", "/__dev/api/status", headers: { "Host" => "devbox.internal:7147" })[0]).to eq(200)
  end

  it "a foreign host cannot reach mcp" do
    expect(dispatch("GET", "/__dev/api/mcp/tools", headers: { "Host" => "rebind.evil.example" })[0]).to eq(403)
    rpc = { jsonrpc: "2.0", id: 1, method: "tools/list" }
    expect(dispatch("POST", "/__dev/mcp", headers: { "Host" => "rebind.evil.example" }, json: rpc)[0]).to eq(403)
  end

  it "a foreign host cannot open the reload socket" do
    Tina4::RackApp.register_dev_reload_ws
    upgrade = { "Upgrade" => "websocket", "Connection" => "Upgrade",
                "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version" => "13" }
    status, = dispatch("GET", "/__dev_reload", headers: upgrade.merge("Host" => "rebind.evil.example:7147"))
    expect(status).to eq(403)
    # Positive control: a loopback Host reaches the upgrade itself (426 here
    # only because this in-process env carries no rack.hijack).
    status, = dispatch("GET", "/__dev_reload", headers: upgrade.merge("Host" => "localhost:7147"))
    expect(status).to eq(426)
  end

  # ── Only TINA4_MCP_TOKEN unlocks the remote dev surface ───────────────────

  it "the api key does not unlock dev writes" do
    ENV["TINA4_API_KEY"] = "app-api-key"
    probe = File.join(@app_dir, "api_key_probe.txt")
    [{ "Authorization" => "Bearer app-api-key" }, { "X-Api-Key" => "app-api-key" }].each do |headers|
      status, = dispatch("POST", "/__dev/api/file/save", headers: headers, remote_addr: "203.0.113.9",
                                                          json: { path: "api_key_probe.txt", content: "x" })
      expect(status).to eq(403)
      expect(File.exist?(probe)).to be(false)
    end
    ENV["TINA4_MCP"] = "true"
    ENV["TINA4_MCP_REMOTE"] = "true"
    status, = dispatch("GET", "/__dev/api/mcp/tools", headers: { "Authorization" => "Bearer app-api-key" },
                                                      remote_addr: "203.0.113.9")
    expect(status).to eq(200) # accepted MCP transport API-key fallback
    ENV["TINA4_MCP_TOKEN"] = "mcp-token-0078"
    ENV["TINA4_HOST"] = "devbox.lan"
    status, = dispatch("POST", "/__dev/api/file/save", headers: { "Authorization" => "Bearer mcp-token-0078",
                                                                  "Host" => "devbox.lan:7147" },
                                                        remote_addr: "203.0.113.9",
                                                        json: { path: "api_key_probe.txt", content: "ok" })
    expect(status).to eq(200)
    expect(File.read(probe)).to eq("ok")
  end

  # ── Table viewer takes only a real table name ─────────────────────────────

  it "table info rejects an unknown table name" do
    db = Tina4::Database.new("sqlite:///#{File.join(@app_dir, "surface.db")}")
    db.execute("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
    db.execute("INSERT INTO people (name) VALUES ('ada')")
    db.commit if db.respond_to?(:commit)
    saved_db = Tina4.database
    Tina4.bind_database(db)
    begin
      status, body = dispatch("GET", "/__dev/api/table?name=people")
      expect(status).to eq(200)
      expect(body).to include("ada")
      ["(SELECT 'INJECTED' AS leak)", "people WHERE 1=0 UNION SELECT 1,'INJECTED'", "no_such_table"].each do |bad|
        status, body = dispatch("GET", "/__dev/api/table?name=#{URI.encode_www_form_component(bad)}")
        expect(status).to eq(404), "name=#{bad} -> #{status}"
        expect(body).not_to include("INJECTED")
      end
    ensure
      Tina4.bind_database(saved_db)
      db.close if db.respond_to?(:close)
    end
  end

  # ── Template auto-routing stays inside the pages root ─────────────────────

  it "template auto routing cannot leave the templates root" do
    status, body = dispatch("GET", "/hello")
    expect(status).to eq(200)
    expect(body).to include("PAGE-OK")
    ["/../partial_secret", "/../../outside", "/sub/../../partial_secret"].each do |path|
      _, body = dispatch("GET", path)
      expect(body).not_to include("PARTIAL-LEAK"), "#{path} rendered a template outside pages/"
      expect(body).not_to include("ROOT-LEAK"), "#{path} rendered a file outside the templates root"
    end
  end

  it "matching fetch metadata does not override a foreign Origin" do
    status, body = dispatch("GET", "/__dev/api/file?path=readme.txt", headers: {
      "Host" => "localhost:7147", "Sec-Fetch-Site" => "same-origin", "Origin" => "https://localhost:7147"})
    expect(status).to eq(403)
    expect(body).not_to include("public-readme")
  end

  it "dedicated token does not bypass host or origin" do
    ENV["TINA4_MCP_TOKEN"] = "synthetic-token"
    [{ "Host" => "foreign.example" }, { "Host" => "localhost", "Origin" => "https://foreign.example" }].each do |headers|
      status, body = dispatch("GET", "/__dev/api/file?path=readme.txt", remote_addr: "203.0.113.9",
        headers: headers.merge("Authorization" => "Bearer synthetic-token"))
      expect(status).to eq(403)
      expect(body).not_to include("public-readme")
    end
  end

  %w[GET HEAD OPTIONS POST].each do |method|
    it "every dev method requires raw peer trust: #{method}" do
      status, body = dispatch(method, "/__dev/api/file?path=readme.txt", remote_addr: "203.0.113.9",
        headers: { "Host" => "localhost", "X-Forwarded-For" => "127.0.0.1" })
      expect(status).to eq(403)
      expect(body).not_to include("public-readme")
    end
  end

  it "public in project symlink remains readable" do
    File.symlink(File.join(@app_dir, "readme.txt"), File.join(@app_dir, "public-alias.txt"))
    ["/__dev/api/file", "/__dev/api/file/raw"].each do |endpoint|
      status, body = dispatch("GET", endpoint + "?path=public-alias.txt")
      expect(status).to eq(200)
      expect(body).to include("public-readme")
    end
  end

  it "raw file preserves non UTF8 and CRLF bytes exactly" do
    bytes = [0, 255, 254, 13, 10, 128, 65, 13, 10].pack("C*")
    File.binwrite(File.join(@app_dir, "binary.dat"), bytes)
    status, body = dispatch("GET", "/__dev/api/file/raw?path=binary.dat")
    expect(status).to eq(200)
    expect(body.b).to eq(bytes)
  end

  # ── Health does not disclose the version in production (ADR-0078) ──────────

  it "health omits the version outside debug" do
    ENV["TINA4_DEBUG"] = "false"
    Tina4::Health.register!
    ["/health", "/__health"].each do |path|
      status, body = dispatch("GET", path)
      expect(status).to eq(200)
      expect(JSON.parse(body).keys.sort).to eq(%w[framework status uptime])
    end
  end

  it "health carries the version in debug" do
    Tina4::Health.register!
    status, body = dispatch("GET", "/health")
    expect(status).to eq(200)
    expect(JSON.parse(body)["version"]).to eq(Tina4::VERSION)
  end
end
