# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

# Dev-admin security conformance (feature 127) -- REAL dispatch, NO mocks.
#
# Drives the shared devadmin_contract.json cases through the REAL front
# controller Tina4::RackApp#call -- the same Rack entry point Puma calls -- with
# a controllable raw socket peer (env["REMOTE_ADDR"]) and headers. NOTHING is
# mocked: the witness of every case is a real side effect (a file that is / is
# not written on disk, a real SQLite row that is / is not inserted, a secret
# that never appears in a response body).
#
# Fixture: tina4-documentation/plan/v3/fixtures/devadmin_contract.json
# Owner decisions: DEVADMIN-DEC-01 (same-origin gate), DEC-02 (loopback), DEC-03
# (.env denylist), DEC-04 (toolbar/path escape), DEC-05 (mcp/call gate), DEC-06
# (this suite). Each `it` description matches a fixture case name verbatim so the
# shared auditor (scripts/audit-contract-fixtures.py) credits this suite; the
# SAME case names appear in the Python (reference), PHP and Node suites.
#
# These are DELIBERATELY real-dispatch: the audit found prior dev-admin tests
# drove handlers through mock req/resp that BYPASSED the mount gate and the
# guard, so a passing test proved nothing about the wire. Every negative case
# here has been mutation-proved (disable the gate under test -> it goes red).
RSpec.describe "Tina4::DevAdmin security conformance (feature 127)" do
  TINA4_SECRET_VALUE = "sup3r-sekret-do-not-leak-127"

  ENV_KEYS = %w[
    TINA4_DEBUG TINA4_MCP TINA4_MCP_REMOTE TINA4_MCP_TOKEN TINA4_API_KEY
    TINA4_HOST TINA4_CSRF
  ].freeze

  around(:each) do |example|
    saved = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    Dir.mktmpdir("tina4_devadmin_conf") do |tmp|
      # A real project cwd with a real .env carrying a secret. The file endpoints
      # read Dir.pwd, so the whole example runs against this throwaway tree.
      File.write(File.join(tmp, ".env"), <<~ENV)
        TINA4_SECRET=#{TINA4_SECRET_VALUE}
        TINA4_DATABASE_PASSWORD=pg-password-leak
        TINA4_MCP_TOKEN=mcp-token-leak
      ENV
      File.write(File.join(tmp, ".env.example"), "TINA4_SECRET=\n")
      File.write(File.join(tmp, "readme.txt"), "public\n")
      FileUtils.mkdir_p(File.join(tmp, "src", "routes"))

      # Clean baseline so a stray MCP/host var can't skew a case.
      %w[TINA4_MCP TINA4_MCP_REMOTE TINA4_MCP_TOKEN TINA4_API_KEY TINA4_HOST TINA4_CSRF].each { |k| ENV.delete(k) }

      Dir.chdir(tmp) do
        Tina4::Router.clear!
        example.run
      end
    end
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Tina4::Router.clear!
  end

  # One real RackApp per example; reused across the multiple dispatches a case
  # makes. Lazily built INSIDE the example, after the around block chdir'd into
  # the temp project, so its Dir.pwd is that project.
  let(:app) { Tina4::RackApp.new }

  # Drive the real front controller for one request. Returns [status, body_str,
  # headers]. `remote_addr` is the RAW socket peer -- exactly what Puma hands the
  # framework -- so a case can present a genuine non-loopback peer that
  # X-Forwarded-For cannot spoof. This is NOT a mock: it is the real Rack app
  # running its real dispatch pipeline.
  def dispatch(method, path, headers: {}, remote_addr: "127.0.0.1", json: nil, body: nil)
    clean_path, _, query = path.partition("?")
    env = {
      "REQUEST_METHOD"  => method.to_s.upcase,
      "PATH_INFO"       => clean_path,
      "SCRIPT_NAME"     => "",
      "QUERY_STRING"    => query.to_s,
      "SERVER_NAME"     => "localhost",
      "SERVER_PORT"     => "7147",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "REMOTE_ADDR"     => remote_addr,
      "rack.url_scheme" => "http",
      "rack.input"      => StringIO.new(""),
      "rack.errors"     => StringIO.new
    }
    raw = ""
    if !json.nil?
      raw = JSON.generate(json)
      env["CONTENT_TYPE"] = "application/json"
    elsif !body.nil?
      raw = body.is_a?(String) ? body : body.to_s
    end
    unless raw.empty?
      env["CONTENT_LENGTH"] = raw.bytesize.to_s
      env["rack.input"] = StringIO.new(raw)
    end
    (headers || {}).each do |k, v|
      env["HTTP_#{k.to_s.upcase.tr('-', '_')}"] = v
    end

    status, resp_headers, body_parts = app.call(env)
    body_str = +""
    body_parts.each { |chunk| body_str << (chunk.is_a?(String) ? chunk : chunk.to_s) }
    [status, body_str, resp_headers]
  end

  # ── DEVADMIN-DEC-06: behavioural prod-404 ───────────────────────────────────

  it "dev admin is absent without debug" do
    ENV["TINA4_DEBUG"] = "false"

    status_ui, = dispatch("GET", "/__dev")
    expect(status_ui).to eq(404)

    status_save, = dispatch(
      "POST", "/__dev/api/file/save",
      headers: { "sec-fetch-site" => "same-origin" },
      json: { "path" => "prod404_probe.txt", "content" => "should not exist" }
    )
    expect(status_save).to eq(404)
    expect(File.exist?("prod404_probe.txt")).to be(false)
  end

  # ── DEVADMIN-DEC-01: fail-closed same-origin gate ───────────────────────────

  it "a cross origin write is refused and writes nothing" do
    ENV["TINA4_DEBUG"] = "true"

    status, = dispatch(
      "POST", "/__dev/api/file/save",
      headers: { "sec-fetch-site" => "cross-site", "origin" => "https://evil.example" },
      json: { "path" => "csrf_probe.txt", "content" => "pwned by drive-by CSRF" }
    )
    expect(status).to eq(403)
    expect(File.exist?("csrf_probe.txt")).to be(false)

    # An explicit cross-origin Origin (no Sec-Fetch-Site, the older-browser path)
    # is refused the same way.
    status2, = dispatch(
      "POST", "/__dev/api/file/save",
      headers: { "origin" => "https://evil.example", "host" => "localhost:7147" },
      json: { "path" => "csrf_probe.txt", "content" => "pwned" }
    )
    expect(status2).to eq(403)
    expect(File.exist?("csrf_probe.txt")).to be(false)
  end

  it "a same origin write is allowed" do
    ENV["TINA4_DEBUG"] = "true"

    status, = dispatch(
      "POST", "/__dev/api/file/save",
      headers: { "sec-fetch-site" => "same-origin" },
      json: { "path" => "same_origin_probe.txt", "content" => "legit save" }
    )
    expect(status).to eq(200)
    expect(File.read("same_origin_probe.txt")).to eq("legit save")
  end

  # ── DEVADMIN-DEC-03: .env / secret denylist ─────────────────────────────────

  it "the file read endpoint refuses dotenv secrets" do
    ENV["TINA4_DEBUG"] = "true"

    status, body_str = dispatch("GET", "/__dev/api/file?path=.env")
    expect(status).to eq(403)
    expect(body_str).not_to include(TINA4_SECRET_VALUE)
    expect(body_str).not_to include("pg-password-leak")

    status_raw, body_raw = dispatch("GET", "/__dev/api/file/raw?path=.env")
    expect(status_raw).to eq(403)
    expect(body_raw).not_to include(TINA4_SECRET_VALUE)

    # .env.example is a safe placeholder template and stays readable.
    status_ex, = dispatch("GET", "/__dev/api/file?path=.env.example")
    expect(status_ex).to eq(200)
  end

  it "the file listing hides dotenv" do
    ENV["TINA4_DEBUG"] = "true"

    status, body_str = dispatch("GET", "/__dev/api/files?path=.")
    expect(status).to eq(200)
    names = JSON.parse(body_str).fetch("entries", []).map { |e| e["name"] }
    expect(names).not_to include(".env")
    expect(names).to include("readme.txt")
    expect(body_str).not_to include(TINA4_SECRET_VALUE)
  end

  # ── DEVADMIN-DEC-02: loopback-only mutations (defense in depth) ──────────────

  it "a non loopback peer cannot mutate" do
    ENV["TINA4_DEBUG"] = "true"

    status, = dispatch(
      "POST", "/__dev/api/file/save",
      remote_addr: "8.8.8.8",
      headers: { "sec-fetch-site" => "same-origin" },
      json: { "path" => "loopback_probe.txt", "content" => "remote write" }
    )
    expect(status).to eq(403)
    expect(File.exist?("loopback_probe.txt")).to be(false)

    # A spoofed X-Forwarded-For: 127.0.0.1 from a remote peer does NOT bypass it
    # (the raw socket peer governs).
    status_xff, = dispatch(
      "POST", "/__dev/api/file/save",
      remote_addr: "8.8.8.8",
      headers: { "sec-fetch-site" => "same-origin", "x-forwarded-for" => "127.0.0.1" },
      json: { "path" => "loopback_probe.txt", "content" => "xff bypass" }
    )
    expect(status_xff).to eq(403)
    expect(File.exist?("loopback_probe.txt")).to be(false)
  end

  it "a loopback peer may mutate" do
    ENV["TINA4_DEBUG"] = "true"

    status, = dispatch(
      "POST", "/__dev/api/file/save",
      remote_addr: "127.0.0.1",
      headers: { "sec-fetch-site" => "same-origin" },
      json: { "path" => "loopback_ok_probe.txt", "content" => "local write" }
    )
    expect(status).to eq(200)
    expect(File.read("loopback_ok_probe.txt")).to eq("local write")
  end

  # ── DEVADMIN-DEC-04: toolbar / reflected-path escaping ──────────────────────

  it "the injected toolbar escapes the request path" do
    ENV["TINA4_DEBUG"] = "true"

    _status, body_str = dispatch(
      "GET", "/x<script>alert(1)</script>y", headers: { "accept" => "text/html" }
    )
    expect(body_str).to include("tina4-dev-toolbar")
    expect(body_str).not_to include("<script>alert(1)</script>")
    expect(body_str).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
  end

  # ── DEVADMIN-DEC-05: mcp/call tool-execution gate ───────────────────────────

  def bind_probe_db(dir)
    db = Tina4::Database.new("sqlite:///" + File.join(dir, "mcp_gate.db"))
    db.execute("CREATE TABLE IF NOT EXISTS gate_probe (id INTEGER PRIMARY KEY, v TEXT)")
    Tina4.bind_database(db)
    db
  end

  def probe_row_count
    # The sqlite driver returns rows with SYMBOL keys.
    Tina4.database.fetch_one("SELECT COUNT(*) AS n FROM gate_probe")[:n].to_i
  end

  it "a remote unauthenticated mcp call is refused and the tool does not run" do
    ENV["TINA4_DEBUG"] = "true"
    Dir.mktmpdir("tina4_mcp_gate_db") do |db_dir|
      db = bind_probe_db(db_dir)
      begin
        expect(probe_row_count).to eq(0)
        insert = { "name" => "database_execute",
                   "arguments" => { "sql" => "INSERT INTO gate_probe (v) VALUES ('x')" } }

        # Remote, no token -> 404 BEFORE the tool runs; nothing inserted.
        status, body_str = dispatch("POST", "/__dev/api/mcp/call", remote_addr: "8.8.8.8", json: insert)
        expect(status).to eq(404)
        expect(body_str).to include("MCP forbidden")
        expect(probe_row_count).to eq(0)

        # Remote + spoofed X-Forwarded-For loopback -> still 404 (raw peer governs).
        status_xff, = dispatch(
          "POST", "/__dev/api/mcp/call", remote_addr: "8.8.8.8",
          headers: { "x-forwarded-for" => "127.0.0.1" }, json: insert
        )
        expect(status_xff).to eq(404)
        expect(probe_row_count).to eq(0)

        # Loopback -> the tool runs (positive control): the row lands.
        status_ok, = dispatch("POST", "/__dev/api/mcp/call", remote_addr: "127.0.0.1", json: insert)
        expect(status_ok).to eq(200)
        expect(probe_row_count).to eq(1)
      ensure
        db.close rescue nil
      end
    end
  end
end
