# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Response do
  let(:response) { Tina4::Response.new }

  describe "#json" do
    it "sets content type to application/json" do
      response.json({ hello: "world" })
      status, headers, body = response.to_rack
      expect(headers["content-type"] || headers["Content-Type"]).to include("json")
    end

    it "serializes hash to JSON" do
      response.json({ hello: "world" })
      _, _, body = response.to_rack
      parsed = JSON.parse(body.first)
      expect(parsed["hello"]).to eq("world")
    end

    it "accepts custom status code" do
      response.json({ created: true }, status: 201)
      status, _, _ = response.to_rack
      expect(status).to eq(201)
    end

    it "handles arrays" do
      response.json([1, 2, 3])
      _, _, body = response.to_rack
      expect(JSON.parse(body.first)).to eq([1, 2, 3])
    end

    it "returns self for chaining" do
      result = response.json({ test: true })
      expect(result).to be_a(Tina4::Response)
    end
  end

  describe "#html" do
    it "sets content type to text/html" do
      response.html("<h1>Hello</h1>")
      _, headers, _ = response.to_rack
      content_type = headers["content-type"] || headers["Content-Type"]
      expect(content_type).to include("html")
    end

    it "sets the body content" do
      response.html("<h1>Hello</h1>")
      _, _, body = response.to_rack
      expect(body.first).to eq("<h1>Hello</h1>")
    end

    it "accepts custom status code" do
      response.html("<h1>Not Found</h1>", status: 404)
      status, _, _ = response.to_rack
      expect(status).to eq(404)
    end
  end

  describe "#redirect" do
    it "sets 302 status by default" do
      response.redirect("/new-location")
      status, _, _ = response.to_rack
      expect(status).to eq(302)
    end

    it "sets location header" do
      response.redirect("/new-location")
      _, headers, _ = response.to_rack
      location = headers["location"] || headers["Location"]
      expect(location).to eq("/new-location")
    end

    it "accepts custom redirect status" do
      response.redirect("/permanent", status: 301)
      status, _, _ = response.to_rack
      expect(status).to eq(301)
    end
  end

  describe "#text" do
    it "sets content type to text/plain" do
      response.text("hello")
      _, headers, _ = response.to_rack
      content_type = headers["content-type"] || headers["Content-Type"]
      expect(content_type).to include("text/plain")
    end
  end

  describe "#set_cookie" do
    it "sets a cookie header" do
      response.set_cookie("session", "abc123")
      _, headers, _ = response.to_rack
      cookie = headers["set-cookie"] || headers["Set-Cookie"]
      expect(cookie.to_s).to include("session")
    end
  end

  describe "#to_rack" do
    it "returns a 3-element array" do
      result = response.to_rack
      expect(result).to be_an(Array)
      expect(result.length).to eq(3)
    end

    it "returns status as integer" do
      status, _, _ = response.to_rack
      expect(status).to be_an(Integer)
    end

    it "returns headers as hash" do
      _, headers, _ = response.to_rack
      expect(headers).to be_a(Hash)
    end

    it "returns body as array" do
      _, _, body = response.to_rack
      expect(body).to be_an(Array)
    end
  end

  describe "#add_cors_headers" do
    it "sets CORS headers" do
      response.add_cors_headers
      _, headers, _ = response.to_rack
      cors_header = headers["access-control-allow-origin"] || headers["Access-Control-Allow-Origin"]
      expect(cors_header).to eq("*")
    end
  end
end
