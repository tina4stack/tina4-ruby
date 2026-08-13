# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "securerandom"

# ── Dev-MCP tools conformance (invoke every tool) ────────────────────────────
#
# Invoke-every-tool lock-in for the built-in dev-MCP tools. This is the guard
# that was missing when four tools shipped broken and an ad-hoc sweep found
# them: route_test (a clean-boot NameError), template_render (a raise),
# queue_status and seed_table (self-rescued "green but dead" error dicts).
#
# Everything runs in fresh SUBPROCESSES with `require "tina4"` and nothing more,
# because the dev-MCP server is a per-project process singleton — McpDevTools
# .register captures File.expand_path(Dir.pwd) as project_root and the tools
# read process-global state (the ORM subclass registry, the router, the bare
# `require "tina4"` load graph). Running the sweep inside the shared rspec VM is
# inherently leaky: other specs pollute Tina4::ORM.subclasses with anonymous
# models and pre-load stringio, so an in-process sweep both trips on unrelated
# leaked state and MISSES the load-order-sensitive defects. A clean subprocess
# is the real throwaway app the MCP server actually runs in (a fresh
# `tina4 serve`), and is exactly how the sweep found the bugs. No mocks — a real
# temp SQLite DB, a real route, a real ORM model, a real migration, a real plan,
# driven through the real JSON-RPC handler / the real dev-admin dispatcher.
#
# Coverage map (each fix has at least one example that FAILS pre-fix):
#   * template_render, queue_status — the invoke-all sweep (a raise / an
#     in-band error dict manifest on every call, order-independent).
#   * route_test — a minimal clean boot (its stringio NameError only bites when
#     TestClient is the first thing touched, before anything loads stringio).
#   * seed_table (MCP tool) — a minimal clean boot (its missing-autoload only
#     bites before any tool has referenced Tina4::FakeData).
#   * seed_table (dev-admin POST /__dev/api/seed) — same root cause, same lock.
#
# The load-order-sensitive tools (route_test, seed_table) CANNOT be caught by a
# single full sweep: building the whole dev environment (`require "tina4/dev"`,
# the full tool registry) eagerly loads stringio and the seeder, masking them.
# Hence the dedicated first-touch examples. FAILS pre-fix, PASSES after.

