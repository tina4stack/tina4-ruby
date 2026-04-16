# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Session Handlers" do
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
    it "is defined in the SessionHandlers module" do
      expect(defined?(Tina4::SessionHandlers::RedisHandler)).to eq("constant")
    end

    it "responds to the session handler interface methods" do
      instance_methods = Tina4::SessionHandlers::RedisHandler.instance_methods(false)
      expect(instance_methods).to include(:read)
      expect(instance_methods).to include(:write)
      expect(instance_methods).to include(:destroy)
      expect(instance_methods).to include(:cleanup)
    end
  end

  describe Tina4::SessionHandlers::MongoHandler do
    it "is defined in the SessionHandlers module" do
      expect(defined?(Tina4::SessionHandlers::MongoHandler)).to eq("constant")
    end

    it "responds to the session handler interface methods" do
      instance_methods = Tina4::SessionHandlers::MongoHandler.instance_methods(false)
      expect(instance_methods).to include(:read)
      expect(instance_methods).to include(:write)
      expect(instance_methods).to include(:destroy)
      expect(instance_methods).to include(:cleanup)
    end
  end

  describe Tina4::SessionHandlers::ValkeyHandler do
    it "is defined in the SessionHandlers module" do
      expect(defined?(Tina4::SessionHandlers::ValkeyHandler)).to eq("constant")
    end

    it "responds to the session handler interface methods" do
      instance_methods = Tina4::SessionHandlers::ValkeyHandler.instance_methods(false)
      expect(instance_methods).to include(:read)
      expect(instance_methods).to include(:write)
      expect(instance_methods).to include(:destroy)
      expect(instance_methods).to include(:cleanup)
    end
  end

  describe Tina4::SessionHandlers::DatabaseHandler do
    it "is defined in the SessionHandlers module" do
      expect(defined?(Tina4::SessionHandlers::DatabaseHandler)).to eq("constant")
    end

    it "responds to the session handler interface methods" do
      instance_methods = Tina4::SessionHandlers::DatabaseHandler.instance_methods(false)
      expect(instance_methods).to include(:read)
      expect(instance_methods).to include(:write)
      expect(instance_methods).to include(:destroy)
      expect(instance_methods).to include(:cleanup)
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

  describe "Session handler interface consistency" do
    let(:handlers) do
      [
        Tina4::SessionHandlers::FileHandler,
        Tina4::SessionHandlers::RedisHandler,
        Tina4::SessionHandlers::MongoHandler,
        Tina4::SessionHandlers::ValkeyHandler,
        Tina4::SessionHandlers::DatabaseHandler
      ]
    end

    it "all handlers implement read" do
      handlers.each do |handler_class|
        expect(handler_class.instance_methods(false)).to include(:read),
          "#{handler_class} missing :read"
      end
    end

    it "all handlers implement write" do
      handlers.each do |handler_class|
        expect(handler_class.instance_methods(false)).to include(:write),
          "#{handler_class} missing :write"
      end
    end

    it "all handlers implement destroy" do
      handlers.each do |handler_class|
        expect(handler_class.instance_methods(false)).to include(:destroy),
          "#{handler_class} missing :destroy"
      end
    end

    it "all handlers implement cleanup" do
      handlers.each do |handler_class|
        expect(handler_class.instance_methods(false)).to include(:cleanup),
          "#{handler_class} missing :cleanup"
      end
    end
  end
end
