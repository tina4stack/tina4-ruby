# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Middleware do
  before(:each) { Tina4::Middleware.clear! }

  let(:request) do
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/api/users",
      "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost",
      "rack.input" => StringIO.new("")
    }
    Tina4::Request.new(env)
  end

  let(:response) { Tina4::Response.new }

  describe ".before" do
    it "registers a before handler" do
      Tina4::Middleware.before { |_req, _res| true }
      expect(Tina4::Middleware.before_handlers.length).to eq(1)
    end

    it "registers with a pattern" do
      Tina4::Middleware.before("/api") { |_req, _res| true }
      expect(Tina4::Middleware.before_handlers.first[:pattern]).to eq("/api")
    end
  end

  describe ".after" do
    it "registers an after handler" do
      Tina4::Middleware.after { |_req, _res| true }
      expect(Tina4::Middleware.after_handlers.length).to eq(1)
    end
  end

  describe ".run_before" do
    it "runs matching before handlers" do
      called = false
      Tina4::Middleware.before { |_req, _res| called = true }
      Tina4::Middleware.run_before([], request, response)
      expect(called).to be true
    end

    it "halts on false return" do
      Tina4::Middleware.before { |_req, _res| false }
      result = Tina4::Middleware.run_before([], request, response)
      expect(result).to be false
    end

    it "skips non-matching patterns" do
      called = false
      Tina4::Middleware.before("/admin") { |_req, _res| called = true }
      Tina4::Middleware.run_before([], request, response)
      expect(called).to be false
    end

    it "matches string prefix patterns" do
      called = false
      Tina4::Middleware.before("/api") { |_req, _res| called = true }
      Tina4::Middleware.run_before([], request, response)
      expect(called).to be true
    end

    it "matches regexp patterns" do
      called = false
      Tina4::Middleware.before(/\/api\/.*/) { |_req, _res| called = true }
      Tina4::Middleware.run_before([], request, response)
      expect(called).to be true
    end
  end

  describe ".run_after" do
    it "runs matching after handlers" do
      called = false
      Tina4::Middleware.after { |_req, _res| called = true }
      Tina4::Middleware.run_after([], request, response)
      expect(called).to be true
    end
  end

  describe ".clear!" do
    it "removes all handlers" do
      Tina4::Middleware.before { |_req, _res| true }
      Tina4::Middleware.after { |_req, _res| true }
      Tina4::Middleware.clear!
      expect(Tina4::Middleware.before_handlers).to be_empty
      expect(Tina4::Middleware.after_handlers).to be_empty
    end
  end
end
