# frozen_string_literal: true

require "spec_helper"

# Define a fake Redis class and register it so `require "redis"` succeeds
# without needing the real gem installed.
unless defined?(::Redis)
  class Redis
    attr_reader :config

    def initialize(**kwargs)
      @config = kwargs
      @store = {}
      @ttls = {}
    end

    def get(key)
      @store[key]
    end

    def setex(key, ttl, value)
      @store[key] = value
      @ttls[key] = ttl
    end

    def del(key)
      @store.delete(key)
    end
  end

  # Register so `require "redis"` is a no-op (already loaded)
  $LOADED_FEATURES << "redis.rb"
end

RSpec.describe Tina4::SessionHandlers::ValkeyHandler do
  before(:each) do
    # Clear relevant env vars
    @saved_env = {}
    %w[TINA4_SESSION_VALKEY_PREFIX TINA4_SESSION_VALKEY_TTL
       TINA4_SESSION_VALKEY_HOST TINA4_SESSION_VALKEY_PORT
       TINA4_SESSION_VALKEY_DB TINA4_SESSION_VALKEY_PASSWORD].each do |key|
      @saved_env[key] = ENV[key]
      ENV.delete(key)
    end
  end

  after(:each) do
    @saved_env.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end

  describe "instantiation" do
    it "can be instantiated with default config" do
      handler = Tina4::SessionHandlers::ValkeyHandler.new
      expect(handler).to be_a(Tina4::SessionHandlers::ValkeyHandler)
    end

    it "can be instantiated with custom config" do
      handler = Tina4::SessionHandlers::ValkeyHandler.new(
        host: "redis.example.com",
        port: 6380,
        db: 2,
        prefix: "myapp:sess:",
        ttl: 3600,
        password: "secret"
      )
      expect(handler).to be_a(Tina4::SessionHandlers::ValkeyHandler)
    end
  end

  describe "default config values" do
    it "uses sensible defaults" do
      handler = Tina4::SessionHandlers::ValkeyHandler.new
      redis = handler.instance_variable_get(:@redis)
      prefix = handler.instance_variable_get(:@prefix)
      ttl = handler.instance_variable_get(:@ttl)

      expect(prefix).to eq("tina4:session:")
      expect(ttl).to eq(86400)
      expect(redis.config[:host]).to eq("localhost")
      expect(redis.config[:port]).to eq(6379)
      expect(redis.config[:db]).to eq(0)
      expect(redis.config[:password]).to be_nil
    end
  end

  describe "environment variable config" do
    it "reads config from TINA4_SESSION_VALKEY_* env vars" do
      ENV["TINA4_SESSION_VALKEY_PREFIX"] = "test:sess:"
      ENV["TINA4_SESSION_VALKEY_TTL"] = "7200"
      ENV["TINA4_SESSION_VALKEY_HOST"] = "valkey.local"
      ENV["TINA4_SESSION_VALKEY_PORT"] = "6380"
      ENV["TINA4_SESSION_VALKEY_DB"] = "5"
      ENV["TINA4_SESSION_VALKEY_PASSWORD"] = "pass123"

      handler = Tina4::SessionHandlers::ValkeyHandler.new
      redis = handler.instance_variable_get(:@redis)
      prefix = handler.instance_variable_get(:@prefix)
      ttl = handler.instance_variable_get(:@ttl)

      expect(prefix).to eq("test:sess:")
      expect(ttl).to eq(7200)
      expect(redis.config[:host]).to eq("valkey.local")
      expect(redis.config[:port]).to eq(6380)
      expect(redis.config[:db]).to eq(5)
      expect(redis.config[:password]).to eq("pass123")
    end

    it "option params override env vars" do
      ENV["TINA4_SESSION_VALKEY_HOST"] = "env-host"
      handler = Tina4::SessionHandlers::ValkeyHandler.new(host: "option-host")
      redis = handler.instance_variable_get(:@redis)
      expect(redis.config[:host]).to eq("option-host")
    end
  end

  describe "interface methods" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "responds to read" do
      expect(handler).to respond_to(:read)
    end

    it "responds to write" do
      expect(handler).to respond_to(:write)
    end

    it "responds to destroy" do
      expect(handler).to respond_to(:destroy)
    end

    it "responds to cleanup" do
      expect(handler).to respond_to(:cleanup)
    end
  end

  describe "#read" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "returns nil when session does not exist" do
      result = handler.read("nonexistent-session")
      expect(result).to be_nil
    end

    it "returns parsed JSON data for existing session" do
      redis = handler.instance_variable_get(:@redis)
      redis.setex("tina4:session:abc123", 86400, '{"user_id":42,"role":"admin"}')
      result = handler.read("abc123")
      expect(result).to eq({ "user_id" => 42, "role" => "admin" })
    end

    it "returns nil for invalid JSON" do
      redis = handler.instance_variable_get(:@redis)
      redis.setex("tina4:session:bad", 86400, "not valid json{{{")
      result = handler.read("bad")
      expect(result).to be_nil
    end
  end

  describe "#write" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "writes session data as JSON" do
      handler.write("sess123", { "user" => "test" })
      redis = handler.instance_variable_get(:@redis)
      stored = redis.get("tina4:session:sess123")
      expect(JSON.parse(stored)).to eq({ "user" => "test" })
    end
  end

  describe "#destroy" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "removes session data" do
      handler.write("sess123", { "user" => "test" })
      handler.destroy("sess123")
      expect(handler.read("sess123")).to be_nil
    end
  end

  describe "#cleanup" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "does not raise (Valkey handles TTL automatically)" do
      expect { handler.cleanup }.not_to raise_error
    end
  end
end
