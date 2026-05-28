# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"

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

  # Captures the request the feedback handler would have fired at the
  # Rust agent and returns a canned response. Mirrors the stub pattern
  # used in dev_admin_parity_spec.rb (Tier 3 supervisor proxies).
  def stub_supervisor(response_body: "{}", content_type: "application/json", status_code: "200")
    captured = { method: nil, host: nil, port: nil, path: nil, body: nil, headers: {} }

    allow(Net::HTTP).to receive(:start) do |host, port, _opts = {}, &block|
      captured[:host] = host
      captured[:port] = port
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
    stub_supervisor(response_body: '{"ok":true}')

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

  it "forwards turn to supervisor" do
    ENV["TINA4_ENABLE_FEEDBACK"] = "true"
    ENV["TINA4_FEEDBACK_WHITELIST"] = "dev@example.com"
    ENV["TINA4_FEEDBACK_DEV_USER"] = "dev@example.com"
    captured = stub_supervisor(response_body: '{"thread_id":"fb-123"}')

    status, _, body = Tina4::Feedback.handle_request(
      make_env("POST", "/__feedback/api/turn",
               body: { message: "page is broken", sender: "client-spoofed@bad.com" })
    )
    expect(status).to eq(200)
    expect(captured[:method]).to eq("POST")
    expect(captured[:path]).to eq("/feedback/intake")
    expect(captured[:headers]["content-type"]).to include("application/json")

    forwarded = JSON.parse(captured[:body])
    # Server-stamped — client-supplied sender must be overwritten.
    expect(forwarded["sender"]).to eq("dev@example.com")
    expect(forwarded["message"]).to eq("page is broken")

    expect(JSON.parse(body.first)["thread_id"]).to eq("fb-123")
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
