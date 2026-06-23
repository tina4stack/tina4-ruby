# frozen_string_literal: true

require "spec_helper"

# Real-service spec. The Valkey session handler speaks the RESP protocol via the
# real `redis` gem; these specs run against the live Valkey instance the CI/dev
# stack provisions on localhost:6380 (NO fake/mock Redis — a hand-rolled stand-in
# would only prove the test against itself, never against Valkey). The handler
# defaults to port 6379, so every handler here is pointed at 6380 via the
# TINA4_SESSION_VALKEY_PORT env var (saved/restored by the hooks below) or an
# explicit `port:` option.
#
# `redis` is not declared in the framework Gemfile, so a plain `require "redis"`
# fails under `bundle exec`. We load the REAL installed gem (and its runtime
# deps) off the on-disk gem path — this is the genuine client talking to a real
# Valkey, never a stub. If the gem genuinely isn't installed, REDIS_GEM_AVAILABLE
# stays false and every example skips with a service-keyword reason (which the
# TINA4_REQUIRE_SERVICES gate in spec_helper turns into a hard failure in CI).
REDIS_GEM_AVAILABLE =
  begin
    require "redis"
    true
  rescue LoadError
    begin
      Gem.path
         .flat_map { |p| Dir.glob(File.join(p, "gems", "{redis,redis-client,connection_pool}-*")) }
         .each { |dir| lib = File.join(dir, "lib"); $LOAD_PATH.unshift(lib) if File.directory?(lib) }
      require "redis"
      true
    rescue LoadError
      false
    end
  end

