# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/tina4/mcp"

RSpec.describe "Tina4 MCP" do
  # ── JSON-RPC 2.0 codec ────────────────────────────────────────

  describe Tina4::McpProtocol do
    describe ".encode_response" do
      it "encodes a successful JSON-RPC 2.0 response" do
        raw = described_class.encode_response(1, { "tools" => [] })
        msg = JSON.parse(raw)
        expect(msg["jsonrpc"]).to eq("2.0")
        expect(msg["id"]).to eq(1)
        expect(msg["result"]).to eq({ "tools" => [] })
      end
    end

    describe ".encode_error" do
      it "encodes an error with code and message" do
        raw = described_class.encode_error(2, Tina4::McpProtocol::METHOD_NOT_FOUND, "Not found")
        msg = JSON.parse(raw)
        expect(msg["jsonrpc"]).to eq("2.0")
        expect(msg["id"]).to eq(2)
        expect(msg["error"]["code"]).to eq(-32_601)
        expect(msg["error"]["message"]).to eq("Not found")
      end

      it "includes data when provided" do
        raw = described_class.encode_error(3, Tina4::McpProtocol::INTERNAL_ERROR, "fail", { "detail" => "x" })
        msg = JSON.parse(raw)
        expect(msg["error"]["data"]).to eq({ "detail" => "x" })
      end
    end

    describe ".encode_notification" do
      it "encodes a notification without id" do
        raw = described_class.encode_notification("notifications/initialized")
        msg = JSON.parse(raw)
        expect(msg["jsonrpc"]).to eq("2.0")
        expect(msg["method"]).to eq("notifications/initialized")
        expect(msg).not_to have_key("id")
      end
    end

    describe ".decode_request" do
      it "decodes a valid request" do
        method, params, rid = described_class.decode_request(JSON.generate({
          "jsonrpc" => "2.0",
          "id"      => 3,
          "method"  => "tools/list",
          "params"  => {}
        }))
        expect(method).to eq("tools/list")
        expect(params).to eq({})
        expect(rid).to eq(3)
      end

      it "decodes a notification (no id)" do
        method, params, rid = described_class.decode_request({
          "jsonrpc" => "2.0",
          "method"  => "notifications/initialized"
        })
        expect(method).to eq("notifications/initialized")
        expect(rid).to be_nil
      end

      it "accepts a Hash directly" do
        method, _, rid = described_class.decode_request({
          "jsonrpc" => "2.0",
          "id"      => 5,
          "method"  => "ping"
        })
        expect(method).to eq("ping")
        expect(rid).to eq(5)
      end

      it "raises on invalid JSON string" do
        expect { described_class.decode_request("not json") }
          .to raise_error(ArgumentError, /Invalid JSON/)
      end

      it "raises when method is missing" do
        expect { described_class.decode_request({ "jsonrpc" => "2.0", "id" => 1 }) }
          .to raise_error(ArgumentError, /method/)
      end

      it "raises when jsonrpc version is missing" do
        expect { described_class.decode_request({ "method" => "test", "id" => 1 }) }
          .to raise_error(ArgumentError, /jsonrpc/)
      end
    end
  end

  # ── McpServer core ────────────────────────────────────────────

  describe Tina4::McpServer do
    let(:server) { described_class.new("/test-mcp", name: "Test Server", version: "0.1.0") }

    describe "initialize handshake" do
      it "returns protocol version, capabilities, and server info" do
        resp = JSON.parse(server.handle_message({
          "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
          "params"  => {
            "protocolVersion" => "2024-11-05",
            "capabilities"    => {},
            "clientInfo"      => { "name" => "test", "version" => "1.0" }
          }
        }))
        expect(resp["result"]["protocolVersion"]).to eq("2024-11-05")
        expect(resp["result"]["serverInfo"]["name"]).to eq("Test Server")
        expect(resp["result"]["capabilities"]).to have_key("tools")
      end
    end

    describe "ping" do
      it "returns an empty result" do
        resp = JSON.parse(server.handle_message({
          "jsonrpc" => "2.0", "id" => 2, "method" => "ping", "params" => {}
        }))
        expect(resp["result"]).to eq({})
      end
    end

    describe "method not found" do
      it "returns error code -32601" do
        resp = JSON.parse(server.handle_message({
          "jsonrpc" => "2.0", "id" => 3, "method" => "nonexistent", "params" => {}
        }))
        expect(resp["error"]["code"]).to eq(-32_601)
      end
    end

    describe "notification" do
      it "returns empty string (no response)" do
        resp = server.handle_message({
          "jsonrpc" => "2.0", "method" => "notifications/initialized"
        })
        expect(resp).to eq("")
      end
    end
  end

  # ── Tool registration and invocation ──────────────────────────

  describe "Tool registration" do
    let(:server) { Tina4::McpServer.new("/test-tools", name: "Tool Test") }

    it "registers a tool and lists it" do
      greet = lambda { |name:| "Hello, #{name}!" }
      server.register_tool("greet", greet, "Greet someone")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {}
      }))
      tools = resp["result"]["tools"]
      expect(tools.length).to eq(1)
      expect(tools[0]["name"]).to eq("greet")
      expect(tools[0]["inputSchema"]["properties"]).to have_key("name")
    end

    it "calls a tool and returns the result" do
      add = lambda { |a:, b:| (a.to_i + b.to_i).to_s }
      server.register_tool("add", add, "Add two numbers")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
        "params"  => { "name" => "add", "arguments" => { "a" => 3, "b" => 5 } }
      }))
      content = resp["result"]["content"]
      expect(content.length).to eq(1)
      expect(content[0]["type"]).to eq("text")
      expect(content[0]["text"]).to include("8")
    end

    it "returns error for unknown tool" do
      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
        "params"  => { "name" => "missing", "arguments" => {} }
      }))
      expect(resp["error"]["code"]).to eq(-32_603)
    end

    it "handles tools returning hashes" do
      info = lambda { { "version" => "1.0", "status" => "ok" } }
      server.register_tool("info", info, "Get info")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 4, "method" => "tools/call",
        "params"  => { "name" => "info", "arguments" => {} }
      }))
      text = resp["result"]["content"][0]["text"]
      data = JSON.parse(text)
      expect(data["version"]).to eq("1.0")
    end

    it "handles tools returning arrays" do
      items = lambda { [1, 2, 3] }
      server.register_tool("items", items, "Get items")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 5, "method" => "tools/call",
        "params"  => { "name" => "items", "arguments" => {} }
      }))
      text = resp["result"]["content"][0]["text"]
      data = JSON.parse(text)
      expect(data).to eq([1, 2, 3])
    end
  end

  # ── Schema from method ────────────────────────────────────────

  describe "Tina4.schema_from_method" do
    it "extracts required and optional keyword params" do
      handler = lambda { |name:, count: 5, active: true| }
      schema = Tina4.schema_from_method(handler)

      expect(schema["properties"]["name"]["type"]).to eq("string")
      expect(schema["properties"]["count"]["type"]).to eq("string")
      expect(schema["properties"]["active"]["type"]).to eq("string")
      expect(schema["required"]).to eq(["name"])
    end

    it "handles methods with no parameters" do
      handler = lambda { "hello" }
      schema = Tina4.schema_from_method(handler)

      expect(schema["type"]).to eq("object")
      expect(schema["properties"]).to eq({})
      expect(schema).not_to have_key("required")
    end

    it "handles positional parameters" do
      handler = lambda { |a, b| a + b }
      schema = Tina4.schema_from_method(handler)

      expect(schema["properties"]).to have_key("a")
      expect(schema["properties"]).to have_key("b")
      expect(schema["required"]).to eq(%w[a b])
    end
  end

  # ── Class method tools ────────────────────────────────────────

  describe "Class method tools" do
    let(:server) { Tina4::McpServer.new("/test-class-tools", name: "Class Tool Test") }

    it "registers and calls a bound method" do
      klass = Class.new do
        def report(month:, year:)
          "Report for #{month} #{year}"
        end
      end
      svc = klass.new
      server.register_tool("report", svc.method(:report), "Generate report")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 4, "method" => "tools/call",
        "params"  => { "name" => "report", "arguments" => { "month" => "March", "year" => 2026 } }
      }))
      expect(resp["result"]["content"][0]["text"]).to include("March 2026")
    end
  end

  # ── Resource registration and reading ─────────────────────────

  describe "Resource registration" do
    let(:server) { Tina4::McpServer.new("/test-resources", name: "Resource Test") }

    it "registers a resource and lists it" do
      server.register_resource("app://tables", lambda { %w[users products] }, "Database tables")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 1, "method" => "resources/list", "params" => {}
      }))
      resources = resp["result"]["resources"]
      expect(resources.length).to eq(1)
      expect(resources[0]["uri"]).to eq("app://tables")
    end

    it "reads a resource" do
      server.register_resource("app://info", lambda { { "version" => "1.0", "name" => "Test App" } }, "App info")

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 2, "method" => "resources/read",
        "params"  => { "uri" => "app://info" }
      }))
      contents = resp["result"]["contents"]
      expect(contents.length).to eq(1)
      data = JSON.parse(contents[0]["text"])
      expect(data["version"]).to eq("1.0")
    end

    it "returns error for unknown resource" do
      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 3, "method" => "resources/read",
        "params"  => { "uri" => "app://missing" }
      }))
      expect(resp["error"]["code"]).to eq(-32_603)
    end
  end

  # ── Decorator-style API ───────────────────────────────────────

  describe "Tina4.mcp_tool / Tina4.mcp_resource" do
    it "registers a tool via mcp_tool" do
      server = Tina4::McpServer.new("/test-decorator", name: "Decorator Test")
      Tina4.mcp_tool("hello", description: "Say hello", server: server) do |name:|
        "Hello, #{name}!"
      end

      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params"  => { "name" => "hello", "arguments" => { "name" => "World" } }
      }))
      expect(resp["result"]["content"][0]["text"]).to include("Hello, World!")
    end

    it "registers a resource via mcp_resource" do
      server = Tina4::McpServer.new("/test-decorator2", name: "Decorator Test 2")
      Tina4.mcp_resource("test://data", description: "Test data", server: server) do
        [1, 2, 3]
      end

      expect(server.resources).to have_key("test://data")
    end
  end

  # ── Localhost detection ───────────────────────────────────────

  describe "Tina4.is_localhost?" do
    around(:each) do |example|
      old = ENV["TINA4_HOST_NAME"]
      example.run
      if old.nil?
        ENV.delete("TINA4_HOST_NAME")
      else
        ENV["TINA4_HOST_NAME"] = old
      end
    end

    it "returns true for localhost" do
      ENV["TINA4_HOST_NAME"] = "localhost:7145"
      expect(Tina4.is_localhost?).to be true
    end

    it "returns true for 127.0.0.1" do
      ENV["TINA4_HOST_NAME"] = "127.0.0.1:7145"
      expect(Tina4.is_localhost?).to be true
    end

    it "returns true for 0.0.0.0" do
      ENV["TINA4_HOST_NAME"] = "0.0.0.0:7145"
      expect(Tina4.is_localhost?).to be true
    end

    it "returns false for remote host" do
      ENV["TINA4_HOST_NAME"] = "myserver.example.com:7145"
      expect(Tina4.is_localhost?).to be false
    end
  end

  # ── File sandbox ──────────────────────────────────────────────

  describe "File sandbox" do
    it "rejects paths that escape the project directory (file_read)" do
      Dir.mktmpdir do |tmp|
        server = Tina4::McpServer.new("/test-sandbox", name: "Sandbox Test")
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          Tina4::McpDevTools.register(server)

          resp = JSON.parse(server.handle_message({
            "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
            "params"  => { "name" => "file_read", "arguments" => { "path" => "../../../etc/passwd" } }
          }))
          expect(resp).to have_key("error")
          expect(resp["error"]["message"].downcase).to match(/escapes|path/)
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "rejects paths that escape the project directory (file_write)" do
      Dir.mktmpdir do |tmp|
        server = Tina4::McpServer.new("/test-sandbox2", name: "Sandbox Test 2")
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          Tina4::McpDevTools.register(server)

          resp = JSON.parse(server.handle_message({
            "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
            "params"  => { "name" => "file_write", "arguments" => { "path" => "../../evil.txt", "content" => "hacked" } }
          }))
          expect(resp).to have_key("error")
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end
  end

  # ── write_claude_config ───────────────────────────────────────

  describe "McpServer#write_claude_config" do
    it "writes .claude/settings.json with the MCP server URL" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/my-mcp", name: "My Tools")
          server.write_claude_config(7145)

          config_file = File.join(tmp, ".claude", "settings.json")
          expect(File.exist?(config_file)).to be true

          config = JSON.parse(File.read(config_file))
          expect(config["mcpServers"]["my-tools"]["url"]).to eq("http://localhost:7145/my-mcp/sse")
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end
  end

  # ── Defensive file_write / file_patch ─────────────────────────
  #
  # Five guards lifted from tina4_python/tina4_python/mcp/tools.py:
  # prose-path rejection, coder-path normalization, agent_log,
  # agent_backup, and the truncation guard. Mirrors the defensive
  # parity push for Tier 1 of the AI agent surface.

  describe "Defensive file_write" do
    def call_tool(server, name, args)
      resp = JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params"  => { "name" => name, "arguments" => args }
      }))
      resp
    end

    it "refuses prose paths in file_write" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-prose", name: "Prose Test")
          Tina4::McpDevTools.register(server)

          resp = call_tool(server, "file_write", {
            "path"    => "The plan requires implementing a feature.txt",
            "content" => "hello"
          })
          # safe_path raises ArgumentError → JSON-RPC top-level error.
          expect(resp).to have_key("error")
          expect(resp["error"]["message"]).to match(/Invalid path|prose|illegal character/)
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "normalizes bare routes/ to src/routes/" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-norm", name: "Normalize Test")
          Tina4::McpDevTools.register(server)

          resp = call_tool(server, "file_write", {
            "path"    => "routes/foo.rb",
            "content" => "Tina4::Router.get('/foo') { }\n"
          })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])
          expect(body["written"]).to eq("src/routes/foo.rb")

          # The file landed at src/routes/foo.rb, not routes/foo.rb.
          expect(File.file?(File.join(tmp, "src", "routes", "foo.rb"))).to be true
          expect(File.exist?(File.join(tmp, "routes", "foo.rb"))).to be false

          # Agent log records the rewrite.
          log_path = File.join(tmp, ".tina4", "agent.log")
          expect(File.exist?(log_path)).to be true
          expect(File.read(log_path)).to include("write.path_normalized")
          expect(File.read(log_path)).to include("routes/foo.rb")
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "backs up existing file before overwrite" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-backup", name: "Backup Test")
          Tina4::McpDevTools.register(server)

          # First write: creates the file (no backup expected).
          call_tool(server, "file_write", { "path" => "src/notes.txt", "content" => "version one" })

          # Second write: should produce a backup of the original.
          resp = call_tool(server, "file_write", { "path" => "src/notes.txt", "content" => "version two" })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])
          expect(body["backup"]).to be_a(String)
          expect(body["backup"]).to start_with(".tina4/backups/")

          backup_full = File.join(tmp, body["backup"])
          expect(File.exist?(backup_full)).to be true
          expect(File.read(backup_full)).to eq("version one")
          expect(File.read(File.join(tmp, "src", "notes.txt"))).to eq("version two")
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "refuses suspicious truncation" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-trunc", name: "Truncation Test")
          Tina4::McpDevTools.register(server)

          # Seed a 500-byte file.
          big_content = "x" * 500
          call_tool(server, "file_write", { "path" => "src/big.txt", "content" => big_content })

          # Attempt to overwrite with a much smaller payload (~50 bytes).
          tiny_content = "y" * 50
          resp = call_tool(server, "file_write", { "path" => "src/big.txt", "content" => tiny_content })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])
          expect(body["refused"]).to be true
          expect(body["error"]).to include("REFUSED")

          # Original file intact.
          expect(File.read(File.join(tmp, "src", "big.txt"))).to eq(big_content)

          # Audit log contains the refusal.
          log_path = File.join(tmp, ".tina4", "agent.log")
          expect(File.exist?(log_path)).to be true
          expect(File.read(log_path)).to include("write.refused")
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "lets canonical src/ paths pass through" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-passthrough", name: "Passthrough Test")
          Tina4::McpDevTools.register(server)

          resp = call_tool(server, "file_write", {
            "path"    => "src/routes/foo.rb",
            "content" => "Tina4::Router.get('/foo') { }\n"
          })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])
          expect(body["written"]).to eq("src/routes/foo.rb")

          # No path_normalized log entry — canonical path bypasses rewrite.
          log_path = File.join(tmp, ".tina4", "agent.log")
          if File.exist?(log_path)
            expect(File.read(log_path)).not_to include("write.path_normalized")
          end
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "catches Ruby syntax errors via ruby -c" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-syntax", name: "Syntax Test")
          Tina4::McpDevTools.register(server)

          # Broken Ruby — missing closing paren AND `end` keyword.
          broken = "def foo\n  bar(\n"
          resp = call_tool(server, "file_write", {
            "path"    => "src/routes/broken.rb",
            "content" => broken
          })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])

          # The file was still written, but with an import_error attached.
          expect(body["written"]).to eq("src/routes/broken.rb")
          expect(body).to have_key("import_error")
          expect(body["import_error"]).to match(/syntax error|unexpected/i)
          # The absolute project_root prefix should be stripped so the
          # error reads as src/routes/broken.rb:..., not /Users/...
          expect(body["import_error"]).not_to include(tmp)

          # Audit log records the import failure.
          log_path = File.join(tmp, ".tina4", "agent.log")
          expect(File.exist?(log_path)).to be true
          expect(File.read(log_path)).to include("write.import_failed")
          expect(File.read(log_path)).to include("src/routes/broken.rb")
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "skips non-Ruby files" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-skip-ext", name: "Skip Ext Test")
          Tina4::McpDevTools.register(server)

          # Content that would be invalid Ruby — but the file is .twig,
          # so ruby -c should never run against it.
          resp = call_tool(server, "file_write", {
            "path"    => "src/templates/foo.twig",
            "content" => "def foo\n  bar(\n"
          })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])
          expect(body["written"]).to eq("src/templates/foo.twig")
          expect(body).not_to have_key("import_error")

          # No import_failed entry in the log.
          log_path = File.join(tmp, ".tina4", "agent.log")
          if File.exist?(log_path)
            expect(File.read(log_path)).not_to include("write.import_failed")
          end
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end

    it "skips files outside src/" do
      Dir.mktmpdir do |tmp|
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-skip-dir", name: "Skip Dir Test")
          Tina4::McpDevTools.register(server)

          # tests/ is in the passthrough list, so the path won't be
          # normalized to src/. Even though the content is broken
          # Ruby, the syntax check only runs for files under src/.
          resp = call_tool(server, "file_write", {
            "path"    => "tests/foo.rb",
            "content" => "def foo\n  bar(\n"
          })
          expect(resp).to have_key("result")
          body = JSON.parse(resp["result"]["content"][0]["text"])
          expect(body["written"]).to eq("tests/foo.rb")
          expect(body).not_to have_key("import_error")

          # No import_failed entry in the log.
          log_path = File.join(tmp, ".tina4", "agent.log")
          if File.exist?(log_path)
            expect(File.read(log_path)).not_to include("write.import_failed")
          end
        ensure
          Dir.chdir(old_cwd)
        end
      end
    end
  end
end
