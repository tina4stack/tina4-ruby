# frozen_string_literal: true

# File upload contract (feature 44) - repeated field -> LIST, safe-save, per-chunk cap.
#
# Shared invariants: tina4-documentation/plan/v3/fixtures/fileupload_contract.json
# (UP-DEC-02 / UP-DEC-03, OWNER-DECISIONS Batch 4).
#
# No mocks: the repeated-field cases parse a REAL multipart body (a StringIO
# rack.input, NOT an injected rack.request.form_hash - injecting it is exactly
# what hid the live bug); the safe-save cases write to a REAL temp directory and
# read back what landed (and what did not); the per-chunk cap cases drive the
# REAL RackApp dispatch pipeline with a real over-size body whose declared length
# does not itself trip the declared-length guard, so only the running counter can
# refuse it.
#
# Mutation-proved: revert extract_files to Rack's last-wins and the two-files case
# goes RED (one file survives); drop the basename strip in save_upload and the
# traversal case goes RED (the escaped file appears); stop read_stream_capped from
# raising and the over-limit case is accepted (RED).

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe "File upload contract" do
  boundary = "----Tina4FileUploadContract"

  def multipart(boundary, files)
    body = +""
    files.each do |name, filename, content|
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n"
      body << "Content-Type: application/octet-stream\r\n\r\n"
      body << content
      body << "\r\n"
    end
    body << "--#{boundary}--\r\n"
    body.force_encoding("BINARY")
  end

  def multipart_request(boundary, body, content_length: body.bytesize)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/upload",
      "QUERY_STRING" => "",
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.input" => StringIO.new(body)
    }
    env["CONTENT_LENGTH"] = content_length.to_s if content_length
    Tina4::Request.new(env)
  end

  # ── UP-MULTIFILE-LOSS: repeated field name -> a LIST ──────────────────────

  describe "repeated field name" do
    it "two files under one field name arrive as a list" do
      body = multipart(boundary, [
        ["photos", "a.txt", "AAAA-first"],
        ["photos", "b.txt", "BBBB-second"]
      ])
      entry = multipart_request(boundary, body).files["photos"]

      expect(entry).to be_a(Array), "expected a list of 2, got #{entry.class}"
      expect(entry.length).to eq(2) # both files survive - neither silently dropped
      expect(entry.map { |f| f["filename"] }).to eq(["a.txt", "b.txt"])
      expect(entry[0]["content"]).to eq("AAAA-first")
      expect(entry[1]["content"]).to eq("BBBB-second")
    end

    it "a single file stays a single descriptor" do
      body = multipart(boundary, [["avatar", "solo.txt", "only-one"]])
      entry = multipart_request(boundary, body).files["avatar"]

      expect(entry).not_to be_a(Array) # a single occurrence stays a plain descriptor
      expect(entry["filename"]).to eq("solo.txt")
      expect(entry["content"]).to eq("only-one")
    end
  end

  # ── UP-FILENAME-UNTRUSTED: safe-save confines the write ───────────────────

  describe "safe save" do
    around do |example|
      Dir.mktmpdir("tina4-safesave-") do |dir|
        @root = dir
        example.run
      end
    end

    it "safe save writes a traversal filename inside the target dir" do
      target = File.join(@root, "uploads")
      FileUtils.mkdir_p(target)
      descriptor = { "filename" => "../../evil.txt", "content" => "payload", "type" => "text/plain" }

      saved = Tina4::Request.save_upload(descriptor, target)

      # It landed INSIDE the target dir, under the stripped basename ...
      expect(File.realpath(File.dirname(saved))).to eq(File.realpath(target))
      expect(File.basename(saved)).to eq("evil.txt")
      expect(File.binread(saved)).to eq("payload")
      # ... and NOT at the escaped location the raw name pointed at.
      expect(File.exist?(File.join(@root, "evil.txt"))).to be(false) # the traversal escaped
    end

    it "safe save refuses an unusable filename" do
      target = File.join(@root, "uploads")
      FileUtils.mkdir_p(target)

      expect do
        Tina4::Request.save_upload({ "filename" => "..", "content" => "x" }, target)
      end.to raise_error(ArgumentError)
      expect do
        Tina4::Request.save_upload({ "filename" => "ok\u0000.txt", "content" => "x" }, target)
      end.to raise_error(ArgumentError)
    end
  end

  # ── UP-CHUNKED-BYPASS: running per-chunk size guard (413) ──────────────────

  describe "per-chunk size guard" do
    max_upload = 2048

    around do |example|
      previous = ENV["TINA4_MAX_UPLOAD_SIZE"]
      ENV["TINA4_MAX_UPLOAD_SIZE"] = max_upload.to_s
      Tina4::Router.clear!
      # A realistic upload handler reads request.files; that read is what drives
      # the running per-chunk counter over rack.input.
      Tina4::Router.post("/upload") do |request, response|
        response.json({ count: request.files.size }, 200)
      end.no_auth
      begin
        example.run
      ensure
        Tina4::Router.clear!
        if previous.nil?
          ENV.delete("TINA4_MAX_UPLOAD_SIZE")
        else
          ENV["TINA4_MAX_UPLOAD_SIZE"] = previous
        end
      end
    end

    it "an over limit upload is refused with 413" do
      # ACTUAL body 4x the cap, but NO Content-Length - so the declared-length
      # guard sees nothing and only the running counter can stop it.
      body = multipart(boundary, [["file", "big.bin", "a" * (max_upload * 4)]])
      env = {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/upload",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new(body)
      }
      status, _headers, resp = Tina4::RackApp.new.call(env)

      expect(status).to eq(413)
      expect(JSON.parse(resp.join)["error"]).to include("TINA4_MAX_UPLOAD_SIZE")
    end

    it "a body under the limit is accepted" do
      body = multipart(boundary, [["file", "small.bin", "a" * 256]])
      expect(body.bytesize).to be < max_upload
      env = {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/upload",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
        "CONTENT_LENGTH" => body.bytesize.to_s,
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new(body)
      }
      status, _headers, _resp = Tina4::RackApp.new.call(env)

      expect(status).to eq(200)
    end
  end
end
