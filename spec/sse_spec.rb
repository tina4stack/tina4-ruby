# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Response#stream — Server-Sent Events (SSE)" do
  let(:response) { Tina4::Response.new }

  describe "headers" do
    it "sets content-type to text/event-stream by default" do
      response.stream { |out| out << "data: hello\n\n" }
      _, headers, _ = response.to_rack
      expect(headers["content-type"]).to eq("text/event-stream")
    end

    it "sets cache-control to no-cache" do
      response.stream { |out| out << "data: hello\n\n" }
      _, headers, _ = response.to_rack
      expect(headers["cache-control"]).to eq("no-cache")
    end

    it "sets connection to keep-alive" do
      response.stream { |out| out << "data: hello\n\n" }
      _, headers, _ = response.to_rack
      expect(headers["connection"]).to eq("keep-alive")
    end

    it "sets x-accel-buffering to no" do
      response.stream { |out| out << "data: hello\n\n" }
      _, headers, _ = response.to_rack
      expect(headers["x-accel-buffering"]).to eq("no")
    end

    it "accepts a custom content type" do
      response.stream(content_type: "application/octet-stream") { |out| out << "\x00\x01" }
      _, headers, _ = response.to_rack
      expect(headers["content-type"]).to eq("application/octet-stream")
    end
  end

  describe "streaming body" do
    it "returns an Enumerator as the Rack body" do
      response.stream { |out| out << "data: hello\n\n" }
      _, _, body = response.to_rack
      expect(body).to be_a(Enumerator)
    end

    it "yields chunks from the block" do
      response.stream do |out|
        out << "data: message 0\n\n"
        out << "data: message 1\n\n"
        out << "data: message 2\n\n"
      end
      _, _, body = response.to_rack

      chunks = []
      body.each { |chunk| chunks << chunk }
      expect(chunks.length).to eq(3)
      expect(chunks[0]).to eq("data: message 0\n\n")
      expect(chunks[1]).to eq("data: message 1\n\n")
      expect(chunks[2]).to eq("data: message 2\n\n")
    end

    it "handles a single chunk" do
      response.stream { |out| out << "data: hello\n\n" }
      _, _, body = response.to_rack

      chunks = body.to_a
      expect(chunks).to eq(["data: hello\n\n"])
    end

    it "handles SSE-formatted event messages" do
      response.stream do |out|
        5.times do |i|
          out << "event: update\ndata: {\"count\":#{i}}\n\n"
        end
      end
      _, _, body = response.to_rack

      chunks = body.to_a
      expect(chunks.length).to eq(5)
      expect(chunks.first).to include("event: update")
      expect(chunks.first).to include('"count":0')
      expect(chunks.last).to include('"count":4')
    end
  end

  describe "status code" do
    it "defaults to 200" do
      response.stream { |out| out << "data: hello\n\n" }
      status, _, _ = response.to_rack
      expect(status).to eq(200)
    end

    it "preserves a custom status code set before stream" do
      response.status(201)
      response.stream { |out| out << "data: hello\n\n" }
      status, _, _ = response.to_rack
      expect(status).to eq(201)
    end
  end

  describe "fluent interface" do
    it "returns self for chaining" do
      result = response.stream { |out| out << "data: hello\n\n" }
      expect(result).to be(response)
    end
  end

  describe "non-SSE streaming" do
    it "streams NDJSON with custom content type" do
      response.stream(content_type: "application/x-ndjson") do |out|
        out << "{\"event\":\"start\"}\n"
        out << "{\"event\":\"end\"}\n"
      end
      _, headers, body = response.to_rack

      expect(headers["content-type"]).to eq("application/x-ndjson")
      chunks = body.to_a
      expect(chunks.length).to eq(2)
      expect(chunks[0]).to include('"event":"start"')
    end
  end
end
