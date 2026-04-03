# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe "Multipart file upload parsing" do
  LOGO_PATH = File.expand_path("../lib/tina4/public/images/logo.svg", __dir__)

  def make_env(overrides = {})
    {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/upload",
      "QUERY_STRING" => "",
      "CONTENT_TYPE" => "multipart/form-data; boundary=----TestBoundary",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.input" => StringIO.new(""),
      "rack.url_scheme" => "http",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147"
    }.merge(overrides)
  end

  def make_upload(path, filename, content_type)
    tempfile = Tempfile.new(filename)
    tempfile.binmode
    tempfile.write(File.binread(path))
    tempfile.rewind
    { filename: filename, type: content_type, tempfile: tempfile }
  end

  after(:each) do
    # Close any tempfiles created during tests
    @uploads&.each { |u| u[:tempfile].close rescue nil }
  end

  describe "single file upload" do
    it "file appears in request.files with correct filename and type" do
      upload = make_upload(LOGO_PATH, "logo.svg", "image/svg+xml")
      @uploads = [upload]

      env = make_env(
        "rack.request.form_hash" => {
          "avatar" => upload
        }
      )

      request = Tina4::Request.new(env)
      expect(request.files).to have_key("avatar")
      expect(request.files["avatar"][:filename]).to eq("logo.svg")
      expect(request.files["avatar"][:type]).to eq("image/svg+xml")
    end
  end

  describe "file content via tempfile" do
    it "content is raw bytes accessible via tempfile.read" do
      upload = make_upload(LOGO_PATH, "logo.svg", "image/svg+xml")
      @uploads = [upload]

      env = make_env(
        "rack.request.form_hash" => {
          "file" => upload
        }
      )

      request = Tina4::Request.new(env)
      raw = request.files["file"][:tempfile].read
      expect(raw).to be_a(String)
      expect(raw.bytesize).to be > 0
      expect(raw.bytesize).to eq(File.size(LOGO_PATH))
    end
  end

  describe "non-file fields vs file fields" do
    it "non-file fields go to body_parsed, files go to request.files" do
      upload = make_upload(LOGO_PATH, "logo.svg", "image/svg+xml")
      @uploads = [upload]

      env = make_env(
        "rack.request.form_hash" => {
          "description" => "A logo image",
          "document" => upload
        }
      )

      request = Tina4::Request.new(env)

      # The file field must be in files
      expect(request.files).to have_key("document")
      expect(request.files["document"][:filename]).to eq("logo.svg")

      # The plain string field must NOT be in files
      expect(request.files).not_to have_key("description")
    end
  end

  describe "multiple files under different field names" do
    it "each file appears under its own field name in request.files" do
      upload_a = make_upload(LOGO_PATH, "logo_a.svg", "image/svg+xml")
      upload_b = make_upload(LOGO_PATH, "logo_b.svg", "image/svg+xml")
      @uploads = [upload_a, upload_b]

      env = make_env(
        "rack.request.form_hash" => {
          "icon" => upload_a,
          "banner" => upload_b
        }
      )

      request = Tina4::Request.new(env)

      expect(request.files.keys).to contain_exactly("icon", "banner")
      expect(request.files["icon"][:filename]).to eq("logo_a.svg")
      expect(request.files["banner"][:filename]).to eq("logo_b.svg")
      expect(request.files["icon"][:size]).to be > 0
      expect(request.files["banner"][:size]).to be > 0
    end
  end

  describe "SVG content validation" do
    it "uploaded content contains valid SVG markup" do
      upload = make_upload(LOGO_PATH, "logo.svg", "image/svg+xml")
      @uploads = [upload]

      env = make_env(
        "rack.request.form_hash" => {
          "logo" => upload
        }
      )

      request = Tina4::Request.new(env)
      content = request.files["logo"][:tempfile].read
      expect(content).to include("<svg")
      expect(content).to include("</svg>")
      expect(content).to include("xmlns")
    end
  end
end
