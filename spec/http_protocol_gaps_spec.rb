# frozen_string_literal: true

# RFC 9110 conformance — HTTP method handling gaps in tina4-ruby's Router.
#
# Same regression class as the 24stack v3.11.36 report against tina4-php
# and parity port of tests/HttpProtocolGapsTest.php / test_http_protocol_gaps.py.
#
# Tests are written BEFORE the fix lands — expect failures on 3.12.6, all
# green after the patch.

require "spec_helper"
require "stringio"

RSpec.describe "RFC 9110 HTTP method conformance (Tina4 Ruby)" do
  before(:each) do
    Tina4::Router.clear!
    ENV["TINA4_DEBUG"] = "false"
  end

  def mock_env(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new("")
    }
  end

  def dispatch(method, path)
    app = Tina4::RackApp.new
    status, headers, body_parts = app.call(mock_env(method, path))
    body = body_parts.respond_to?(:join) ? body_parts.join : body_parts.to_s
    [status, headers, body]
  end

  def header(headers, name)
    target = name.downcase
    headers.each { |k, v| return v if k.to_s.downcase == target }
    nil
  end

  def head_req(path);    dispatch("HEAD",    path); end
  def get_req(path);     dispatch("GET",     path); end
  def put_req(path);     dispatch("PUT",     path); end
  def options_req(path); dispatch("OPTIONS", path); end
  def trace_req(path);   dispatch("TRACE",   path); end
  def connect_req(path); dispatch("CONNECT", path); end

  # ── Group 1: HEAD auto-fallback to GET ────────────────────────────────

  it "HEAD on a GET route returns 200" do
    Tina4::Router.get("/welcome") { |_req, res| res.json({ ok: true }) }
    status, headers, body = head_req("/welcome")
    expect(status).to eq(200), "HEAD MUST succeed on every GET route (RFC 9110 §9.3.2)"
  end

  it "HEAD response body is empty" do
    Tina4::Router.get("/welcome") { |_req, res| res.json({ heavy: "x" * 5000 }) }
    status, headers, body = head_req("/welcome")
    expect(body).to eq(""), "RFC 9110 §9.3.2: server MUST NOT send content in HEAD response"
  end

  it "HEAD carries same Content-Type as GET" do
    Tina4::Router.get("/welcome") { |_req, res| res.json({ ok: true }) }
    status, headers, body = head_req("/welcome")
    expect(headers["content-type"] || headers["Content-Type"]).to include("application/json")
  end

  it "HEAD on a non-existent path still returns 404" do
    Tina4::Router.get("/welcome") { |_req, res| res.json({ ok: true }) }
    status, headers, body = head_req("/does/not/exist")
    expect(status).to eq(404)
  end

  it "HEAD on a POST-only path returns 405 with Allow header" do
    Tina4::Router.post("/submit") { |_req, res| res.json({ created: true }) }
    status, headers, body = head_req("/submit")
    expect(status).to eq(405), "HEAD only auto-falls back to GET, never to other methods"
    allow = header(headers, "Allow") || ""
    expect(allow).to include("POST")
  end

  # ── Group 2: 405 Method Not Allowed + Allow header ─────────────────

  it "Wrong method on existing path returns 405 (not 404)" do
    Tina4::Router.post("/submit") { |_req, res| res.json({ ok: true }) }
    status, headers, body = get_req("/submit")
    expect(status).to eq(405), "RFC 9110 §15.5.6: wrong method on existing path is 405, not 404"
  end

  it "405 includes Allow header listing valid methods" do
    Tina4::Router.get("/x") { |_req, res| res.json({}) }
    Tina4::Router.post("/x") { |_req, res| res.json({}) }
    status, headers, body = put_req("/x")
    expect(status).to eq(405)
    allow = header(headers, "Allow") || ""
    allowed = allow.split(",").map(&:strip)
    expect(allowed).to include("GET", "POST")
    expect(allowed).not_to include("PUT"), "PUT is what was asked — must NOT be in Allow"
  end

  it "Allow includes HEAD and OPTIONS when GET is registered" do
    Tina4::Router.get("/page") { |_req, res| res.json({}) }
    status, headers, body = put_req("/page")
    expect(status).to eq(405)
    allow = header(headers, "Allow") || ""
    allowed = allow.split(",").map(&:strip)
    expect(allowed).to include("GET", "HEAD", "OPTIONS")
  end

  # ── Group 3: Generic OPTIONS handler ────────────────────────────────

  it "OPTIONS on an existing path returns 204" do
    Tina4::Router.get("/foo") { |_req, res| res.json({}) }
    status, headers, body = options_req("/foo")
    expect(status).to eq(204), "RFC 9110 §9.3.7: OPTIONS returns 204 No Content with Allow"
  end

  it "OPTIONS Allow includes all registered methods plus HEAD + OPTIONS" do
    Tina4::Router.get("/r")    { |_req, res| res.json({}) }
    Tina4::Router.post("/r")   { |_req, res| res.json({}) }
    Tina4::Router.delete("/r") { |_req, res| res.json({}) }
    status, headers, body = options_req("/r")
    allow = header(headers, "Allow") || ""
    allowed = allow.split(",").map(&:strip)
    %w[GET POST DELETE HEAD OPTIONS].each do |m|
      expect(allowed).to include(m), "OPTIONS Allow header missing #{m}"
    end
    expect(allowed).not_to include("PUT", "PATCH")
  end

  it "OPTIONS on a non-existent path returns 404" do
    Tina4::Router.get("/exists") { |_req, res| res.json({}) }
    status, headers, body = options_req("/does/not/exist")
    expect(status).to eq(404)
  end

  # ── Group 4: TRACE / CONNECT explicit rejection ─────────────────────

  it "TRACE on existing path returns 405" do
    Tina4::Router.get("/x") { |_req, res| res.json({}) }
    status, headers, body = trace_req("/x")
    expect(status).to eq(405), "TRACE must always be 405 (security)"
    allow = header(headers, "Allow") || ""
    expect(allow.split(",").map(&:strip)).not_to include("TRACE")
  end

  it "CONNECT on existing path returns 405" do
    Tina4::Router.get("/x") { |_req, res| res.json({}) }
    status, headers, body = connect_req("/x")
    expect(status).to eq(405), "CONNECT is for proxies; an origin server must reject it"
  end

  # ── Group 5: Explicit head() / options() registration ──────────────

  it "Explicit Router.head() registration is honoured" do
    Tina4::Router.get("/probe") { |_req, res| res.json({ from: "get" }) }
    Tina4::Router.head("/probe") do |_req, res|
      res.header("X-Probe-Source", "custom-head")
      res.json({})
    end
    status, headers, body = head_req("/probe")
    expect(status).to eq(200)
    expect(header(headers, "X-Probe-Source")).to eq("custom-head"),
      "Explicit Router.head() must override the GET auto-fallback"
  end

  it "Explicit Router.options() registration is honoured" do
    Tina4::Router.get("/cfg") { |_req, res| res.json({}) }
    Tina4::Router.options("/cfg") do |_req, res|
      res.header("X-Custom-Options", "yes")
      res.json({ custom: true })
    end
    status, headers, body = options_req("/cfg")
    expect(header(headers, "X-Custom-Options")).to eq("yes"),
      "Explicit Router.options() must override the generic 204 handler"
  end

  # ── Group 6: HEAD body strip is unconditional ──────────────────────

  it "Explicit HEAD handler body is also stripped" do
    Tina4::Router.head("/x") { |_req, res| res.json({ accidentally: "returned a body" }) }
    status, headers, body = head_req("/x")
    expect(status).to eq(200)
    expect(body).to eq(""), "HEAD body strip is unconditional — RFC 9110 §9.3.2 MUST"
  end

  it "HEAD response keeps Content-Length of the GET-equivalent body" do
    Tina4::Router.get("/sized") { |_req, res| res.json({ msg: "hi" }) }
    status, headers, body = head_req("/sized")
    cl = header(headers, "Content-Length")
    expect(cl).not_to be_nil
    expect(cl.to_i).to be > 0
  end
end
