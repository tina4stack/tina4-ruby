# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe "Tina4::DevAdmin parity routes" do
  def make_env(method, path, query: "", body: nil)
    input = body ? StringIO.new(body.is_a?(String) ? body : JSON.generate(body)) : StringIO.new("")
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => query,
      "rack.input"     => input
    }
  end

  around(:each) do |ex|
    Dir.mktmpdir("tina4da") do |tmp|
      Dir.chdir(tmp) do
        ENV["TINA4_DEBUG"] = "true"
        ex.run
      ensure
        ENV.delete("TINA4_DEBUG")
      end
    end
  end

  it "returns JSON for GET /__dev/api/git/status even when not a git repo" do
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/git/status"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    # Either error (not a repo) or has branch/status keys
    expect(data.key?("error") || data.key?("branch")).to be true
  end

  it "lists files under project root" do
    File.write("hello.txt", "hi")
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/files"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    names = data["entries"].map { |e| e["name"] }
    expect(names).to include("hello.txt")
  end

  it "reads a file via /__dev/api/file" do
    File.write("a.md", "# test\n")
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/file", query: "path=a.md"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    expect(data["content"]).to eq("# test\n")
  end

  it "saves a file via /__dev/api/file/save" do
    status, _, body = Tina4::DevAdmin.handle_request(
      make_env("POST", "/__dev/api/file/save", body: { path: "x.txt", content: "new" })
    )
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    expect(data["saved"]).to eq("x.txt")
    expect(File.read("x.txt")).to eq("new")
  end

  it "renames a file" do
    File.write("from.txt", "x")
    status, _, body = Tina4::DevAdmin.handle_request(
      make_env("POST", "/__dev/api/file/rename", body: { from: "from.txt", to: "to.txt" })
    )
    expect(status).to eq(200)
    expect(File).to exist("to.txt")
    expect(File).not_to exist("from.txt")
    JSON.parse(body.first)
  end

  it "deletes a file" do
    File.write("gone.txt", "x")
    status, _, body = Tina4::DevAdmin.handle_request(
      make_env("POST", "/__dev/api/file/delete", body: { path: "gone.txt" })
    )
    expect(status).to eq(200)
    expect(File).not_to exist("gone.txt")
    JSON.parse(body.first)
  end

  it "returns scaffold template list" do
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/scaffold"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    ids = data["templates"].map { |t| t["id"] }
    expect(ids).to include("route", "model", "migration", "middleware")
  end

  it "runs a scaffold and creates the target file" do
    # ADR-0063 (3.13.121): scaffold_run now shells to `exe/tina4ruby generate
    # <kind> <name>` so the CLI's envelope + `# tina4:edit` markers reach the
    # endpoint's `output` (mirrors PHP's shell_exec + Node's execFileSync).
    # The Dir.mktmpdir around-block gives us an empty cwd, so symlink the real
    # exe + lib in for the subprocess to find.
    FileUtils.mkdir_p("exe")
    File.symlink(EXE, "exe/tina4ruby") unless File.exist?("exe/tina4ruby")
    File.symlink(File.join(REPO_ROOT, "lib"), "lib") unless File.exist?("lib")

    status, _, body = Tina4::DevAdmin.handle_request(
      make_env("POST", "/__dev/api/scaffold/run", body: { kind: "route", name: "widgets" })
    )
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    expect(data["ok"]).to be true
    expect(File).to exist("src/routes/widgets.rb")
  end

  it "lists the real registered MCP tool catalogue" do
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/mcp/tools"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    # mcp_tools_list returns the default MCP server's actually-registered dev
    # tools — assert the catalogue, not just that it's an Array.
    names = data["tools"].map { |t| t["name"] }
    expect(names).to include("route_list", "file_list", "docs_list", "project_overview")
    # count must match the number of tools returned.
    expect(data["count"]).to eq(data["tools"].size)
    expect(data["count"]).to be > 0
    # Every tool entry carries a non-empty description and a schema key
    # (register_tool maps inputSchema -> "schema" and defaults description to
    # the tool name, so it is never empty).
    data["tools"].each do |tool|
      expect(tool["description"]).to be_a(String)
      expect(tool["description"]).not_to be_empty
      expect(tool).to have_key("schema")
    end
  end

  # ── Agent chat surface removed (feature/release3.13.132) ──────────
  # The dev-admin's agentic chat + supervisor proxy surface is gone:
  # POST /chat, GET/POST /threads, /threads/{id}[/messages], GET /thoughts,
  # the /supervise/* endpoints and POST /execute no longer exist. Every one
  # proxied to the CLI agent on framework_port + 2000. handle_request now
  # DISOWNS these paths (returns nil — the dev-admin "not my route" signal),
  # so the front controller falls through to a 404 (proven end-to-end through
  # a real RackApp in dev_admin_conformance_spec.rb). The MCP, grounding,
  # editor and metrics surfaces are untouched.
  #
  # Real calls into the real handler (no doubles): a removed route yields nil,
  # a kept route yields a real 200 payload.
  describe "agent chat surface removed" do
    [
      ["POST",  "/__dev/api/chat"],
      ["GET",   "/__dev/api/threads"],
      ["POST",  "/__dev/api/threads"],
      ["PATCH", "/__dev/api/threads/abc"],
      ["GET",   "/__dev/api/threads/abc/messages"],
      ["GET",   "/__dev/api/thoughts"],
      ["POST",  "/__dev/api/supervise/create"],
      ["GET",   "/__dev/api/supervise/sessions"],
      ["GET",   "/__dev/api/supervise/diff"],
      ["POST",  "/__dev/api/supervise/commit"],
      ["POST",  "/__dev/api/supervise/cancel"],
      ["POST",  "/__dev/api/execute"]
    ].each do |method, path|
      it "disowns #{method} #{path} (agent removed -> nil -> 404)" do
        result = Tina4::DevAdmin.handle_request(make_env(method, path, body: {}))
        expect(result).to be_nil
      end
    end

    it "still serves the kept grounding panel (positive control)" do
      status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/grounding/status"))
      expect(status).to eq(200)
      expect { JSON.parse(body.first) }.not_to raise_error
    end

    it "still serves the dev-admin SPA shell (code-editor landing)" do
      status, headers, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("text/html")
      html = body.first
      expect(html).to include('id="app"')
      expect(html).to include("/__dev/js/tina4-dev-admin.min.js")
    end
  end
end
