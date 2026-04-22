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
    status, _, body = Tina4::DevAdmin.handle_request(
      make_env("POST", "/__dev/api/scaffold/run", body: { kind: "route", name: "widgets" })
    )
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    expect(data["ok"]).to be true
    expect(File).to exist("src/routes/widgets.rb")
  end

  it "lists MCP tools" do
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/mcp/tools"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    expect(data["tools"]).to be_an(Array)
  end

  it "returns supervisor error JSON for /__dev/api/thoughts when supervisor is down" do
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/thoughts"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    # Connection refused or similar — just require JSON shape.
    expect(data).to be_a(Hash)
  end
end
