# frozen_string_literal: true

require "spec_helper"
require_relative "support/real_env"
require "json"
require "tmpdir"
require "stringio"
require "fileutils"

# The dev server exposes the default MCP server two ways:
#   • REST shim   — GET /__dev/api/mcp/tools, POST /__dev/api/mcp/call
#   • JSON-RPC+SSE — POST /__dev/mcp[/message], GET /__dev/mcp/sse
# Real MCP clients (Claude Code / Desktop) speak the JSON-RPC + SSE pair.
# These specs cover that pair on the same DevAdmin.handle_request dispatch
# the REST shim already uses, gated on the same TINA4_DEBUG check.
RSpec.describe "Tina4 dev MCP JSON-RPC + SSE endpoint" do
  # POST helper — build a Rack env with a JSON body and dispatch it.
  def post_jsonrpc(payload, path: "/__dev/mcp/message")
    env = {
      "PATH_INFO"      => path,
      "REQUEST_METHOD" => "POST",
      "QUERY_STRING"   => "",
      "rack.input"     => StringIO.new(payload.is_a?(String) ? payload : JSON.generate(payload))
    }
    Tina4::DevAdmin.handle_request(env)
  end

  def get_path(path)
    Tina4::DevAdmin.handle_request(
      "PATH_INFO" => path, "REQUEST_METHOD" => "GET", "QUERY_STRING" => ""
    )
  end

  def delete_path(path)
    Tina4::DevAdmin.handle_request(
      "PATH_INFO" => path, "REQUEST_METHOD" => "DELETE", "QUERY_STRING" => ""
    )
  end

  around(:each) do |example|
    # Dispatch calls auto_discover_mcp! which writes .tina4/mcp.json to the
    # CWD — run inside a tmpdir so nothing lands in the repo working tree.
    Dir.mktmpdir do |tmp|
      old = Dir.pwd
      Dir.chdir(tmp)
      begin
        Tina4::Router.clear!
        Tina4::Router.get("/hello") { |_req, res| res.call("hi") }
        Tina4::Router.post("/things") { |_req, res| res.call("ok") }
        example.run
      ensure
        Dir.chdir(old)
      end
    end
  end

  context "when debug mode is enabled" do
    before do
      set_real_env("TINA4_DEBUG" => "true")
    end

    describe "endpoint registration" do
      it "dispatches POST /__dev/mcp/message to the real JSON-RPC ping handler" do
        result = post_jsonrpc({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => {} })
        expect(result).not_to be_nil
        status, _headers, body = result
        expect(status).to eq(200)
        # 200 alone only proves routing; parse the body and assert the real
        # JSON-RPC ping result the McpServer#_handle_ping handler returns ({}).
        msg = JSON.parse(body.first)
        expect(msg["jsonrpc"]).to eq("2.0")
        expect(msg["id"]).to eq(1)
        expect(msg["result"]).to eq({})
      end

      it "dispatches the bare POST /__dev/mcp alias to the same JSON-RPC ping handler" do
        result = post_jsonrpc(
          { "jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => {} },
          path: "/__dev/mcp"
        )
        status, _headers, body = result
        expect(status).to eq(200)
        # Confirm the alias reaches the same real ping handler, not just any 200:
        # the body must be the empty-object ping result keyed back to our id.
        msg = JSON.parse(body.first)
        expect(msg["jsonrpc"]).to eq("2.0")
        expect(msg["id"]).to eq(1)
        expect(msg["result"]).to eq({})
      end
    end

    describe "initialize handshake" do
      it "returns serverInfo and protocol version" do
        status, headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
          "params"  => { "protocolVersion" => "2024-11-05", "capabilities" => {}, "clientInfo" => { "name" => "rspec" } }
        })
        expect(status).to eq(200)
        expect(headers["content-type"]).to include("application/json")
        msg = JSON.parse(body.first)
        expect(msg["jsonrpc"]).to eq("2.0")
        expect(msg["result"]["serverInfo"]["name"]).to eq("Tina4 Dev Tools")
        expect(msg["result"]).to have_key("protocolVersion")
        expect(msg["result"]["capabilities"]).to have_key("tools")
      end
    end

    describe "tools/list" do
      it "lists the built-in dev tools" do
        _status, _headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => {}
        })
        msg = JSON.parse(body.first)
        names = msg["result"]["tools"].map { |t| t["name"] }
        expect(names).to include("route_list", "database_query", "file_read")
        expect(msg["result"]["tools"]).not_to be_empty
      end
    end

    describe "tools/call (safe read-only tool)" do
      it "returns real route content via route_list" do
        _status, _headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
          "params"  => { "name" => "route_list", "arguments" => {} }
        })
        msg = JSON.parse(body.first)
        expect(msg).to have_key("result")
        text = msg["result"]["content"][0]["text"]
        routes = JSON.parse(text)
        paths = routes.map { |r| r["path"] }
        expect(paths).to include("/hello", "/things")
        # route_list must return real data, not the pre-fix subscript error.
        expect(text).not_to include("undefined method")
      end
    end

    describe "unknown tool" do
      it "returns a JSON-RPC error" do
        _status, _headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "id" => 4, "method" => "tools/call",
          "params"  => { "name" => "does_not_exist", "arguments" => {} }
        })
        msg = JSON.parse(body.first)
        expect(msg).to have_key("error")
        expect(msg["error"]["code"]).to eq(-32_603)
      end
    end

    describe "notification (no id)" do
      it "returns an empty 202 (Streamable HTTP accepts the notification)" do
        status, _headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "method" => "notifications/initialized"
        })
        expect(status).to eq(202)
        expect(body).to eq([])
      end
    end

    describe "Streamable HTTP session + method handling" do
      it "issues an Mcp-Session-Id on initialize (POST /__dev/mcp)" do
        status, headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
          "params"  => { "protocolVersion" => "2025-06-18" }
        }, path: "/__dev/mcp")
        expect(status).to eq(200)
        expect(headers["Mcp-Session-Id"]).to be_a(String)
        expect(headers["Mcp-Session-Id"]).not_to be_empty
        expect(JSON.parse(body.first)["result"]["protocolVersion"]).to eq("2025-06-18")
      end

      it "405s a GET on the endpoint with Allow: POST, DELETE" do
        status, headers, _body = get_path("/__dev/mcp")
        expect(status).to eq(405)
        expect(headers["allow"]).to eq("POST, DELETE")
      end

      it "204s a DELETE on the endpoint (session termination)" do
        status, _headers, body = delete_path("/__dev/mcp")
        expect(status).to eq(204)
        expect(body).to eq([])
      end
    end

    describe "SSE handshake" do
      it "emits the endpoint event with text/event-stream" do
        status, headers, body = get_path("/__dev/mcp/sse")
        expect(status).to eq(200)
        expect(headers["content-type"]).to eq("text/event-stream")
        expect(body.first).to include("event: endpoint")
        expect(body.first).to include("data: /__dev/mcp/message")
      end
    end
  end

  context "when debug mode is disabled" do
    before do
      set_real_env("TINA4_DEBUG" => nil)
    end

    it "404s (handle_request returns nil) for POST /__dev/mcp/message" do
      expect(post_jsonrpc({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" })).to be_nil
    end

    it "404s (handle_request returns nil) for GET /__dev/mcp/sse" do
      expect(get_path("/__dev/mcp/sse")).to be_nil
    end
  end

  # The MCP dev tools expose powerful ops (DB query, file read/WRITE, route
  # list). After the 3.13.40 capability/per-request split, TINA4_DEBUG=true
  # turns the capability ON regardless of host; what stops a REMOTE caller is
  # the per-request gate driven by the RAW socket peer (REMOTE_ADDR), never
  # X-Forwarded-For. A remote caller is denied unless TINA4_MCP_REMOTE=true AND
  # a valid TINA4_MCP_TOKEN is presented.
  context "when debug mode is enabled and the caller is REMOTE" do
    # Build an env with an explicit raw socket peer + optional headers.
    def post_remote(payload, remote_ip:, headers: {}, path: "/__dev/mcp/message")
      env = {
        "PATH_INFO"      => path,
        "REQUEST_METHOD" => "POST",
        "QUERY_STRING"   => "",
        "REMOTE_ADDR"    => remote_ip,
        "rack.input"     => StringIO.new(payload.is_a?(String) ? payload : JSON.generate(payload))
      }.merge(headers)
      Tina4::DevAdmin.handle_request(env)
    end

    def get_remote(path, remote_ip:, headers: {})
      Tina4::DevAdmin.handle_request({
        "PATH_INFO" => path, "REQUEST_METHOD" => "GET",
        "QUERY_STRING" => "", "REMOTE_ADDR" => remote_ip
      }.merge(headers))
    end

    before do
      set_real_env("TINA4_DEBUG" => "true")
      set_real_env("TINA4_MCP" => nil)
      set_real_env("TINA4_MCP_REMOTE" => nil)
      set_real_env("TINA4_MCP_TOKEN" => nil)
      set_real_env("TINA4_API_KEY" => nil)
    end

    it "404s a remote caller with no opt-in (POST /__dev/mcp/message)" do
      status, = post_remote({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }, remote_ip: "8.8.8.8")
      expect(status).to eq(404)
    end

    it "404s a remote caller for GET /__dev/mcp/sse" do
      status, = get_remote("/__dev/mcp/sse", remote_ip: "8.8.8.8")
      expect(status).to eq(404)
    end

    it "ignores a spoofed X-Forwarded-For — the raw peer still governs" do
      status, = post_remote(
        { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" },
        remote_ip: "8.8.8.8", headers: { "HTTP_X_FORWARDED_FOR" => "127.0.0.1" }
      )
      expect(status).to eq(404)
    end

    it "still denies a remote opt-in WITHOUT a valid token" do
      set_real_env("TINA4_MCP_REMOTE" => "true")
      status, = post_remote({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }, remote_ip: "8.8.8.8")
      expect(status).to eq(404)
    end

    it "allows a remote caller with TINA4_MCP_REMOTE + a valid bearer token" do
      set_real_env("TINA4_MCP_REMOTE" => "true")
      set_real_env("TINA4_MCP_TOKEN" => "s3cr3t-token")
      status, = post_remote(
        { "jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => {} },
        remote_ip: "8.8.8.8", headers: { "HTTP_AUTHORIZATION" => "Bearer s3cr3t-token" }
      )
      expect(status).to eq(200)
    end

    it "denies a remote caller presenting the WRONG token" do
      set_real_env("TINA4_MCP_REMOTE" => "true")
      set_real_env("TINA4_MCP_TOKEN" => "s3cr3t-token")
      status, = post_remote(
        { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" },
        remote_ip: "8.8.8.8", headers: { "HTTP_AUTHORIZATION" => "Bearer wrong" }
      )
      expect(status).to eq(404)
    end
  end

  # ── Tool coverage ──────────────────────────────────────────────
  #
  # Assert the core tool set is registered on the shared default server and
  # that a handful of safe read-only tools execute without a protocol error
  # (an in-band {"error": "No database connection"} result is fine — that's
  # a tool result, not a JSON-RPC error). This is the coverage that catches
  # broken tools like the route_list subscript bug.
  describe "dev tool coverage" do
    before do
      set_real_env("TINA4_DEBUG" => "true")
    end

    CORE_TOOLS = %w[
      database_query database_execute file_read file_write file_list
      route_list migration_status plan_list plan_create log_tail
      docs_list project_overview
    ].freeze

    it "registers the core tool set on the default MCP server" do
      server = Tina4._default_mcp_server
      CORE_TOOLS.each do |name|
        expect(server.tools).to have_key(name), "expected MCP tool '#{name}' to be registered"
      end
    end

    %w[route_list file_list plan_list docs_list log_tail project_overview].each do |tool|
      it "executes #{tool} without a JSON-RPC protocol error" do
        _status, _headers, body = post_jsonrpc({
          "jsonrpc" => "2.0", "id" => 9, "method" => "tools/call",
          "params"  => { "name" => tool, "arguments" => {} }
        })
        msg = JSON.parse(body.first)
        # Top-level "error" = protocol failure (unknown tool / raised exception).
        expect(msg).not_to have_key("error"), "#{tool} raised a protocol error: #{msg["error"]}"
        expect(msg["result"]["content"][0]["type"]).to eq("text")
      end
    end
  end

  # ── /call REST INVOCATION shim gate (MCP-02 lock-in) ───────────────
  #
  # POST /__dev/api/mcp/call is the tool-INVOCATION REST shim: it RUNS a named
  # tool (database_execute / file_write / …) with caller-supplied arguments.
  # In the Python master this exact shim shipped UNGATED, so on a
  # TINA4_DEBUG=true 0.0.0.0-bound server a remote unauthenticated caller could
  # POST {"name":"database_execute","arguments":{"sql":"INSERT …"}} and mutate
  # the DB (now fixed). Ruby wraps /call in with_mcp_gate — the SAME gate as
  # every other MCP surface (lib/tina4/dev_admin.rb: the /call route + gate).
  #
  # The remote/spoofed-XFF specs ABOVE drive /__dev/mcp[/message]; the
  # Python hole survived precisely because no spec drove the /call surface
  # itself. THESE examples close that gap: they build a REAL Rack env for
  # POST /__dev/api/mcp/call, dispatch it through the REAL
  # Tina4::DevAdmin.handle_request, and prove the gate with a REAL SQLite
  # write-WITNESS — a denied call must not merely 404, it must never reach the
  # INSERT (assert the actual row count through the same bound connection).
  context "when a REMOTE caller hits the /call INVOCATION shim (database_execute)" do
    # Real Rack env for POST /__dev/api/mcp/call — the same shape and the same
    # dispatch entrypoint the shipping server uses; no mocks, no test double.
    def post_call(name, arguments, remote_ip:, headers: {})
      env = {
        "PATH_INFO"      => "/__dev/api/mcp/call",
        "REQUEST_METHOD" => "POST",
        "QUERY_STRING"   => "",
        "REMOTE_ADDR"    => remote_ip,
        "rack.input"     => StringIO.new(JSON.generate("name" => name, "arguments" => arguments))
      }.merge(headers)
      Tina4::DevAdmin.handle_request(env)
    end

    # The write-witness: count probe rows through the SAME real connection the
    # database_execute tool writes to (Tina4.database). A real query, never a
    # stubbed value — if the INSERT ran, this is 1; if the gate blocked it, 0.
    def probe_row_count
      # The sqlite driver returns rows with SYMBOL keys ({ n: 1 }).
      Tina4.database.fetch_one("SELECT COUNT(*) AS n FROM mcp_probe")[:n].to_i
    end

    # let, not a bare constant — a constant inside an RSpec block lands on Object
    # and clobbers other spec files (see the ruby-constants-are-global lesson).
    let(:insert_sql) { "INSERT INTO mcp_probe (marker) VALUES ('pwned')" }

    before do
      set_real_env("TINA4_DEBUG" => "true")   # capability ON (mcp_enabled?)
      set_real_env("TINA4_MCP" => nil)
      set_real_env("TINA4_MCP_REMOTE" => nil)
      set_real_env("TINA4_MCP_TOKEN" => nil)
      set_real_env("TINA4_API_KEY" => nil)

      # Bind a REAL SQLite DB (temp file) with a probe table. database_execute
      # writes through Tina4.database; spec_helper resets the binding after each
      # example, and the after-hook below closes the connection + removes the dir.
      @db_dir = Dir.mktmpdir
      db = Tina4::Database.new("sqlite:///" + File.join(@db_dir, "probe.db"))
      db.execute("CREATE TABLE mcp_probe (id INTEGER PRIMARY KEY, marker TEXT)")
      Tina4.bind_database(db)
    end

    after do
      Tina4.database&.close rescue nil
      FileUtils.remove_entry(@db_dir) if @db_dir && File.directory?(@db_dir)
    end

    it "404s a remote caller with NO token and never reaches the INSERT" do
      expect(probe_row_count).to eq(0)
      status, _headers, body = post_call(
        "database_execute", { "sql" => insert_sql }, remote_ip: "8.8.8.8"
      )
      expect(status).to eq(404)
      expect(body.first).to include("MCP forbidden")
      # Write-witness: the gate blocked BEFORE the tool ran — no row inserted.
      expect(probe_row_count).to eq(0)
    end

    it "runs the tool and INSERTS the row for a remote caller with TINA4_MCP_REMOTE + a valid bearer token" do
      set_real_env("TINA4_MCP_REMOTE" => "true")
      set_real_env("TINA4_MCP_TOKEN" => "s3cr3t-token")
      expect(probe_row_count).to eq(0)
      status, _headers, _body = post_call(
        "database_execute", { "sql" => insert_sql },
        remote_ip: "8.8.8.8", headers: { "HTTP_AUTHORIZATION" => "Bearer s3cr3t-token" }
      )
      expect(status).to eq(200)
      # Write-witness: the authorised call actually ran the INSERT (positive control —
      # rules out a gate that simply 404s everything).
      expect(probe_row_count).to eq(1)
    end

    it "ignores a spoofed X-Forwarded-For on /call — the raw peer governs, no row inserted" do
      expect(probe_row_count).to eq(0)
      status, _headers, body = post_call(
        "database_execute", { "sql" => insert_sql },
        remote_ip: "8.8.8.8", headers: { "HTTP_X_FORWARDED_FOR" => "127.0.0.1" }
      )
      expect(status).to eq(404)
      expect(body.first).to include("MCP forbidden")
      # Proves REMOTE_ADDR governs, not the spoofable XFF — no row inserted.
      expect(probe_row_count).to eq(0)
    end
  end
end
