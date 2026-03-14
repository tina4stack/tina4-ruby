# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Session do
  let(:tmp_dir) { Dir.mktmpdir("tina4_sess_test") }
  let(:env) { { "HTTP_COOKIE" => "" } }
  let(:options) { { handler: :file, handler_options: { dir: tmp_dir } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  describe "#initialize" do
    it "creates a session with a unique id" do
      session = Tina4::Session.new(env, options)
      expect(session.id).to be_a(String)
      expect(session.id.length).to be > 0
    end

    it "restores session from cookie" do
      s1 = Tina4::Session.new(env, options)
      s1["user"] = "Alice"
      s1.save

      env2 = { "HTTP_COOKIE" => "tina4_session=#{s1.id}" }
      s2 = Tina4::Session.new(env2, options)
      expect(s2["user"]).to eq("Alice")
    end
  end

  describe "#[] and #[]=" do
    it "gets and sets values" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      expect(session["key"]).to eq("value")
    end
  end

  describe "#delete" do
    it "removes a key" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      session.delete("key")
      expect(session["key"]).to be_nil
    end
  end

  describe "#clear" do
    it "clears all data" do
      session = Tina4::Session.new(env, options)
      session["a"] = 1
      session["b"] = 2
      session.clear
      expect(session.to_hash).to eq({})
    end
  end

  describe "#save" do
    it "persists session data" do
      session = Tina4::Session.new(env, options)
      session["name"] = "Bob"
      session.save

      s2 = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{session.id}" }, options)
      expect(s2["name"]).to eq("Bob")
    end
  end

  describe "#destroy" do
    it "destroys session data" do
      session = Tina4::Session.new(env, options)
      session["name"] = "Bob"
      session.save
      session.destroy
      expect(session.to_hash).to eq({})
    end
  end

  describe "#cookie_header" do
    it "returns a valid Set-Cookie string" do
      session = Tina4::Session.new(env, options)
      header = session.cookie_header
      expect(header).to include("tina4_session=")
      expect(header).to include("HttpOnly")
      expect(header).to include("Path=/")
    end
  end

  describe "#to_hash" do
    it "returns a copy of session data" do
      session = Tina4::Session.new(env, options)
      session["x"] = 1
      hash = session.to_hash
      expect(hash).to eq({ "x" => 1 })
    end
  end
end

RSpec.describe Tina4::LazySession do
  let(:tmp_dir) { Dir.mktmpdir("tina4_lazy_sess_test") }
  let(:env) { { "HTTP_COOKIE" => "" } }
  let(:options) { { handler: :file, handler_options: { dir: tmp_dir } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it "lazy-loads session on first access" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["test"] = "value"
    expect(lazy["test"]).to eq("value")
  end
end
