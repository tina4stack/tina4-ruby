# frozen_string_literal: true

require "spec_helper"
require "socket"

# ADR-0060 cases for Api.stream_bytes / stream_lines / stream_sse — the shared
# streaming primitives that Ai.chat(stream: true) also uses. Real local TCP
# fixture, real Net::HTTP client, real sockets. No mocks.
RSpec.describe "ADR-0060 Api streaming primitives" do
  # Minimal HTTP/1.1 fixture that dispatches on the path and lets the test
  # pick chunked vs Content-Length framing, plus an early-close mode for the
  # transport-drop case. Each request is captured for later inspection.
  class ApiStreamServer
    attr_reader :port, :requests

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @requests = []
      @running = true
      @thread = Thread.new { serve }
    end

    def url(path)
      "http://127.0.0.1:#{@port}#{path}"
    end

    def stop
      @running = false
      @server.close
      @thread.join(1)
    rescue IOError, Errno::EBADF
      nil
    end

    private

    def serve
      while @running
        socket = @server.accept
        Thread.new(socket) { |client| handle(client) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def handle(socket)
      request_line = socket.gets
      return socket.close unless request_line

      method, path, = request_line.split
      headers = {}
      while (line = socket.gets)
        break if line == "\r\n" || line == "\n"

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = headers["content-length"] ? socket.read(headers["content-length"].to_i).to_s : ""
      @requests << { method: method, path: path, headers: headers, body: body }
      respond(socket, method, path)
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    ensure
      socket.close rescue nil
    end

    def respond(socket, _method, path)
      case path
      when "/plain-two-chunks"
        chunked(socket, ["hello", " world"])
      when "/plain-multi-chunks"
        chunked(socket, %w[alpha beta gamma delta])
      when "/lf-lines"
        chunked(socket, ["first\nsecond\n", "third\n"])
      when "/crlf-lines"
        chunked(socket, ["first\r\nsecond\r\n", "third\r\n"])
      when "/trailing-line-no-newline"
        chunked(socket, ["one\n", "two\n", "no-newline"])
      when "/multibyte-split"
        # UTF-8 for "héllo" = 68 c3 a9 6c 6c 6f — split the é between chunks.
        chunked(socket, ["h\xc3".b, "\xa9llo\n".b, "world\n".b])
      when "/sse-single"
        sse_body(socket, "data: one\n\n")
      when "/sse-multiline"
        sse_body(socket, "data: first\ndata: second\ndata: third\n\n")
      when "/sse-named"
        sse_body(socket, "event: tick\ndata: 42\n\n")
      when "/sse-comment"
        sse_body(socket, ":ping\ndata: after\n\n")
      when "/sse-blank-boundary"
        sse_body(socket, "data: one\n\ndata: two\n\n")
      when "/sse-done-sentinel"
        sse_body(socket, "data: hello\n\ndata: [DONE]\n\n")
      when "/sse-retry-field"
        sse_body(socket, "retry: 5000\ndata: reconnect-me\n\n")
      when "/drop-midstream"
        # Send some chunks, then hang up without the terminating 0-length
        # chunk so the client sees a truncated body.
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n")
        socket.write("5\r\nhello\r\n")
        socket.flush
        socket.close
      when "/echo-post"
        # Confirm stream_bytes actually POSTed our body — echo it back.
        chunked(socket, [@requests.last[:body]])
      else
        socket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      end
    end

    def chunked(socket, chunks)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      chunks.each do |chunk|
        socket.write("#{chunk.bytesize.to_s(16)}\r\n")
        socket.write(chunk)
        socket.write("\r\n")
        socket.flush
      end
      socket.write("0\r\n\r\n")
      socket.flush
    end

    def sse_body(socket, payload)
      body = payload.b
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
      socket.write(body)
      socket.flush
    end
  end

  before(:all) { @server = ApiStreamServer.new }
  after(:all) { @server.stop }

  let(:api) { Tina4::API.new("http://127.0.0.1:#{@server.port}") }

  # ── stream_bytes ─────────────────────────────────────────────────────────

  it "stream-bytes-yields-chunks-in-order" do
    chunks = []
    api.stream_bytes("/plain-multi-chunks") { |chunk| chunks << chunk.dup }
    expect(chunks.join).to eq("alphabetagammadelta")
    # And ordering (chunks may coalesce but their concatenation is stable).
    expect(chunks.map(&:bytesize).sum).to eq("alphabetagammadelta".bytesize)
  end

  it "stream-bytes-ends-on-eof" do
    collected = []
    api.stream_bytes("/plain-two-chunks") { |chunk| collected << chunk.dup }
    # If EOF wasn't clean, the block would never return and this expect wouldn't run.
    expect(collected.join).to eq("hello world")
  end

  it "stream-bytes-raises-on-transport-drop" do
    expect do
      api.stream_bytes("/drop-midstream") { |_chunk| nil }
    end.to raise_error(StandardError)
  end

  it "stream-bytes-returns-enumerator-without-block" do
    # Ruby idiom: no block = Enumerator that lazily runs the stream.
    enum = api.stream_bytes("/plain-two-chunks")
    expect(enum).to be_a(Enumerator)
    expect(enum.to_a.join).to eq("hello world")
  end

  it "stream-bytes-sends-request-body" do
    body = "hello=world"
    echoed = []
    api.stream_bytes("/echo-post", method: "POST", body: body,
                     content_type: "application/x-www-form-urlencoded") do |chunk|
      echoed << chunk.dup
    end
    expect(echoed.join).to eq(body)
    last = @server.requests.reverse.find { |r| r[:path] == "/echo-post" }
    expect(last[:method]).to eq("POST")
    expect(last[:headers]["content-type"]).to eq("application/x-www-form-urlencoded")
    expect(last[:body]).to eq(body)
  end

  # ── stream_lines ─────────────────────────────────────────────────────────

  it "stream-lines-splits-on-lf" do
    lines = api.stream_lines("/lf-lines").to_a
    expect(lines).to eq(%w[first second third])
    expect(lines.first.encoding).to eq(Encoding::UTF_8)
  end

  it "stream-lines-splits-on-crlf" do
    lines = api.stream_lines("/crlf-lines").to_a
    expect(lines).to eq(%w[first second third])
  end

  it "stream-lines-yields-trailing-line-without-newline" do
    lines = api.stream_lines("/trailing-line-no-newline").to_a
    expect(lines).to eq(%w[one two no-newline])
  end

  it "stream-lines-multibyte-across-chunk-boundary" do
    lines = api.stream_lines("/multibyte-split").to_a
    expect(lines).to eq(%w[héllo world])
    expect(lines.first.encoding).to eq(Encoding::UTF_8)
    expect(lines.first.valid_encoding?).to be true
  end

  # ── stream_sse ───────────────────────────────────────────────────────────

  it "stream-sse-single-event" do
    events = api.stream_sse("/sse-single").to_a
    expect(events).to eq([{ data: "one" }])
  end

  it "stream-sse-multi-line-data-concatenated" do
    events = api.stream_sse("/sse-multiline").to_a
    expect(events).to eq([{ data: "first\nsecond\nthird" }])
  end

  it "stream-sse-named-event" do
    events = api.stream_sse("/sse-named").to_a
    expect(events).to eq([{ data: "42", event: "tick" }])
  end

  it "stream-sse-comment-ignored" do
    events = api.stream_sse("/sse-comment").to_a
    expect(events).to eq([{ data: "after" }])
  end

  it "stream-sse-blank-line-boundary" do
    events = api.stream_sse("/sse-blank-boundary").to_a
    expect(events).to eq([{ data: "one" }, { data: "two" }])
  end

  it "stream-sse-done-sentinel-delivered" do
    events = api.stream_sse("/sse-done-sentinel").to_a
    expect(events).to eq([{ data: "hello" }, { data: "[DONE]" }])
  end

  it "stream-sse-retry-field-captured" do
    events = api.stream_sse("/sse-retry-field").to_a
    expect(events).to eq([{ data: "reconnect-me", retry: 5000 }])
  end

  # ── ai-chat-uses-api-stream-sse-under-the-hood ───────────────────────────

  it "ai-chat-uses-api-stream-sse-under-the-hood" do
    # Prove shared framing: Ai.chat(stream: true) calls Api#stream_sse and
    # does not carry its own SSE framer. Positive check (an api.stream_sse
    # call site exists) plus a structural check (Ai does not use
    # response.read_body directly, which is what a bespoke SSE reader would
    # need). ai_client_contract_spec.rb exercises the SSE cases end-to-end
    # through Ai.chat — the byte-for-byte proof of shared framing.
    ai_client_source = File.read(File.expand_path("../lib/tina4/ai_client.rb", __dir__), encoding: Encoding::UTF_8)
    expect(ai_client_source).to include("api.stream_sse")
    expect(ai_client_source).not_to include(".read_body")
  end
end
