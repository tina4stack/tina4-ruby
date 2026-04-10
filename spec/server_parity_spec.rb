# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::WebServer do
  let(:app) { Tina4::RackApp.new }
  let(:server) { Tina4::WebServer.new(app, host: "0.0.0.0", port: 17147) }

  describe "#handle" do
    it "dispatches a Rack env through the app and returns a response triple" do
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/health",
        "QUERY_STRING" => "",
        "SERVER_NAME" => "localhost",
        "SERVER_PORT" => "17147",
        "CONTENT_TYPE" => "",
        "CONTENT_LENGTH" => "0",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new(""),
        "rack.errors" => $stderr,
        "rack.url_scheme" => "http"
      }

      status, headers, body = server.handle(env)
      expect(status).to be_a(Integer)
      expect(headers).to be_a(Hash)
      expect(body).to respond_to(:each)
    end
  end

  describe "#start" do
    it "responds to start" do
      expect(server).to respond_to(:start)
    end
  end

  describe "#stop" do
    it "responds to stop" do
      expect(server).to respond_to(:stop)
    end
  end
end
