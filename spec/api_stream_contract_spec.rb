# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


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
    attr_reader :port, :requests, :closed_connections

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @requests = []
      # One entry per /hold-for-close connection, pushed the moment the SERVER
      # sees the client's side of the socket go away.
      @closed_connections = Queue.new
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
      when "/drip-forever"
        # A healthy connection that never ends: a chunk every 50 ms. Only a
        # TOTAL deadline stops it; a per-read idle timeout never fires.
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        loop do
          socket.write("4\r\ndrip\r\n")
          socket.flush
          sleep 0.05
        end
      when "/hold-for-close"
        # One chunk, then wait for the client. The client never sends another
        # byte, so read returns only when the client closes its socket.
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        socket.write("5\r\nfirst\r\n")
        socket.flush
        begin
          socket.read(1)
        rescue Errno::ECONNRESET
          nil
        end
        @closed_connections << :closed_by_client
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

  # ── api-stream-timeouts-and-close ────────────────────────────────────────

  # Run a stream on its own thread and report what it did within `limit`
  # seconds: the exception it raised, :returned, or :still_streaming. A stream
  # still running at the limit is killed, which unwinds it and closes its socket.
  def stream_outcome_within(limit)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    worker = Thread.new do
      yield
      :returned
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end
    worker.report_on_exception = false
    outcome = worker.join(limit) ? worker.value : :still_streaming
    worker.kill
    [outcome, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  # A REAL loopback listener that never completes a TCP handshake: it listens
  # with a backlog of 0 and never accepts, and filler connections occupy the
  # accept queue, so the kernel drops every further SYN. A connect to it stalls
  # the way a connect to a dead host does.
  def with_stalled_listener
    listener = Socket.new(:INET, :STREAM)
    listener.bind(Addrinfo.tcp("127.0.0.1", 0))
    listener.listen(0)
    address = listener.local_address
    fillers = Array.new(8) do
      filler = Socket.new(:INET, :STREAM)
      begin
        filler.connect_nonblock(address)
      rescue IO::WaitWritable, Errno::EISCONN
        nil
      end
      filler
    end
    # Precondition, proved rather than assumed: a fresh connect must NOT
    # complete. If it does, this platform accepts past the backlog and the case
    # below would prove nothing.
    probe = Socket.new(:INET, :STREAM)
    begin
      probe.connect_nonblock(address)
      raise "the stalled listener accepted a connection; the connect case cannot be staged here"
    rescue IO::WaitWritable
      _readable, writable, = IO.select(nil, [probe], nil, 0.5)
      raise "the stalled listener completed a handshake; the connect case cannot be staged here" if writable
    ensure
      probe.close
    end
    yield address.ip_port
  ensure
    fillers&.each(&:close)
    listener&.close
  end

  it "stream-connect-timeout-honoured" do
    with_stalled_listener do |stalled_port|
      stalled_api = Tina4::API.new("http://127.0.0.1:#{stalled_port}")

      # Per call: connect_timeout bounds the handshake, well inside timeout.
      outcome, elapsed = stream_outcome_within(5) do
        stalled_api.stream_bytes("/never", connect_timeout: 0.2, timeout: 5) { |_chunk| nil }
      end
      expect(outcome).to be_a(Timeout::Error)
      expect(elapsed).to be < 2.0

      # From the environment: TINA4_API_CONNECT_TIMEOUT, no argument.
      with_env("TINA4_API_CONNECT_TIMEOUT", "0.2") do
        outcome, elapsed = stream_outcome_within(5) do
          stalled_api.stream_bytes("/never") { |_chunk| nil }
        end
        expect(outcome).to be_a(Timeout::Error)
        expect(elapsed).to be < 2.0
      end
    end
  end

  it "stream-total-timeout-honoured" do
    # Per call: the connection is healthy and delivering data every 50 ms, so
    # only a TOTAL deadline can end it.
    outcome, elapsed = stream_outcome_within(5) do
      api.stream_bytes("/drip-forever", timeout: 0.3, connect_timeout: 1.0) { |_chunk| nil }
    end
    expect(outcome).to be_a(Timeout::Error)
    expect(outcome).to be_a(Tina4::APIStreamTimeoutError)
    expect(elapsed).to be < 2.0

    # From the environment: TINA4_API_TIMEOUT, no argument.
    with_env("TINA4_API_TIMEOUT", "0.3") do
      outcome, elapsed = stream_outcome_within(5) do
        api.stream_lines("/drip-forever") { |_line| nil }
      end
      expect(outcome).to be_a(Timeout::Error)
      expect(outcome).to be_a(Tina4::APIStreamTimeoutError)
      expect(elapsed).to be < 2.0
    end
  end

  it "stream-early-close-releases-socket" do
    @server.closed_connections.clear

    # Block form: break out after the first chunk.
    first = nil
    api.stream_bytes("/hold-for-close", timeout: 30) do |chunk|
      first = chunk
      break
    end
    expect(first).to eq("first")
    # The SERVER sees the client's socket close. A leaked socket keeps the
    # server's read blocked and this pop times out with nil.
    expect(@server.closed_connections.pop(timeout: 2)).to eq(:closed_by_client)

    # Enumerator form: #first stops the iteration before EOF.
    expect(api.stream_bytes("/hold-for-close", timeout: 30).first).to eq("first")
    expect(@server.closed_connections.pop(timeout: 2)).to eq(:closed_by_client)
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
