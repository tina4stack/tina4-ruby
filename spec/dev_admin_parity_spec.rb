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

  # ── Tier 3 parity: /__dev/api/chat + /__dev/api/threads* ──────────
  # Mirrors tina4-python/tina4_python/dev_admin/__init__.py lines
  # 1183-1230 and 1591-1700. The Ruby implementation forwards JSON
  # bodies verbatim to the Rust agent server and pipes SSE responses
  # back. We stub Net::HTTP at the class level (no WebMock — Tina4
  # Ruby specs avoid third-party HTTP mocking deps).
  describe "supervisor proxies" do
    # Captures the request that the dev_admin would have fired at the
    # Rust agent and returns the canned response. Replaces
    # Net::HTTP.start so any GET/POST/PATCH proxy path is observable.
    def stub_supervisor(response_body: "{}", content_type: "application/json", status_code: "200")
      captured = { method: nil, host: nil, port: nil, path: nil, body: nil, headers: {} }

      allow(Net::HTTP).to receive(:start) do |host, port, opts = {}, &block|
        captured[:host] = host
        captured[:port] = port
        # Fake the HTTP session — the block in proxy_supervisor calls
        # `h.request(req)` and inspects resp.body / resp.code.
        session = Object.new
        session.define_singleton_method(:request) do |req|
          captured[:method] = req.method
          captured[:path] = req.path
          captured[:body] = req.body
          req.each_header { |k, v| captured[:headers][k.downcase] = v }
          resp = Net::HTTPResponse.send(:response_class, status_code).new("1.1", status_code, "OK")
          resp.instance_variable_set(:@read, true)
          resp.body = response_body
          resp["content-type"] = content_type
          resp
        end
        block ? block.call(session) : session
      end

      captured
    end

    # Net::HTTP#request_get (used by chat_proxy via http.request(req) { |resp| resp.read_body }).
    # Stubs the instance-level `request` call so we can capture both
    # the outbound payload AND inject an SSE chunk into the read_body
    # callback.
    def stub_chat_supervisor(sse_chunks: ["event: status\ndata: ok\n\n"], content_type: "text/event-stream")
      captured = { host: nil, port: nil, method: nil, path: nil, body: nil, headers: {}, accept: nil }

      fake_http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new) do |host, port|
        captured[:host] = host
        captured[:port] = port
        fake_http
      end
      allow(fake_http).to receive(:open_timeout=)
      allow(fake_http).to receive(:read_timeout=)
      allow(fake_http).to receive(:request) do |req, &block|
        captured[:method] = req.method
        captured[:path] = req.path
        captured[:body] = req.body
        req.each_header { |k, v| captured[:headers][k.downcase] = v }
        captured[:accept] = req["accept"]
        resp = Net::HTTPResponse.send(:response_class, "200").new("1.1", "200", "OK")
        resp["content-type"] = content_type
        # Emulate chunked SSE delivery — read_body yields each chunk to
        # the block exactly like Net::HTTP does for streamed responses.
        resp.define_singleton_method(:read_body) do |&chunk_block|
          sse_chunks.each { |c| chunk_block.call(c) }
        end
        block ? block.call(resp) : resp
      end

      captured
    end

    it "proxies threads list to the supervisor" do
      captured = stub_supervisor(response_body: '{"threads":[{"id":"t1"}]}')
      status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/threads"))
      expect(status).to eq(200)
      expect(captured[:method]).to eq("GET")
      expect(captured[:path]).to eq("/threads")
      data = JSON.parse(body.first)
      expect(data["threads"]).to eq([{ "id" => "t1" }])
    end

    it "creates threads via POST to the supervisor" do
      captured = stub_supervisor(response_body: '{"id":"t42"}')
      status, _, body = Tina4::DevAdmin.handle_request(
        make_env("POST", "/__dev/api/threads", body: { title: "Hi" })
      )
      expect(status).to eq(200)
      expect(captured[:method]).to eq("POST")
      expect(captured[:path]).to eq("/threads")
      expect(JSON.parse(captured[:body])).to eq({ "title" => "Hi" })
      data = JSON.parse(body.first)
      expect(data["id"]).to eq("t42")
    end

    it "patches threads on upstream" do
      captured = stub_supervisor(response_body: '{"updated":true}')
      status, _, body = Tina4::DevAdmin.handle_request(
        make_env("PATCH", "/__dev/api/threads/abc", body: { archived: true })
      )
      expect(status).to eq(200)
      expect(captured[:method]).to eq("PATCH")
      expect(captured[:path]).to eq("/threads/abc")
      expect(JSON.parse(captured[:body])).to eq({ "archived" => true })
      expect(JSON.parse(body.first)["updated"]).to be true
    end

    it "fetches thread messages from upstream" do
      captured = stub_supervisor(response_body: '{"messages":[]}')
      status, _, body = Tina4::DevAdmin.handle_request(
        make_env("GET", "/__dev/api/threads/abc/messages")
      )
      expect(status).to eq(200)
      expect(captured[:method]).to eq("GET")
      expect(captured[:path]).to eq("/threads/abc/messages")
      expect(JSON.parse(body.first)).to have_key("messages")
    end

    it "forwards active_file in chat POST" do
      captured = stub_chat_supervisor
      payload = { message: "fix the bug", thread_id: "t1", active_file: "src/routes/users.rb" }
      status, headers, _body = Tina4::DevAdmin.handle_request(
        make_env("POST", "/__dev/api/chat", body: payload)
      )
      expect(status).to eq(200)
      expect(captured[:method]).to eq("POST")
      expect(captured[:path]).to eq("/chat")
      expect(captured[:accept]).to include("text/event-stream")
      forwarded = JSON.parse(captured[:body])
      expect(forwarded["active_file"]).to eq("src/routes/users.rb")
      expect(forwarded["thread_id"]).to eq("t1")
      expect(forwarded["message"]).to eq("fix the bug")
      expect(headers["content-type"]).to include("text/event-stream")
    end

    it "honours TINA4_SUPERVISOR_URL env var" do
      ENV["TINA4_SUPERVISOR_URL"] = "http://agent.example:9999"
      captured = stub_supervisor(response_body: '{"threads":[]}')
      status, _, _ = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/threads"))
      expect(status).to eq(200)
      expect(captured[:host]).to eq("agent.example")
      expect(captured[:port]).to eq(9999)
    ensure
      ENV.delete("TINA4_SUPERVISOR_URL")
    end
  end
end