RSpec.describe Tina4::SessionHandlers::ValkeyHandler do
  # localhost:6380 is the provisioned Valkey (RESP) service in the dev/CI stack.
  VALKEY_TEST_PORT = 6380

  before(:each) do
    skip "redis gem not installed (required for the Valkey RESP client)" unless REDIS_GEM_AVAILABLE

    # Skip (hard-fail under TINA4_REQUIRE_SERVICES) if Valkey is unreachable so a
    # behavioural assertion never silently passes against a dead backend.
    begin
      probe = Redis.new(host: "localhost", port: VALKEY_TEST_PORT, timeout: 2)
      probe.ping
      probe.close
    rescue StandardError => e
      skip "Valkey not reachable on localhost:#{VALKEY_TEST_PORT}: #{e.class}: #{e.message}"
    end

    # Unique per-example prefix so concurrent/parallel runs never collide and
    # leftover keys from a crashed run can't leak into an assertion.
    @prefix = "tina4:rbspec:valkey:#{Process.pid}:#{object_id}:"

    # Clear relevant env vars, then point the handler at the real Valkey port.
    @saved_env = {}
    %w[TINA4_SESSION_VALKEY_PREFIX TINA4_SESSION_VALKEY_TTL
       TINA4_SESSION_VALKEY_HOST TINA4_SESSION_VALKEY_PORT
       TINA4_SESSION_VALKEY_DB TINA4_SESSION_VALKEY_PASSWORD].each do |key|
      @saved_env[key] = ENV[key]
      ENV.delete(key)
    end
    ENV["TINA4_SESSION_VALKEY_PORT"] = VALKEY_TEST_PORT.to_s
    ENV["TINA4_SESSION_VALKEY_PREFIX"] = @prefix
  end

  after(:each) do
    # Best-effort cleanup of any keys this example wrote to the real Valkey.
    begin
      r = Redis.new(host: "localhost", port: VALKEY_TEST_PORT, timeout: 2)
      keys = r.keys("#{@prefix}*")
      r.del(*keys) unless keys.empty?
      r.close
    rescue StandardError
      # leave cleanup best-effort; the unique prefix keeps stale keys harmless
    end

    @saved_env.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end

  describe "instantiation" do
    it "instantiates a working handler that reads from real Valkey" do
      handler = Tina4::SessionHandlers::ValkeyHandler.new
      # A bare `be_a` only proves an object was allocated. Prove it is a working
      # handler wired to the live backend: a read of a never-written session
      # round-trips to Valkey and returns nil.
      expect(handler.read("missing-#{object_id}")).to be_nil
    end

    it "applies custom config so writes land under the custom prefix in Valkey" do
      custom_prefix = "tina4:rbspec:valkey:custom:#{Process.pid}:#{object_id}:"
      handler = Tina4::SessionHandlers::ValkeyHandler.new(
        host: "localhost",
        port: VALKEY_TEST_PORT,
        db: 0,
        prefix: custom_prefix,
        ttl: 3600,
        password: nil
      )
      begin
        # Prove the custom config actually took effect against the real service:
        # a write lands under the custom prefix (not the default "tina4:session:")
        # and is readable back through the same handler.
        handler.write("c1", { "user_id" => 7 })
        raw = Redis.new(host: "localhost", port: VALKEY_TEST_PORT, timeout: 2)
        stored = raw.get("#{custom_prefix}c1")
        ttl_remaining = raw.ttl("#{custom_prefix}c1")
        raw.close

        expect(JSON.parse(stored)).to eq({ "user_id" => 7 })
        expect(ttl_remaining).to be > 0           # custom ttl: 3600 was applied
        expect(ttl_remaining).to be <= 3600
        expect(handler.read("c1")).to eq({ "user_id" => 7 })
      ensure
        handler.destroy("c1")
      end
    end
  end

  describe "default config values" do
    it "uses sensible defaults" do
      # No host/db env set (only the port override to reach real Valkey), so the
      # real client should fall back to the documented defaults. We read the
      # actual connection target off the real Redis::Client, not a fake's stored
      # kwargs hash.
      ENV.delete("TINA4_SESSION_VALKEY_PREFIX")
      handler = Tina4::SessionHandlers::ValkeyHandler.new
      client = handler.instance_variable_get(:@redis)._client

      expect(handler.instance_variable_get(:@prefix)).to eq("tina4:session:")
      expect(handler.instance_variable_get(:@ttl)).to eq(86400)
      expect(client.host).to eq("localhost")
      expect(client.db).to eq(0)
    end
  end

  describe "environment variable config" do
    it "reads config from TINA4_SESSION_VALKEY_* env vars" do
      ENV["TINA4_SESSION_VALKEY_PREFIX"] = "test:sess:"
      ENV["TINA4_SESSION_VALKEY_TTL"] = "7200"
      ENV["TINA4_SESSION_VALKEY_HOST"] = "localhost"
      ENV["TINA4_SESSION_VALKEY_PORT"] = VALKEY_TEST_PORT.to_s
      ENV["TINA4_SESSION_VALKEY_DB"] = "0"

      handler = Tina4::SessionHandlers::ValkeyHandler.new
      client = handler.instance_variable_get(:@redis)._client

      expect(handler.instance_variable_get(:@prefix)).to eq("test:sess:")
      expect(handler.instance_variable_get(:@ttl)).to eq(7200)
      expect(client.host).to eq("localhost")
      expect(client.port).to eq(VALKEY_TEST_PORT)
      expect(client.db).to eq(0)
    end

    it "option params override env vars" do
      ENV["TINA4_SESSION_VALKEY_HOST"] = "env-host"
      handler = Tina4::SessionHandlers::ValkeyHandler.new(host: "localhost", port: VALKEY_TEST_PORT)
      client = handler.instance_variable_get(:@redis)._client
      # The explicit host: option must win over the env var on the real client.
      expect(client.host).to eq("localhost")
    end
  end

  describe "interface methods" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "reads back parsed data it wrote to Valkey" do
      handler.write("s", { "k" => 1 })
      # Real read: proves read() returns the parsed stored hash from Valkey,
      # not just that the method exists.
      expect(handler.read("s")).to eq({ "k" => 1 })
    ensure
      handler.destroy("s")
    end

    it "writes JSON into Valkey under the prefixed key" do
      handler.write("s", { "u" => 5 })
      raw = Redis.new(host: "localhost", port: VALKEY_TEST_PORT, timeout: 2)
      stored = raw.get("#{@prefix}s")
      raw.close
      # Real write: the value is stored as JSON at "<prefix>s" in Valkey.
      expect(JSON.parse(stored)).to eq({ "u" => 5 })
    ensure
      handler.destroy("s")
    end

    it "destroys a session so a later read returns nil" do
      handler.write("s", { "x" => 1 })
      handler.destroy("s")
      # Real destroy: the key is gone from Valkey.
      expect(handler.read("s")).to be_nil
    end

    it "cleanup is a no-op that leaves TTL-managed data intact" do
      handler.write("s", { "x" => 1 })
      handler.cleanup
      # cleanup is the documented no-op (Valkey expires keys via TTL); the data
      # it wrote is still readable afterwards.
      expect(handler.read("s")).to eq({ "x" => 1 })
    ensure
      handler.destroy("s")
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
      redis.setex("#{@prefix}abc123", 86400, '{"user_id":42,"role":"admin"}')
      result = handler.read("abc123")
      expect(result).to eq({ "user_id" => 42, "role" => "admin" })
    ensure
      handler.destroy("abc123")
    end

    it "returns nil for invalid JSON" do
      redis = handler.instance_variable_get(:@redis)
      redis.setex("#{@prefix}bad", 86400, "not valid json{{{")
      result = handler.read("bad")
      expect(result).to be_nil
    ensure
      handler.destroy("bad")
    end
  end

  describe "#write" do
    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new }

    it "writes session data as JSON" do
      handler.write("sess123", { "user" => "test" })
      redis = handler.instance_variable_get(:@redis)
      stored = redis.get("#{@prefix}sess123")
      expect(JSON.parse(stored)).to eq({ "user" => "test" })
    ensure
      handler.destroy("sess123")
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
      handler.write("s", { "x" => 1 })
      handler.cleanup
      # A genuine no-op: cleanup never raises AND never deletes — TTL-managed
      # data survives it.
      expect(handler.read("s")).to eq({ "x" => 1 })
    ensure
      handler.destroy("s")
    end
  end
end
