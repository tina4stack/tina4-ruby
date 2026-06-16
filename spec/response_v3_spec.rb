# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Response v3 features" do
  let(:response) { Tina4::Response.new }

  describe "#json" do
    it "sets JSON content type and body" do
      response.json({ name: "Alice" })
      expect(response.headers["content-type"]).to eq("application/json; charset=utf-8")
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Alice")
    end

    it "sets custom status code" do
      response.json({ created: true }, status: 201)
      expect(response.status_code).to eq(201)
    end

    it "accepts positional status code" do
      response.json({ error: "not found" }, 404)
      expect(response.status_code).to eq(404)
    end
  end

  describe "#html" do
    it "sets HTML content type and body" do
      response.html("<h1>Hello</h1>")
      expect(response.headers["content-type"]).to eq("text/html; charset=utf-8")
      expect(response.body).to eq("<h1>Hello</h1>")
    end
  end

  describe "#text" do
    it "sets text content type and body" do
      response.text("plain text")
      expect(response.headers["content-type"]).to eq("text/plain; charset=utf-8")
      expect(response.body).to eq("plain text")
    end
  end

  describe "#redirect" do
    it "sets location header and 302 status" do
      response.redirect("/new-location")
      expect(response.status_code).to eq(302)
      expect(response.headers["location"]).to eq("/new-location")
    end

    it "supports custom redirect status" do
      response.redirect("/permanent", status: 301)
      expect(response.status_code).to eq(301)
    end
  end

  describe "#status (chainable)" do
    it "sets status and returns self" do
      result = response.status(404)
      expect(result).to equal(response)
      expect(response.status_code).to eq(404)
    end

    it "returns current status when called without argument" do
      response.status_code = 201
      expect(response.status).to eq(201)
    end
  end

  describe "#header (chainable)" do
    it "sets a custom header and returns self" do
      result = response.header("X-Custom", "value")
      expect(result).to equal(response)
      expect(response.headers["X-Custom"]).to eq("value")
    end

    it "gets a header value when called with one arg" do
      response.headers["X-Custom"] = "test"
      expect(response.header("X-Custom")).to eq("test")
    end
  end

  describe "#cookie (chainable)" do
    it "sets a cookie and returns self" do
      result = response.cookie("session", "abc123")
      expect(result).to equal(response)
      expect(response.cookies.length).to eq(1)
      expect(response.cookies.first).to include("session=abc123")
    end

    it "supports cookie options" do
      response.cookie("token", "xyz", secure: true, max_age: 3600)
      cookie_str = response.cookies.first
      expect(cookie_str).to include("Secure")
      expect(cookie_str).to include("Max-Age=3600")
    end
  end

  describe "#set_cookie" do
    it "adds HttpOnly by default" do
      response.set_cookie("test", "value")
      expect(response.cookies.first).to include("HttpOnly")
    end

    it "adds SameSite=Lax by default" do
      response.set_cookie("test", "value")
      expect(response.cookies.first).to include("SameSite=Lax")
    end

    it "supports custom path" do
      response.set_cookie("test", "value", path: "/api")
      expect(response.cookies.first).to include("Path=/api")
    end
  end

  describe "#delete_cookie" do
    it "sets Max-Age=0 to delete cookie" do
      response.delete_cookie("old_cookie")
      expect(response.cookies.first).to include("Max-Age=0")
    end
  end

  describe "#to_rack" do
    it "returns rack-compatible triple" do
      response.json({ ok: true }, status: 200)
      status, headers, body = response.to_rack
      expect(status).to eq(200)
      expect(headers).to be_a(Hash)
      expect(body).to be_a(Array)
    end

    it "includes cookies in Set-Cookie header" do
      response.cookie("a", "1").cookie("b", "2")
      status, headers, body = response.to_rack
      expect(headers["set-cookie"]).to include("a=1")
      expect(headers["set-cookie"]).to include("b=2")
    end
  end

  describe "#send" do
    it "is an alias for to_rack" do
      response.text("hello")
      expect(response.send).to eq(response.to_rack)
    end
  end

  describe ".auto_detect" do
    it "detects Hash as JSON" do
      result = Tina4::Response.auto_detect({ key: "value" }, response)
      expect(result.headers["content-type"]).to include("json")
    end

    it "detects Array as JSON" do
      result = Tina4::Response.auto_detect([1, 2, 3], response)
      expect(result.headers["content-type"]).to include("json")
    end

    it "detects HTML string" do
      result = Tina4::Response.auto_detect("<div>hello</div>", response)
      expect(result.headers["content-type"]).to include("html")
    end

    it "detects plain text" do
      result = Tina4::Response.auto_detect("just text", response)
      expect(result.headers["content-type"]).to include("text/plain")
    end

    it "handles nil as 204" do
      result = Tina4::Response.auto_detect(nil, response)
      expect(result.status_code).to eq(204)
    end

    it "handles Integer as status code" do
      result = Tina4::Response.auto_detect(404, response)
      expect(result.status_code).to eq(404)
    end
  end

  describe "chaining" do
    it "supports method chaining" do
      result = response.status(201)
                       .header("X-Request-Id", "abc")
                       .json({ created: true })
      # json sets status to 200 by default, but we set 201 first
      # Since json resets status, check that chaining works
      expect(result).to equal(response)
      expect(response.headers["X-Request-Id"]).to eq("abc")
    end
  end

  describe "#stream" do
    # Helper: drain the Rack body into the list of chunks it yields.
    def stream_chunks(resp)
      _status, _headers, body = resp.to_rack
      chunks = []
      body.each { |c| chunks << c }
      chunks
    end

    it "sets SSE headers and returns self" do
      result = response.stream { |out| out << "data: x\n\n" }
      expect(result).to equal(response)
      expect(response.headers["content-type"]).to eq("text/event-stream")
      expect(response.headers["cache-control"]).to eq("no-cache")
      expect(response.headers["connection"]).to eq("keep-alive")
      expect(response.headers["x-accel-buffering"]).to eq("no")
    end

    it "streams from a block (unchanged behaviour)" do
      response.stream do |out|
        3.times { |i| out << "data: msg #{i}\n\n" }
      end
      _status, _headers, body = response.to_rack
      expect(body).to be_a(Enumerator)
      expect(stream_chunks(response)).to eq([
        "data: msg 0\n\n", "data: msg 1\n\n", "data: msg 2\n\n"
      ])
    end

    it "streams from a positional Enumerator generator (Python/PHP/Node parity)" do
      gen = Enumerator.new do |y|
        3.times { |i| y << "data: gen #{i}\n\n" }
      end
      response.stream(gen)
      _status, _headers, body = response.to_rack
      expect(body).to be_a(Enumerator)
      expect(stream_chunks(response)).to eq([
        "data: gen 0\n\n", "data: gen 1\n\n", "data: gen 2\n\n"
      ])
    end

    it "streams from any object responding to #each (e.g. an Array)" do
      response.stream(["a", "b", "c"])
      expect(stream_chunks(response)).to eq(["a", "b", "c"])
    end

    it "streams from a callable generator (responds to #call with a yielder)" do
      callable = ->(out) { 2.times { |i| out << "c#{i}" } }
      response.stream(callable)
      expect(stream_chunks(response)).to eq(["c0", "c1"])
    end

    it "honours a custom content_type with a positional generator" do
      response.stream(["x"], content_type: "text/plain")
      expect(response.headers["content-type"]).to eq("text/plain")
      expect(stream_chunks(response)).to eq(["x"])
    end
  end
end
