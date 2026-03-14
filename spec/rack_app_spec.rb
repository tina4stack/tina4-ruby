# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::RackApp do
  let(:tmp_dir) { Dir.mktmpdir("tina4_rack_test") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) { Tina4::Router.clear! }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def mock_env(method, path, headers: {}, body: "")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7145",
      "rack.input" => StringIO.new(body)
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  describe "#call" do
    it "handles OPTIONS preflight" do
      status, headers, _body = app.call(mock_env("OPTIONS", "/api/test"))
      expect(status).to eq(204)
    end

    it "routes GET requests" do
      Tina4.get("/hello") { |_req, res| res.json({ message: "hi" }) }
      status, headers, body = app.call(mock_env("GET", "/hello"))
      expect(status).to eq(200)
      parsed = JSON.parse(body.join)
      expect(parsed["message"]).to eq("hi")
    end

    it "returns 404 for unknown routes" do
      status, _headers, _body = app.call(mock_env("GET", "/nonexistent"))
      expect(status).to eq(404)
    end

    it "serves static files" do
      # Create a static file
      pub_dir = File.join(tmp_dir, "public")
      FileUtils.mkdir_p(pub_dir)
      File.write(File.join(pub_dir, "test.txt"), "hello static")

      status, _headers, body = app.call(mock_env("GET", "/test.txt"))
      expect(status).to eq(200)
    end

    it "prevents path traversal" do
      result = app.call(mock_env("GET", "/../../../etc/passwd"))
      status = result[0]
      expect(status).to eq(404)
    end

    it "serves swagger UI" do
      status, _headers, body = app.call(mock_env("GET", "/swagger"))
      expect(status).to eq(200)
      expect(body.join).to include("swagger-ui")
    end

    it "serves OpenAPI JSON spec" do
      status, headers, body = app.call(mock_env("GET", "/swagger/openapi.json"))
      expect(status).to eq(200)
      spec = JSON.parse(body.join)
      expect(spec["openapi"]).to eq("3.0.3")
    end

    it "handles exceptions with 500" do
      Tina4.get("/crash") { |_req, _res| raise "boom" }
      status, _headers, _body = app.call(mock_env("GET", "/crash"))
      expect(status).to eq(500)
    end

    it "returns 403 for failed auth" do
      Tina4.secure_get("/secret") { |_req, res| res.json({ secret: true }) }
      status, _headers, _body = app.call(mock_env("GET", "/secret"))
      expect(status).to eq(403)
    end

    it "passes path params to handler" do
      Tina4.get("/users/{id}") { |req, res| res.json({ id: req.params["id"] }) }
      status, _headers, body = app.call(mock_env("GET", "/users/42"))
      expect(status).to eq(200)
      parsed = JSON.parse(body.join)
      expect(parsed["id"]).to eq("42")
    end
  end
end