RSpec.describe "Dev-MCP tools conformance (invoke every tool)" do
  FIXED_TOOLS = %w[route_test template_render queue_status seed_table].freeze

  LIB = File.expand_path("../lib", __dir__)

  # Run a Ruby script in a fresh subprocess against the working-tree lib
  # (`-I lib`, so `require "tina4"` picks up our source, not the installed gem).
  # STDERR is folded into STDOUT and the result is forced to UTF-8 (fake data /
  # docs contain non-ASCII).
  def run_ruby(dir, body)
    script = File.join(dir, "boot_#{SecureRandom.hex(4)}.rb")
    File.write(script, body)
    out = IO.popen([RbConfig.ruby, "-I", LIB, script, dir], err: %i[child out], &:read)
    [out.force_encoding("UTF-8"), $?]
  end

  # Driver for the full sweep. Builds the real dev-MCP server, enumerates EVERY
  # registered tool from the live registry, invokes each via real JSON-RPC
  # tools/call, classifies the outcome, and emits a JSON report between markers.
  # `#{...}` is intentionally literal here (single-quoted heredoc).
  SWEEP_DRIVER = <<~'RUBY'
    require "json"

    Dir.chdir(ARGV[0])
    ENV["TINA4_DEBUG"]       = "true"
    ENV["TINA4_LOG_LEVEL"]   = "NONE"
    ENV["TINA4_SECRET"]      = "test-secret-do-not-use-in-prod-0000000000000000"
    ENV["TINA4_AI_URL"]      = "http://127.0.0.1:9/api/chat"  # dead port -> plan_flesh degrades
    ENV["TINA4_ENV"]         = "development"
    ENV.delete("TINA4_DATABASE_URL")

    require "tina4"
    begin; require "tina4/dev"; rescue LoadError; end

    db = Tina4::Database.new("sqlite://app.db")
    Tina4.bind_database(db)
    db.execute("CREATE TABLE IF NOT EXISTS widget (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER)")
    db.execute("INSERT INTO widget (name, qty) VALUES (?, ?)", ["alpha", 3])
    db.execute("INSERT INTO widget (name, qty) VALUES (?, ?)", ["beta", 7])
    db.commit rescue nil

    class Widget < Tina4::ORM
      integer_field :id, primary_key: true, auto_increment: true
      string_field  :name
      integer_field :qty
    end

    Tina4::Router.clear! rescue nil
    Tina4::Router.get("/hello")    { |_req, res| res.call({ msg: "hi" }, 200) }
    Tina4::Router.post("/widgets") { |_req, res| res.call({ ok: true }, 201) }

    begin
      Tina4::Plan.create("Setup Plan", goal: "verify tools", steps: %w[one two], make_current: true)
    rescue => e
      warn "plan setup skipped: #{e.class}: #{e.message}"
    end

    server = Tina4::McpServer.new("/__dev/mcp", name: "Conformance Tools")
    Tina4::McpDevTools.register(server)

    args = {
      "database_query"     => { "sql" => "SELECT id, name, qty FROM widget ORDER BY id", "params" => "[]" },
      "database_execute"   => { "sql" => "CREATE TABLE IF NOT EXISTS scratch_exec (id INTEGER)", "params" => "[]" },
      "database_columns"   => { "table" => "widget" },
      "route_test"         => { "method" => "GET", "path" => "/hello", "body" => "", "headers" => "{}" },
      "template_render"    => { "template" => "Hello {{ name }}", "data" => "{\"name\":\"World\"}" },
      "file_read"          => { "path" => "notes.txt" },
      "file_write"         => { "path" => "src/routes/scratch_route.rb", "content" => "Tina4::Router.get('/scratch') { |_q,r| r.call({ok:true},200) }\n" },
      "file_patch"         => { "path" => "notes.txt", "old_string" => "PATCH_TARGET marker", "new_string" => "PATCHED marker", "count" => 1 },
      "file_list"          => { "path" => "." },
      "asset_upload"       => { "filename" => "probe.txt", "content" => "hello-asset", "encoding" => "utf-8" },
      "migration_create"   => { "description" => "scratch verify migration" },
      "queue_status"       => { "topic" => "default" },
      "log_tail"           => { "lines" => 10 },
      "error_log"          => { "limit" => 5 },
      "seed_table"         => { "table" => "widget", "count" => 2 },
      "docs_search"        => { "query" => "route", "limit" => 3, "context_lines" => 2 },
      "docs_section"       => { "file" => "CLAUDE.md", "heading" => "Build" },
      "index_search"       => { "query" => "widget", "limit" => 5 },
      "index_file"         => { "path" => "notes.txt" },
      "plan_create"        => { "title" => "Scratch Plan", "goal" => "verify", "steps" => %w[a b], "make_current" => true },
      "plan_switch_to"     => { "name" => "setup-plan" },
      "plan_complete_step" => { "index" => 0 },
      "plan_add_step"      => { "text" => "a new step" },
      "plan_note"          => { "text" => "a breadcrumb note" },
      "plan_archive"       => { "name" => "scratch-plan" },
      "plan_read"          => { "name" => "setup-plan" },
      "plan_flesh"         => { "name" => "setup-plan", "prompt" => "add steps" },
      "api_search"         => { "query" => "Database", "k" => 3 },
      "api_class"          => { "name" => "Database" },
      "api_method"         => { "class_name" => "Database", "name" => "fetch" },
      "code_search"        => { "query" => "widget", "k" => 3, "rebuild" => false }
    }

    report = { "tools" => {} }
    server.tools.keys.sort.each do |name|
      req = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                          "params" => { "name" => name, "arguments" => args[name] || {} })
      parsed = JSON.parse(server.handle_message(req))
      if parsed.key?("error")
        report["tools"][name] = { "status" => "RAISED", "message" => parsed.dig("error", "message").to_s[0, 300] }
      else
        text = parsed.dig("result", "content", 0, "text").to_s
        obj  = (JSON.parse(text) rescue text)
        errd = obj.is_a?(Hash) && obj.key?("error")
        report["tools"][name] = { "status" => errd ? "ERROR_DICT" : "OK", "text" => text[0, 400] }
      end
    rescue Exception => e
      report["tools"][name] = { "status" => "RAISED", "message" => "#{e.class}: #{e.message}"[0, 300] }
    end

    puts "<<<TINA4_MCP_CONFORMANCE_JSON>>>"
    puts JSON.generate(report)
    puts "<<<END>>>"
  RUBY

  it "invokes every registered dev tool: none raises, and the four fixed tools return real payloads" do
    report = nil
    output = nil
    Dir.mktmpdir("tina4-mcp-conformance") do |proj|
      FileUtils.mkdir_p(File.join(proj, "src", "templates"))
      FileUtils.mkdir_p(File.join(proj, "migrations"))
      File.write(File.join(proj, "notes.txt"), "PATCH_TARGET marker\n")

      output, = run_ruby(proj, SWEEP_DRIVER)
      json = output[/<<<TINA4_MCP_CONFORMANCE_JSON>>>\n(.*)\n<<<END>>>/m, 1]
      expect(json).not_to(be_nil, "sweep produced no report — subprocess likely crashed:\n#{output}")
      report = JSON.parse(json)
    end

    tools  = report["tools"]
    raised = tools.select { |_, v| v["status"] == "RAISED" }

    aggregate_failures "dev-MCP conformance sweep" do
      expect(tools.keys).not_to be_empty

      # Guarantee 1 — no tool raises an uncaught exception (JSON-RPC error).
      expect(raised).to eq({}),
        "tool(s) raised an uncaught exception:\n" +
        raised.map { |k, v| "  #{k}: #{v['message']}" }.join("\n")

      # Guarantee 2 — the four fixed tools return real, non-error payloads.
      FIXED_TOOLS.each do |t|
        entry = tools[t]
        expect(entry).not_to be_nil, "#{t} was never invoked"
        expect(entry["status"]).to(
          eq("OK"),
          "#{t} did not return a real payload (status=#{entry['status']}): #{entry['message'] || entry['text']}"
        )
      end

      # route_test — a real 200 through the TestClient auth gate.
      rt = JSON.parse(tools["route_test"]["text"])
      expect(rt["status"]).to eq(200)
      expect(rt["body"].to_s).to include("hi")

      # template_render — the rendered string (returned verbatim, not JSON).
      expect(tools["template_render"]["text"].strip).to eq("Hello World")

      # queue_status — real integer counts per status.
      qs = JSON.parse(tools["queue_status"]["text"])
      expect(qs["topic"]).to eq("default")
      expect(qs["pending"]).to be_a(Integer)
      expect(qs["completed"]).to be_a(Integer)
      expect(qs["failed"]).to be_a(Integer)

      # seed_table — canonical cross-framework shape {table, inserted:<int>, failed:<int>}
      # (inserted is the real SeedSummary#seeded count, NOT the summary object).
      st = JSON.parse(tools["seed_table"]["text"])
      expect(st["table"]).to eq("widget")
      expect(st["inserted"]).to be_a(Integer)
      expect(st["inserted"]).to eq(2)
      expect(st["failed"]).to be_a(Integer)
    end
  end

  # route_test's stringio NameError only bites when TestClient is the FIRST
  # thing touched on a clean boot — StringIO.new (test_client.rb) runs before
  # anything else pulls stringio in. Pre-fix this subprocess dies with
  # `uninitialized constant Tina4::TestClient::StringIO (NameError)`.
  it "route_test: TestClient serves a route on a clean `require \"tina4\"` (test_client requires stringio itself)" do
    Dir.mktmpdir("tina4-cleanboot-rt") do |dir|
      body = <<~'RUBY'
        # Only the framework — NOT `require "stringio"`. TestClient must pull it in.
        require "tina4"
        Tina4::Router.clear! rescue nil
        Tina4::Router.get("/__cleanboot") { |_q, r| r.call({ ok: true }, 200) }
        resp = Tina4::TestClient.new.get("/__cleanboot")
        puts "STATUS=#{resp.status}"
        puts "BODY=#{resp.body}"
      RUBY
      output, status = run_ruby(dir, body)
      expect(output).not_to include("NameError"),
        "clean boot crashed (stringio not required in test_client.rb):\n#{output}"
      expect(status).to be_success, "subprocess exited non-zero:\n#{output}"
      expect(output).to include("STATUS=200")
      expect(output).to include("BODY=")
    end
  end

  # seed_table (MCP tool)'s missing-autoload only bites before any tool has
  # referenced Tina4::FakeData. On a clean boot with the seeder unloaded, the
  # tool must force-load it. Pre-fix it returns a self-rescued
  # {"error":"undefined method 'seed_table' for module Tina4"} and inserts 0 rows.
  it "seed_table (MCP tool): force-loads the seeder on a clean boot and inserts real rows" do
    Dir.mktmpdir("tina4-cleanboot-seed") do |dir|
      body = <<~'RUBY'
        require "tina4"   # NOT tina4/dev — keep the seeder unloaded until the tool needs it
        require "json"
        Dir.chdir(ARGV[0])
        ENV["TINA4_LOG_LEVEL"] = "NONE"
        db = Tina4::Database.new("sqlite://seed.db")
        Tina4.bind_database(db)
        db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER)")
        db.commit rescue nil
        server = Tina4::McpServer.new("/__dev/mcp", name: "Seed")
        Tina4::McpDevTools.register(server)
        req = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                            "params" => { "name" => "seed_table", "arguments" => { "table" => "t", "count" => 2 } })
        text = JSON.parse(server.handle_message(req)).dig("result", "content", 0, "text").to_s
        rows = db.fetch("SELECT id FROM t").records.size
        puts "RESULT=#{text.gsub("\n", ' ')}"
        puts "ROWS=#{rows}"
      RUBY
      output, status = run_ruby(dir, body)
      expect(status).to be_success, "subprocess exited non-zero:\n#{output}"
      expect(output).not_to match(/undefined method 'seed_table'/),
        "seed_table tool did not force-load the seeder:\n#{output}"
      expect(output).to include("ROWS=2")
    end
  end

  # dev-admin POST /__dev/api/seed calls Tina4.seed_table too — same root cause,
  # same lock. Drive the REAL dispatcher (DevAdmin.handle_request) with a real
  # Rack env on a clean boot. Pre-fix it returns an {error: ...} body, 0 rows.
  it "dev-admin POST /__dev/api/seed: force-loads the seeder on a clean boot and inserts real rows" do
    Dir.mktmpdir("tina4-cleanboot-devseed") do |dir|
      body = <<~'RUBY'
        ENV["TINA4_DEBUG"] = "true"           # DevAdmin.handle_request is gated on debug
        ENV["TINA4_LOG_LEVEL"] = "NONE"
        require "tina4"   # NOT tina4/dev — keep the seeder unloaded until the endpoint needs it
        require "json"
        require "stringio" # test-side: to build the Rack env's rack.input (unrelated to the seeder bug)
        Dir.chdir(ARGV[0])
        db = Tina4::Database.new("sqlite://devseed.db")
        Tina4.bind_database(db)
        db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER)")
        db.commit rescue nil
        payload = JSON.generate("table" => "t", "count" => 2)
        env = {
          "REQUEST_METHOD" => "POST", "PATH_INFO" => "/__dev/api/seed", "QUERY_STRING" => "",
          "rack.input" => StringIO.new(payload), "CONTENT_LENGTH" => payload.bytesize.to_s,
          "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "127.0.0.1",
          "rack.url_scheme" => "http", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7145",
          "HTTP_HOST" => "localhost:7145"
        }
        status, _headers, rack_body = Tina4::DevAdmin.handle_request(env)
        resp = Array(rack_body).join
        rows = db.fetch("SELECT id FROM t").records.size
        puts "STATUS=#{status}"
        puts "RESP=#{resp.gsub("\n", ' ')}"
        puts "ROWS=#{rows}"
      RUBY
      output, status = run_ruby(dir, body)
      expect(status).to be_success, "subprocess exited non-zero:\n#{output}"
      expect(output).to include("STATUS=200"), "dev-admin seed endpoint not reachable:\n#{output}"
      expect(output).not_to match(/undefined method 'seed_table'/),
        "dev-admin seed endpoint did not force-load the seeder:\n#{output}"
      expect(output).to include("ROWS=2")
      expect(output).to match(/"seeded"\s*[:=]\s*2/)
    end
  end
end
