# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe "Session Handlers" do
  # Skip a live-service example (with a gate-recognised reason) when the real
  # backend is not reachable. CI provisions redis/valkey/mongo and sets
  # TINA4_REQUIRE_SERVICES, which turns these skips into hard failures (see
  # spec_helper.rb) so a real-service spec can never silently no-op.
  def self.service_reachable?(host, port)
    s = Socket.tcp(host, port, connect_timeout: 1)
    s.close
    true
  rescue StandardError
    false
  end

  # The Redis and Valkey handlers no longer need the optional `redis` gem: they
  # prefer it when installed but fall back to a zero-dependency raw RESP client
  # (RespClient) otherwise, so a real round-trip runs whether or not the gem is
  # present. The only gate left is reachability — a provisioned service that is
  # unreachable becomes a hard failure under TINA4_REQUIRE_SERVICES.

  REDIS_HOST  = ENV.fetch("TINA4_REDIS_HOST", "localhost")
  REDIS_PORT  = ENV.fetch("TINA4_REDIS_PORT", "6379").to_i
  VALKEY_HOST = ENV.fetch("TINA4_SESSION_VALKEY_HOST", "localhost")
  VALKEY_PORT = ENV.fetch("TINA4_SESSION_VALKEY_PORT", "6380").to_i
  MONGO_URI   = ENV.fetch("TINA4_MONGO_URI", "mongodb://localhost:27017")
  MONGO_HOST  = MONGO_URI[%r{//([^:/]+)}, 1] || "localhost"
  MONGO_PORT  = (MONGO_URI[%r{//[^:/]+:(\d+)}, 1] || "27017").to_i

  describe Tina4::SessionHandlers::FileHandler do
    let(:tmpdir) { Dir.mktmpdir }
    let(:handler) { Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600) }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "creates the session directory on initialization" do
      expect(Dir.exist?(tmpdir)).to be true
    end

    it "writes and reads session data" do
      handler.write("session1", { "user" => "Alice", "role" => "admin" })
      data = handler.read("session1")
      expect(data).to eq({ "user" => "Alice", "role" => "admin" })
    end

    it "returns nil for non-existent session" do
      data = handler.read("nonexistent")
      expect(data).to be_nil
    end

    it "overwrites existing session data" do
      handler.write("session1", { "count" => 1 })
      handler.write("session1", { "count" => 2 })
      data = handler.read("session1")
      expect(data).to eq({ "count" => 2 })
    end

    it "destroys a session" do
      handler.write("session1", { "data" => "value" })
      handler.destroy("session1")
      expect(handler.read("session1")).to be_nil
    end

    it "does not raise when destroying non-existent session" do
      expect { handler.destroy("nonexistent") }.not_to raise_error
    end

    it "returns nil for expired session" do
      # Create handler with very short TTL
      short_handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 0)
      short_handler.write("expired", { "data" => "old" })
      sleep(0.1)
      expect(short_handler.read("expired")).to be_nil
    end

    it "deletes expired session file on read" do
      short_handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 0)
      short_handler.write("expired", { "data" => "old" })
      sleep(0.1)
      short_handler.read("expired")
      # File should be deleted
      files = Dir.glob(File.join(tmpdir, "sess_expired.json"))
      expect(files).to be_empty
    end

    it "sanitizes session id to prevent path traversal" do
      handler.write("../../../etc/passwd", { "hack" => true })
      # Should write to a safe path, not traverse directories
      files = Dir.glob(File.join(tmpdir, "sess_*.json"))
      expect(files.length).to eq(1)
      expect(files.first).to start_with(tmpdir)
    end

    it "stores data as JSON" do
      handler.write("json_test", { "nested" => { "key" => "value" }, "array" => [1, 2, 3] })
      data = handler.read("json_test")
      expect(data["nested"]["key"]).to eq("value")
      expect(data["array"]).to eq([1, 2, 3])
    end

    it "handles cleanup of expired files" do
      short_handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 0)
      short_handler.write("old1", { "a" => 1 })
      short_handler.write("old2", { "b" => 2 })
      sleep(0.1)
      short_handler.cleanup
      files = Dir.glob(File.join(tmpdir, "sess_*.json"))
      expect(files).to be_empty
    end

    it "cleanup does not remove unexpired files" do
      handler.write("active", { "data" => "still valid" })
      handler.cleanup
      expect(handler.read("active")).to eq({ "data" => "still valid" })
    end

    it "returns nil for corrupted JSON" do
      path = File.join(tmpdir, "sess_corrupt.json")
      File.write(path, "not valid json{{{")
      expect(handler.read("corrupt")).to be_nil
    end

    it "uses default TTL of 86400" do
      default_handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir)
      default_handler.write("test", { "key" => "val" })
      expect(default_handler.read("test")).to eq({ "key" => "val" })
    end

    it "uses default directory when none specified" do
      default_handler = Tina4::SessionHandlers::FileHandler.new
      expect(default_handler).to respond_to(:read)
      expect(default_handler).to respond_to(:write)
      expect(default_handler).to respond_to(:destroy)
      expect(default_handler).to respond_to(:cleanup)
    end
  end

  describe Tina4::SessionHandlers::RedisHandler do
    before(:each) do
      skip "redis not running" unless self.class.service_reachable?(REDIS_HOST, REDIS_PORT)
    end

    let(:handler) { Tina4::SessionHandlers::RedisHandler.new(host: REDIS_HOST, port: REDIS_PORT) }

    after(:each) { handler.destroy("sess_r") rescue nil }

    it "round-trips session data through a live Redis" do
      handler.destroy("sess_r")
      handler.write("sess_r", { "u" => "A" })
      expect(handler.read("sess_r")).to eq({ "u" => "A" })
    end

    it "exercises the full read/write/destroy interface against a live Redis" do
      handler.destroy("sess_r")
      handler.write("sess_r", { "user" => "Alice", "role" => "admin" })
      expect(handler.read("sess_r")).to eq({ "user" => "Alice", "role" => "admin" })
      handler.destroy("sess_r")
      expect(handler.read("sess_r")).to be_nil
    end
  end

  describe Tina4::SessionHandlers::MongoHandler do
    before(:each) do
      skip "mongo not running" unless self.class.service_reachable?(MONGO_HOST, MONGO_PORT)
    end

    let(:handler) do
      Tina4::SessionHandlers::MongoHandler.new(
        uri: MONGO_URI,
        database: "tina4_sessions_spec",
        collection: "session_handlers_spec"
      )
    end

    after(:each) { handler.destroy("sess_m") rescue nil }

    it "round-trips a session hash through a live Mongo" do
      handler.destroy("sess_m")
      handler.write("sess_m", { "u" => "A", "n" => 1 })
      # MongoHandler#read returns the stored document; compares equal to the
      # plain hash that was written.
      expect(handler.read("sess_m")).to eq({ "u" => "A", "n" => 1 })
    end

    it "exercises the full write/read/destroy/cleanup cycle against a live Mongo" do
      handler.destroy("sess_m")
      handler.write("sess_m", { "user" => "Alice", "role" => "admin", "visits" => 3 })
      expect(handler.read("sess_m")).to eq({ "user" => "Alice", "role" => "admin", "visits" => 3 })
      # cleanup is a no-op (the Mongo server-side TTL index reaps expired docs),
      # so it must run without error and leave a live session intact.
      expect { handler.cleanup }.not_to raise_error
      expect(handler.read("sess_m")).to eq({ "user" => "Alice", "role" => "admin", "visits" => 3 })
      handler.destroy("sess_m")
      expect(handler.read("sess_m")).to be_nil
    end
  end

  describe Tina4::SessionHandlers::ValkeyHandler do
    before(:each) do
      skip "valkey not running" unless self.class.service_reachable?(VALKEY_HOST, VALKEY_PORT)
    end

    let(:handler) { Tina4::SessionHandlers::ValkeyHandler.new(host: VALKEY_HOST, port: VALKEY_PORT) }

    after(:each) { handler.destroy("sess_v") rescue nil }

    it "round-trips session data through a live Valkey" do
      handler.destroy("sess_v")
      handler.write("sess_v", { "k" => "v" })
      expect(handler.read("sess_v")).to eq({ "k" => "v" })
    end

    it "exercises the full read/write/destroy interface against a live Valkey" do
      handler.destroy("sess_v")
      handler.write("sess_v", { "k" => "v" })
      expect(handler.read("sess_v")).to eq({ "k" => "v" })
      handler.destroy("sess_v")
      expect(handler.read("sess_v")).to be_nil
    end
  end

  describe Tina4::SessionHandlers::DatabaseHandler do
    let(:tmp_dir) { Dir.mktmpdir("tina4_db_session_iface") }
    let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "iface.db")) }
    let(:handler) { Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600) }

    after(:each) do
      db.close rescue nil
      FileUtils.rm_rf(tmp_dir)
    end

    it "round-trips session data through a real SQLite database" do
      handler.write("sess_db", { "u" => "A" })
      expect(handler.read("sess_db")).to eq({ "u" => "A" })
    end

    it "exercises the full write/read/destroy interface against a real SQLite database" do
      handler.write("sess_db", { "user_id" => 42, "role" => "admin" })
      expect(handler.read("sess_db")).to eq({ "user_id" => 42, "role" => "admin" })
      handler.destroy("sess_db")
      expect(handler.read("sess_db")).to be_nil
    end
  end

  describe "Session create_handler supports :database and :db symbols" do
    it "maps :database to DatabaseHandler in the create_handler switch" do
      session_source = File.read(File.expand_path("../lib/tina4/session.rb", __dir__))
      expect(session_source).to include("when :database, :db")
      expect(session_source).to include("SessionHandlers::DatabaseHandler")
    end
  end

  # ── DatabaseHandler Functional Tests ────────────────────────────

  describe Tina4::SessionHandlers::DatabaseHandler do
    let(:tmp_dir) { Dir.mktmpdir("tina4_db_session") }
    let(:db_path) { File.join(tmp_dir, "session.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

    after(:each) do
      db.close rescue nil
      FileUtils.rm_rf(tmp_dir)
    end

    it "writes and reads session data" do
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600)
      handler.write("db_sess_1", { "user_id" => 42, "role" => "admin" })
      data = handler.read("db_sess_1")
      expect(data).to eq({ "user_id" => 42, "role" => "admin" })
    end

    it "returns nil for non-existent session" do
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600)
      expect(handler.read("nonexistent_db_sess")).to be_nil
    end

    it "destroys a session" do
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600)
      handler.write("db_sess_2", { "data" => "value" })
      handler.destroy("db_sess_2")
      expect(handler.read("db_sess_2")).to be_nil
    end

    it "returns nil for expired session" do
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 1)
      handler.write("db_expired", { "data" => "old" })
      sleep(1.2)
      expect(handler.read("db_expired")).to be_nil
    end

    it "cleans up expired sessions via garbage collection" do
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 1)
      handler.write("gc_1", { "a" => 1 })
      handler.write("gc_2", { "b" => 2 })
      sleep(1.2)
      handler.cleanup
      expect(handler.read("gc_1")).to be_nil
      expect(handler.read("gc_2")).to be_nil
    end

    it "does not clean up valid sessions" do
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600)
      handler.write("valid_sess", { "c" => 3 })
      handler.cleanup
      expect(handler.read("valid_sess")).to eq({ "c" => 3 })
    end
  end

  # ── FileHandler Additional Tests ──────────────────────────────

  describe "FileHandler additional TTL tests" do
    let(:tmpdir) { Dir.mktmpdir }

    after(:each) do
      FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    end

    it "renews TTL on write overwrite" do
      handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600)
      handler.write("renew_test", { "version" => 1 })
      sleep(0.1)
      handler.write("renew_test", { "version" => 2 })
      data = handler.read("renew_test")
      expect(data).to eq({ "version" => 2 })
    end

    it "handles special characters in session data" do
      handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600)
      handler.write("special", { "msg" => "hello <world> & \"friends\"" })
      data = handler.read("special")
      expect(data["msg"]).to eq("hello <world> & \"friends\"")
    end

    it "handles numeric session data" do
      handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600)
      handler.write("numeric", { "count" => 42, "price" => 19.99, "flag" => true })
      data = handler.read("numeric")
      expect(data["count"]).to eq(42)
      expect(data["price"]).to eq(19.99)
      expect(data["flag"]).to be true
    end

    it "handles empty hash as session data" do
      handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600)
      handler.write("empty_hash", {})
      data = handler.read("empty_hash")
      expect(data).to eq({})
    end

    it "does not raise on multiple destroys of the same session" do
      handler = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600)
      handler.write("multi_destroy", { "data" => "val" })
      handler.destroy("multi_destroy")
      expect { handler.destroy("multi_destroy") }.not_to raise_error
    end
  end

  describe "Session handler interface consistency (live backends)" do
    # Each example builds every handler against its REAL backend and proves the
    # interface FUNCTIONS, not merely that the method name is declared:
    #   read+write -> read returns the stored hash
    #   destroy    -> read returns nil after destroy
    #   cleanup    -> ttl-expiry removes a stored session (where the handler
    #                 actively reaps; Redis/Valkey expire server-side via setex)
    # A short-lived ttl handler is built where cleanup/expiry is under test.
    let(:tmp_dir) { Dir.mktmpdir("tina4_iface_consistency") }

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    # Build [label, handler] for every reachable backend at the given ttl.
    # Unreachable network backends are skipped via the gate-recognised reason.
    def live_handlers(ttl:)
      list = []
      list << ["FileHandler", Tina4::SessionHandlers::FileHandler.new(dir: tmp_dir, ttl: ttl)]

      sqlite_db = Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "iface_#{ttl}.db"))
      @sqlite_dbs << sqlite_db
      list << ["DatabaseHandler", Tina4::SessionHandlers::DatabaseHandler.new(db: sqlite_db, ttl: ttl)]

      if self.class.service_reachable?(REDIS_HOST, REDIS_PORT)
        list << ["RedisHandler", Tina4::SessionHandlers::RedisHandler.new(host: REDIS_HOST, port: REDIS_PORT, ttl: ttl)]
      end
      if self.class.service_reachable?(VALKEY_HOST, VALKEY_PORT)
        list << ["ValkeyHandler", Tina4::SessionHandlers::ValkeyHandler.new(host: VALKEY_HOST, port: VALKEY_PORT, ttl: ttl)]
      end
      if self.class.service_reachable?(MONGO_HOST, MONGO_PORT)
        list << ["MongoHandler", Tina4::SessionHandlers::MongoHandler.new(
          uri: MONGO_URI, database: "tina4_sessions_spec", collection: "iface_consistency", ttl: ttl
        )]
      end
      list
    end

    before(:each) { @sqlite_dbs = [] }
    after(:each)  { @sqlite_dbs.each { |d| d.close rescue nil } }

    it "all handlers implement write+read (read returns the written hash)" do
      payload = { "user" => "Alice", "role" => "admin" }
      live_handlers(ttl: 3600).each do |label, h|
        h.destroy("iface_rw") rescue nil
        h.write("iface_rw", payload)
        expect(h.read("iface_rw")).to eq(payload), "#{label}: read did not return the written hash"
        h.destroy("iface_rw") rescue nil
      end
    end

    it "all handlers implement write (persisted data reads back identically)" do
      payload = { "nested" => { "k" => "v" }, "arr" => [1, 2, 3], "n" => 7 }
      live_handlers(ttl: 3600).each do |label, h|
        h.destroy("iface_w") rescue nil
        h.write("iface_w", payload)
        expect(h.read("iface_w")).to eq(payload), "#{label}: write did not persist the hash"
        h.destroy("iface_w") rescue nil
      end
    end

    it "all handlers implement destroy (read returns nil after destroy)" do
      live_handlers(ttl: 3600).each do |label, h|
        h.write("iface_d", { "data" => "value" })
        h.destroy("iface_d")
        expect(h.read("iface_d")).to be_nil, "#{label}: destroy did not remove the session"
      end
    end

    it "all handlers implement cleanup (ttl expiry removes a stored session)" do
      handlers = live_handlers(ttl: 1)
      handlers.each do |_label, h|
        h.destroy("iface_c1") rescue nil
        h.destroy("iface_c2") rescue nil
        h.write("iface_c1", { "a" => 1 })
        h.write("iface_c2", { "b" => 2 })
      end
      sleep(1.3)
      handlers.each do |label, h|
        h.cleanup
        if label == "MongoHandler"
          # MongoHandler#cleanup is a no-op (the server-side TTL index reaps
          # expired docs on its own ~60s monitor cycle, which cannot be awaited
          # in a unit test). Prove the interface still works: cleanup runs
          # without error and destroy removes the records.
          h.destroy("iface_c1")
          h.destroy("iface_c2")
          expect(h.read("iface_c1")).to be_nil, "#{label}: destroy after cleanup failed"
          expect(h.read("iface_c2")).to be_nil, "#{label}: destroy after cleanup failed"
        else
          # File / Database actively delete on cleanup; Redis / Valkey expire
          # server-side via setex once the ttl elapses.
          expect(h.read("iface_c1")).to be_nil, "#{label}: expired session survived cleanup"
          expect(h.read("iface_c2")).to be_nil, "#{label}: expired session survived cleanup"
        end
      end
    end
  end
end
