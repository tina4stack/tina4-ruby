# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "socket"

RSpec.describe "Tina4::Feedback" do
  def make_env(method, path, query: "", body: nil, auth: nil)
    input = body ? StringIO.new(body.is_a?(String) ? body : JSON.generate(body)) : StringIO.new("")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
      "rack.input" => input
    }
    env["HTTP_AUTHORIZATION"] = auth if auth
    env
  end

  # Real loopback HTTP server standing in for the Rust supervisor.
  #
  # This is NOT a mock — it is a genuine TCPServer bound to 127.0.0.1 on an
  # ephemeral port, accepting real connections and serving canned responses
  # over a real socket. The feedback handler's Net::HTTP.start round-trips to
  # it for real (handshake, request line, headers, body, response parse), so
  # the test exercises the actual HTTP client path end to end. It records the
  # request it received so the spec can assert on what was forwarded.
  class FeedbackSupervisor
    attr_reader :port

    def initialize(response_body: "{}", content_type: "application/json", status_code: 200)
      @response_body = response_body
      @content_type = content_type
      @status_code = status_code
      @mutex = Mutex.new
      @captured = { method: nil, host: nil, port: nil, path: nil, body: nil, headers: {} }
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @running = true
      @thread = Thread.new { serve_loop }
    end

    # Snapshot of the last request the server received over the real socket.
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
          headers: headers
        }
      end

      client.write(
        "HTTP/1.1 #{@status_code} OK\r\n" \
        "Content-Type: #{@content_type}\r\n" \
        "Content-Length: #{@response_body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n#{@response_body}"
      )
    rescue StandardError
      nil
    ensure
      begin
        client.close
      rescue StandardError
        nil
      end
    end
  end

  # Start a real loopback supervisor, point the feedback handler at it via
  # TINA4_SUPERVISOR_URL, and tear it down after the block. Returns the
  # running server so the caller can read `.captured`.
  def with_supervisor(response_body: "{}", content_type: "application/json", status_code: 200)
    server = FeedbackSupervisor.new(
      response_body: response_body, content_type: content_type, status_code: status_code
    )
    ENV["TINA4_SUPERVISOR_URL"] = "http://127.0.0.1:#{server.port}"
    begin
      yield server
    ensure
      server.stop
    end
  end

  before(:each) do
    Tina4::Feedback.reset_rate_limit!
    # Make sure no leaked env from other specs alters behaviour
    %w[TINA4_ENABLE_FEEDBACK TINA4_FEEDBACK_WHITELIST TINA4_FEEDBACK_DEV_USER TINA4_SUPERVISOR_URL].each do |k|
      ENV.delete(k)
    end
  end

  after(:each) do
    %w[TINA4_ENABLE_FEEDBACK TINA4_FEEDBACK_WHITELIST TINA4_FEEDBACK_DEV_USER TINA4_SUPERVISOR_URL].each do |k|
      ENV.delete(k)
    end
  end

  # Fake request struct matching what inject_feedback_widget expects
  # (responds to .path, .env).
  def fake_request(path: "/", env: {})
    Struct.new(:path, :env).new(path, env)
  end

  it "skips injection when disabled" do
    # No master switch — feature is fully off.
    html = "<html><body>hi</body></html>"
    out = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/"), html)
    expect(out).to eq(html)
  end

  it "skips injection on /__dev paths" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    html = "<html><body>hi</body></html>"
    out = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/__dev/whatever"), html)
    expect(out).to eq(html)
  end

  it "skips injection on /__feedback paths" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    html = "<html><body>hi</body></html>"
    out = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/__feedback/widget.js"), html)
    expect(out).to eq(html)
  end

  it "injects for whitelisted user" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com,other@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    html = "<html><body>hi</body></html>"
    out = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/dashboard"), html)
    expect(out).to include('<script src="/__feedback/widget.js" data-tina4-feedback></script>')
    # script must sit immediately before </body>
    expect(out).to include('data-tina4-feedback></script></body>')
  end

  it "is idempotent on re-injection" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    html = "<html><body>hi</body></html>"
    once = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/dashboard"), html)
    twice = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/dashboard"), once)
    expect(twice).to eq(once)
    # Sanity check: only one tag in the doc
    expect(twice.scan("data-tina4-feedback").size).to eq(1)
  end

  it "skips injection for non-whitelisted user" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "alice@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "bob@example.com"  # not on the list
    html = "<html><body>hi</body></html>"
    out = Tina4::Feedback.inject_feedback_widget(fake_request(path: "/dashboard"), html)
    expect(out).to eq(html)
  end

  it "rejects non-whitelisted turn POST" do
    # Master switch off → not authorised
    status, _, body = Tina4::Feedback.handle_request(
      make_env("POST", "/__feedback/api/turn", body: { message: "hi" })
    )
    expect(status).to eq(403)
    data = JSON.parse(body.first)
    expect(data["error"]).to include("not authorised")
  end

  it "rate limits at 5/hour" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    with_supervisor(response_body: '{"ok":true}') do
      # 5 allowed calls
      5.times do
        status, _, _ = Tina4::Feedback.handle_request(
          make_env("POST", "/__feedback/api/turn", body: { message: "ping" })
        )
        expect(status).to eq(200)
      end

      # 6th must be rate-limited
      status, _, body = Tina4::Feedback.handle_request(
        make_env("POST", "/__feedback/api/turn", body: { message: "too much" })
      )
      expect(status).to eq(429)
      data = JSON.parse(body.first)
      expect(data["error"]).to include("rate limit")
    end
  end

  it "forwards turn to supervisor" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    with_supervisor(response_body: '{"thread_id":"fb-123"}') do |server|
      status, _, body = Tina4::Feedback.handle_request(
        make_env("POST", "/__feedback/api/turn",
                 body: { message: "page is broken", sender: "client-spoofed@bad.com" })
      )
      expect(status).to eq(200)

      captured = server.captured
      expect(captured[:method]).to eq("POST")
      expect(captured[:path]).to eq("/feedback/intake")
      expect(captured[:headers]["content-type"]).to include("application/json")

      forwarded = JSON.parse(captured[:body])
      # Server-stamped — client-supplied sender must be overwritten.
      expect(forwarded["sender"]).to eq("dev@example.com")
      expect(forwarded["message"]).to eq("page is broken")

      expect(JSON.parse(body.first)["thread_id"]).to eq("fb-123")
    end
  end

  it "serves widget.js with no-cache headers" do
    status, headers, body = Tina4::Feedback.handle_request(make_env("GET", "/__feedback/widget.js"))
    expect(status).to eq(200)
    expect(headers["content-type"]).to include("application/javascript")
    expect(headers["cache-control"]).to include("no-cache")
    expect(headers["cache-control"]).to include("must-revalidate")
    # Body must contain the widget bundle (or at least be non-empty)
    expect(body.first.to_s).not_to be_empty
  end
end
