# frozen_string_literal: true

# Tina4's own multipart/form-data parser (zero-dependency step 5).
#
# Request#body used to hand multipart bodies to Rack::Request#POST. Rack is no
# longer a dependency, so Tina4::FormParser now does the parse - and it must
# produce the SAME shape Rack produced, or every Ruby app that posts
# `user[name]` or `tags[]` silently changes under it.
#
# The expected values below are CHARACTERISATION values: each was produced by
# running the identical multipart bytes through Rack 3.2.7's Rack::Request#POST
# before Rack was removed (the script is reproduced in the plan file). Where
# Tina4 deliberately differs, the example says so and why.
#
# NO MOCKS: real multipart bytes through the real Tina4::Request.

require "spec_helper"
require "stringio"

RSpec.describe "Tina4 multipart form parser" do
  let(:boundary) { "XyZ" }

  def multipart(parts)
    parts.map do |name, value, extra|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"#{extra}\r\n\r\n#{value}\r\n"
    end.join + "--#{boundary}--\r\n"
  end

  def request_for(body, content_type: "multipart/form-data; boundary=#{boundary}")
    Tina4::Request.new(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/", "QUERY_STRING" => "",
      "CONTENT_TYPE" => content_type, "CONTENT_LENGTH" => body.bytesize.to_s,
      "REMOTE_ADDR" => "127.0.0.1", "rack.input" => StringIO.new(body.b)
    )
  end

  def fields(parts)
    request_for(multipart(parts)).body
  end

  describe "field shapes (Rack-compatible, characterised against Rack 3.2.7)" do
    it "keeps the LAST value of a repeated plain name" do
      expect(fields([%w[a 1], %w[a 2]])).to eq("a" => "2")
    end

    it "collects a[] into an array" do
      expect(fields([%w[a[] 1], %w[a[] 2]])).to eq("a" => %w[1 2])
    end

    it "nests a[b] into a hash" do
      expect(fields([%w[a[b] 1], %w[a[c] 2]])).to eq("a" => { "b" => "1", "c" => "2" })
    end

    it "nests deeply" do
      expect(fields([%w[a[b][c] 1]])).to eq("a" => { "b" => { "c" => "1" } })
    end

    it "builds an array of hashes from a[][x], starting a new hash on a repeated key" do
      expect(fields([%w[a[][x] 1], %w[a[][y] 2], %w[a[][x] 3]]))
        .to eq("a" => [{ "x" => "1", "y" => "2" }, { "x" => "3" }])
    end

    it "nests an array inside a hash" do
      expect(fields([%w[a[b][] 1], %w[a[b][] 2]])).to eq("a" => { "b" => %w[1 2] })
    end

    it "keeps malformed bracket names literally" do
      expect(fields([["a[", "1"]])).to eq("a[" => "1")
      expect(fields([["[]", "1"]])).to eq("[]" => "1")
      expect(fields([["a]", "1"]])).to eq("a]" => "1")
    end

    it "keeps an empty value" do
      expect(fields([["a", ""]])).to eq("a" => "")
    end

    it "decodes field values as UTF-8" do
      value = fields([["naam", "café"]])["naam"]
      expect(value).to eq("café")
      expect(value.encoding).to eq(Encoding::UTF_8)
    end

    it "leaves file parts out of the fields" do
      expect(fields([["f", "data", '; filename="x.txt"'], %w[k v]])).to eq("k" => "v")
    end

    it "leaves an empty file field out of the fields" do
      expect(fields([["f", "", '; filename=""'], %w[k v]])).to eq("k" => "v")
    end

    it "refuses a name used as both a value and a hash (Rack raised; the fields come back empty)" do
      expect(fields([%w[a 1], %w[a[b] 2]])).to eq({})
      expect(fields([%w[a[] 1], %w[a[b] 2]])).to eq({})
    end

    # Deliberate difference: Rack invented the key "text/plain" for a part
    # with no name. Python's _parse_multipart and PHP's parseMultipartBody skip
    # a nameless part, and so does Tina4 now.
    it "skips a part with no name (Python / PHP parity)" do
      expect(fields([["", "1"], %w[b 2]])).to eq("b" => "2")
    end

    it "refuses nesting deeper than 32 levels instead of recursing without bound" do
      name = "a" + ("[x]" * 40)
      expect(fields([[name, "1"]])).to eq({})
    end
  end

  describe "files" do
    it "returns content, filename and type for a file part" do
      request = request_for(multipart([["doc", "hello", "; filename=\"a.txt\"\r\nContent-Type: text/plain"]]))
      file = request.files["doc"]
      expect(file["filename"]).to eq("a.txt")
      expect(file["type"]).to eq("text/plain")
      expect(file["content"]).to eq("hello")
      expect(file["size"]).to eq(5)
    end

    it "defaults a file's type to application/octet-stream" do
      request = request_for(multipart([["doc", "x", '; filename="a.bin"']]))
      expect(request.files["doc"]["type"]).to eq("application/octet-stream")
    end

    it "keeps an empty file field as a zero-byte descriptor (unchanged behaviour)" do
      request = request_for(multipart([["doc", "", '; filename=""']]))
      expect(request.files["doc"]["filename"]).to eq("")
      expect(request.files["doc"]["size"]).to eq(0)
    end

    it "does not truncate a file whose bytes contain the boundary text without a leading CRLF" do
      content = "before --#{boundary} after"
      request = request_for(multipart([["doc", content, '; filename="a.txt"']]))
      expect(request.files["doc"]["content"]).to eq(content)
    end

    it "reads name and filename by parameter, whatever their order" do
      body = "--#{boundary}\r\nContent-Disposition: form-data; filename=\"a.txt\"; name=\"doc\"\r\n\r\nhi\r\n--#{boundary}--\r\n"
      request = request_for(body)
      expect(request.files.keys).to eq(["doc"])
      expect(request.files["doc"]["filename"]).to eq("a.txt")
    end

    it "keeps binary bytes intact" do
      bytes = (0..255).map(&:chr).join.b
      request = request_for(multipart([["bin", bytes, '; filename="b.bin"']]))
      expect(request.files["bin"]["content"].b).to eq(bytes)
    end

    it "accepts a quoted boundary" do
      body = multipart([%w[k v]])
      expect(request_for(body, content_type: "multipart/form-data; boundary=\"#{boundary}\"").body).to eq("k" => "v")
    end
  end
end
