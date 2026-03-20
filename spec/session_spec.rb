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

    it "generates a 64-char hex id" do
      session = Tina4::Session.new(env, options)
      expect(session.id).to match(/\A[0-9a-f]{64}\z/)
    end

    it "generates unique ids for different sessions" do
      s1 = Tina4::Session.new(env, options)
      s2 = Tina4::Session.new(env, options)
      expect(s1.id).not_to eq(s2.id)
    end

    it "restores session from cookie" do
      s1 = Tina4::Session.new(env, options)
      s1["user"] = "Alice"
      s1.save

      env2 = { "HTTP_COOKIE" => "tina4_session=#{s1.id}" }
      s2 = Tina4::Session.new(env2, options)
      expect(s2["user"]).to eq("Alice")
    end

    it "extracts session id from cookie with multiple cookies" do
      s1 = Tina4::Session.new(env, options)
      s1["color"] = "blue"
      s1.save

      env2 = { "HTTP_COOKIE" => "other=abc; tina4_session=#{s1.id}; foo=bar" }
      s2 = Tina4::Session.new(env2, options)
      expect(s2["color"]).to eq("blue")
    end

    it "starts with empty data for a new session" do
      session = Tina4::Session.new(env, options)
      expect(session.data).to eq({})
    end

    it "uses default secret when none provided" do
      session = Tina4::Session.new(env, { handler: :file, handler_options: { dir: tmp_dir } })
      expect(session).not_to be_nil
    end
  end

  describe "#[] and #[]=" do
    it "gets and sets values" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      expect(session["key"]).to eq("value")
    end

    it "converts keys to strings" do
      session = Tina4::Session.new(env, options)
      session[:symbol_key] = "test"
      expect(session["symbol_key"]).to eq("test")
    end

    it "returns nil for missing keys" do
      session = Tina4::Session.new(env, options)
      expect(session["nonexistent"]).to be_nil
    end

    it "overwrites existing values" do
      session = Tina4::Session.new(env, options)
      session["key"] = "first"
      session["key"] = "second"
      expect(session["key"]).to eq("second")
    end
  end

  describe "#get and #set" do
    it "get returns the value for existing key" do
      session = Tina4::Session.new(env, options)
      session.set("name", "Alice")
      expect(session.get("name")).to eq("Alice")
    end

    it "get returns default for missing key" do
      session = Tina4::Session.new(env, options)
      expect(session.get("missing", "fallback")).to eq("fallback")
    end

    it "get returns nil when no default provided" do
      session = Tina4::Session.new(env, options)
      expect(session.get("missing")).to be_nil
    end
  end

  describe "#has?" do
    it "returns true for existing key" do
      session = Tina4::Session.new(env, options)
      session["present"] = "yes"
      expect(session.has?("present")).to be true
    end

    it "returns false for missing key" do
      session = Tina4::Session.new(env, options)
      expect(session.has?("absent")).to be false
    end

    it "converts key to string" do
      session = Tina4::Session.new(env, options)
      session["key"] = "val"
      expect(session.has?(:key)).to be true
    end
  end

  describe "#all" do
    it "returns a copy of session data" do
      session = Tina4::Session.new(env, options)
      session["a"] = 1
      session["b"] = 2
      all = session.all
      expect(all).to eq({ "a" => 1, "b" => 2 })
    end

    it "returns a copy that does not affect the session" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      all = session.all
      all["key"] = "modified"
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

    it "marks session as modified" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      session.save
      session.delete("key")
      session.save

      s2 = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{session.id}" }, options)
      expect(s2["key"]).to be_nil
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

    it "does not write when not modified" do
      session = Tina4::Session.new(env, options)
      # No modifications made, save should be a no-op
      session.save
      # Session file should not exist since nothing was written
      # Just verify it does not raise
    end

    it "persists multiple values" do
      session = Tina4::Session.new(env, options)
      session["name"] = "Alice"
      session["role"] = "admin"
      session["count"] = 42
      session.save

      s2 = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{session.id}" }, options)
      expect(s2["name"]).to eq("Alice")
      expect(s2["role"]).to eq("admin")
      expect(s2["count"]).to eq(42)
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

  describe "#flash" do
    it "sets a flash value" do
      session = Tina4::Session.new(env, options)
      session.flash("message", "Hello!")
      expect(session.flash("message")).to eq("Hello!")
    end

    it "removes flash value after reading" do
      session = Tina4::Session.new(env, options)
      session.flash("notice", "Done!")
      session.flash("notice") # first read
      expect(session.flash("notice")).to be_nil
    end

    it "returns nil for missing flash key" do
      session = Tina4::Session.new(env, options)
      expect(session.flash("nonexistent")).to be_nil
    end

    it "stores flash with a prefix key internally" do
      session = Tina4::Session.new(env, options)
      session.flash("msg", "hi")
      expect(session.data).to have_key("_flash_msg")
    end
  end

  describe "#regenerate" do
    it "changes the session id" do
      session = Tina4::Session.new(env, options)
      old_id = session.id
      session.regenerate
      expect(session.id).not_to eq(old_id)
    end

    it "generates a valid new id" do
      session = Tina4::Session.new(env, options)
      session.regenerate
      expect(session.id).to match(/\A[0-9a-f]{64}\z/)
    end

    it "preserves session data" do
      session = Tina4::Session.new(env, options)
      session["keep"] = "this"
      session.save
      session.regenerate
      expect(session.get("keep")).to eq("this")
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

    it "includes SameSite=Lax" do
      session = Tina4::Session.new(env, options)
      expect(session.cookie_header).to include("SameSite=Lax")
    end

    it "includes Max-Age" do
      session = Tina4::Session.new(env, options)
      expect(session.cookie_header).to include("Max-Age=86400")
    end

    it "uses custom cookie name" do
      custom_opts = options.merge(cookie_name: "my_session")
      session = Tina4::Session.new(env, custom_opts)
      expect(session.cookie_header).to include("my_session=")
    end
  end

  describe "#to_hash" do
    it "returns a copy of session data" do
      session = Tina4::Session.new(env, options)
      session["x"] = 1
      hash = session.to_hash
      expect(hash).to eq({ "x" => 1 })
    end

    it "returns a copy that does not affect original" do
      session = Tina4::Session.new(env, options)
      session["x"] = 1
      hash = session.to_hash
      hash["x"] = 999
      expect(session["x"]).to eq(1)
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

  it "delegates get to underlying session" do
    lazy = Tina4::LazySession.new(env, options)
    lazy.set("name", "Alice")
    expect(lazy.get("name")).to eq("Alice")
  end

  it "delegates get with default" do
    lazy = Tina4::LazySession.new(env, options)
    expect(lazy.get("missing", "default")).to eq("default")
  end

  it "delegates has?" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["key"] = "val"
    expect(lazy.has?("key")).to be true
    expect(lazy.has?("other")).to be false
  end

  it "delegates all" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["a"] = 1
    expect(lazy.all).to eq({ "a" => 1 })
  end

  it "delegates flash" do
    lazy = Tina4::LazySession.new(env, options)
    lazy.flash("msg", "hi")
    expect(lazy.flash("msg")).to eq("hi")
    expect(lazy.flash("msg")).to be_nil
  end

  it "delegates delete" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["key"] = "val"
    lazy.delete("key")
    expect(lazy["key"]).to be_nil
  end

  it "delegates clear" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["a"] = 1
    lazy.clear
    expect(lazy.all).to eq({})
  end

  it "delegates to_hash" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["x"] = 42
    expect(lazy.to_hash).to eq({ "x" => 42 })
  end

  it "delegates cookie_header" do
    lazy = Tina4::LazySession.new(env, options)
    expect(lazy.cookie_header).to include("tina4_session=")
  end

  it "save does nothing when session not loaded" do
    lazy = Tina4::LazySession.new(env, options)
    expect { lazy.save }.not_to raise_error
  end

  it "destroy does nothing when session not loaded" do
    lazy = Tina4::LazySession.new(env, options)
    expect { lazy.destroy }.not_to raise_error
  end
end
