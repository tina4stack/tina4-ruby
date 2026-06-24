# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "socket"

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

  it "returns supervisor error JSON for /__dev/api/thoughts when supervisor is down" do
    # No supervisor is running on the (port + 2000) dev channel during the
    # spec, so thoughts_payload's real connection attempt fails and it returns
    # its degraded shape: { thoughts: [], error: <connection message> }.
    status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/thoughts"))
    expect(status).to eq(200)
    data = JSON.parse(body.first)
    # Assert the REAL degraded payload, not just "is a Hash".
    expect(data["thoughts"]).to eq([])
    expect(data).to have_key("error")
    expect(data["error"]).to be_a(String)
    expect(data["error"]).not_to be_empty
  end

  # ── Tier 3 parity: /__dev/api/chat + /__dev/api/threads* ──────────
  # Mirrors tina4-python/tina4_python/dev_admin/__init__.py lines
  # 1183-1230 and 1591-1700. The Ruby implementation forwards JSON
  # bodies verbatim to the Rust agent server and pipes SSE responses
  # back.
  #
  # These specs drive a REAL loopback HTTP server (a TCPServer bound to
  # 127.0.0.1 on an ephemeral port, see DevAdminSupervisor below) standing
  # in for the Rust agent/supervisor. The dev-admin proxy code makes a real
  # Net::HTTP round-trip to it over a real socket — no Net::HTTP doubles.
  # TINA4_SUPERVISOR_URL points the proxy at the loopback port.
  describe "supervisor proxies" do
    # A genuine in-process HTTP server (real TCP socket serving canned
    # responses) — the correct way to test an HTTP client without mocking.
    # Records the request it actually received over the wire, and serves
    # either a plain JSON body or a streamed SSE body (for the /chat proxy,
    # which reads the response with Net::HTTP#request { |resp| resp.read_body
    # { |chunk| ... } }).
    class DevAdminSupervisor
      attr_reader :port

      def initialize(response_body: "{}", content_type: "application/json", status_code: 200,
                     sse_chunks: nil)
        @response_body = response_body
        @content_type = content_type
        @status_code = status_code
        @sse_chunks = sse_chunks
        @mutex = Mutex.new
        @captured = { method: nil, host: nil, port: nil, path: nil, body: nil, headers: {}, accept: nil }
        @server = TCPServer.new("127.0.0.1", 0)
        @port = @server.addr[1]
        @running = true
        @thread = Thread.new { serve_loop }
      end

      # Snapshot of the last request received over the real socket.
      def captured
        @mutex.synchronize { @captured.dup }
      end

      def stop
        @running = false
        begin
          @server.close unless @server.closed?
        rescue StandardError
          nil
        end
        @thread.join(1) if @thread&.alive?
        @thread.kill if @thread&.alive?
      end

      private

      def serve_loop
        while @running
          client = begin
            @server.accept
          rescue StandardError
            nil
          end
          break if client.nil?

          handle(client)
        end
      end

      def handle(client)
        request_line = client.gets
        return if request_line.nil?

        method, path, = request_line.split(" ")
        headers = {}
        content_length = 0
        while (line = client.gets)
          break if line == "\r\n"

          key, value = line.split(":", 2)
          next unless value

          name = key.strip.downcase
          headers[name] = value.strip
          content_length = value.strip.to_i if name == "content-length"
        end
        body = content_length.positive? ? client.read(content_length) : nil

        @mutex.synchronize do
          @captured = {
            method: method,
            host: headers["host"],
            port: @port,
            path: path,
            body: body,
            headers: headers,
            accept: headers["accept"]
          }
        end

        write_response(client)
      rescue StandardError
        nil
      ensure
        begin
          client.close
        rescue StandardError
          nil
        end
      end

      def write_response(client)
        if @sse_chunks
          # Stream an SSE body — chunked transfer so Net::HTTP delivers each
          # chunk to read_body's block, exactly like the real agent server.
          client.write(
            "HTTP/1.1 #{@status_code} OK\r\n" \
            "Content-Type: #{@content_type}\r\n" \
            "Transfer-Encoding: chunked\r\n" \
            "Connection: close\r\n\r\n"
          )
          @sse_chunks.each do |chunk|
            client.write(format("%x\r\n%s\r\n", chunk.bytesize, chunk))
          end
          client.write("0\r\n\r\n")
        else
          client.write(
            "HTTP/1.1 #{@status_code} OK\r\n" \
            "Content-Type: #{@content_type}\r\n" \
            "Content-Length: #{@response_body.bytesize}\r\n" \
            "Connection: close\r\n" \
            "\r\n#{@response_body}"
          )
        end
      end
    end

    # Start a real loopback supervisor, point dev-admin at it via
    # TINA4_SUPERVISOR_URL, and tear it down after the block. Returns the
    # running server so the caller can read `.captured`.
    def with_supervisor(response_body: "{}", content_type: "application/json", status_code: 200,
                        sse_chunks: nil, supervisor_url: nil)
      server = DevAdminSupervisor.new(
        response_body: response_body, content_type: content_type,
        status_code: status_code, sse_chunks: sse_chunks
      )
      ENV["TINA4_SUPERVISOR_URL"] = supervisor_url || "http://127.0.0.1:#{server.port}"
      begin
        yield server
      ensure
        ENV.delete("TINA4_SUPERVISOR_URL")
        server.stop
      end
    end

    it "proxies threads list to the supervisor" do
      with_supervisor(response_body: '{"threads":[{"id":"t1"}]}') do |server|
        status, _, body = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/threads"))
        expect(status).to eq(200)
        captured = server.captured
        expect(captured[:method]).to eq("GET")
        expect(captured[:path]).to eq("/threads")
        data = JSON.parse(body.first)
        expect(data["threads"]).to eq([{ "id" => "t1" }])
      end
    end

    it "creates threads via POST to the supervisor" do
      with_supervisor(response_body: '{"id":"t42"}') do |server|
        status, _, body = Tina4::DevAdmin.handle_request(
          make_env("POST", "/__dev/api/threads", body: { title: "Hi" })
        )
        expect(status).to eq(200)
        captured = server.captured
        expect(captured[:method]).to eq("POST")
        expect(captured[:path]).to eq("/threads")
        expect(JSON.parse(captured[:body])).to eq({ "title" => "Hi" })
        data = JSON.parse(body.first)
        expect(data["id"]).to eq("t42")
      end
    end

    it "patches threads on upstream" do
      with_supervisor(response_body: '{"updated":true}') do |server|
        status, _, body = Tina4::DevAdmin.handle_request(
          make_env("PATCH", "/__dev/api/threads/abc", body: { archived: true })
        )
        expect(status).to eq(200)
        captured = server.captured
        expect(captured[:method]).to eq("PATCH")
        expect(captured[:path]).to eq("/threads/abc")
        expect(JSON.parse(captured[:body])).to eq({ "archived" => true })
        expect(JSON.parse(body.first)["updated"]).to be true
      end
    end

    it "fetches thread messages from upstream" do
      with_supervisor(response_body: '{"messages":[]}') do |server|
        status, _, body = Tina4::DevAdmin.handle_request(
          make_env("GET", "/__dev/api/threads/abc/messages")
        )
        expect(status).to eq(200)
        captured = server.captured
        expect(captured[:method]).to eq("GET")
        expect(captured[:path]).to eq("/threads/abc/messages")
        expect(JSON.parse(body.first)).to have_key("messages")
      end
    end

    it "forwards active_file in chat POST" do
      with_supervisor(content_type: "text/event-stream",
                      sse_chunks: ["event: status\ndata: ok\n\n"]) do |server|
        payload = { message: "fix the bug", thread_id: "t1", active_file: "src/routes/users.rb" }
        status, headers, _body = Tina4::DevAdmin.handle_request(
          make_env("POST", "/__dev/api/chat", body: payload)
        )
        expect(status).to eq(200)
        captured = server.captured
        expect(captured[:method]).to eq("POST")
        expect(captured[:path]).to eq("/chat")
        expect(captured[:accept]).to include("text/event-stream")
        forwarded = JSON.parse(captured[:body])
        expect(forwarded["active_file"]).to eq("src/routes/users.rb")
        expect(forwarded["thread_id"]).to eq("t1")
        expect(forwarded["message"]).to eq("fix the bug")
        expect(headers["content-type"]).to include("text/event-stream")
      end
    end

    it "honours TINA4_SUPERVISOR_URL env var" do
      # Bind the real loopback server, then point dev-admin at it through a
      # 127.0.0.1 URL with an explicit host:port so we can assert the proxy
      # resolved the env var and hit exactly that endpoint over the wire.
      server = DevAdminSupervisor.new(response_body: '{"threads":[]}')
      ENV["TINA4_SUPERVISOR_URL"] = "http://127.0.0.1:#{server.port}"
      begin
        status, _, _ = Tina4::DevAdmin.handle_request(make_env("GET", "/__dev/api/threads"))
        expect(status).to eq(200)
        captured = server.captured
        expect(captured[:host]).to eq("127.0.0.1:#{server.port}")
        expect(captured[:port]).to eq(server.port)
        expect(captured[:path]).to eq("/threads")
      ensure
        ENV.delete("TINA4_SUPERVISOR_URL")
        server.stop
      end
    end
  end
end
