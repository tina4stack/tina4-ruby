# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::SQLTranslator do
  describe ".limit_to_rows" do
    it "converts LIMIT/OFFSET to Firebird ROWS X TO Y" do
      sql = "SELECT * FROM users LIMIT 10 OFFSET 5"
      result = Tina4::SQLTranslator.limit_to_rows(sql)
      expect(result).to eq("SELECT * FROM users ROWS 6 TO 15")
    end

    it "handles LIMIT without OFFSET" do
      sql = "SELECT * FROM users LIMIT 10"
      result = Tina4::SQLTranslator.limit_to_rows(sql)
      expect(result).to eq("SELECT * FROM users ROWS 1 TO 10")
    end

    it "leaves SQL without LIMIT unchanged" do
      sql = "SELECT * FROM users WHERE id = 1"
      result = Tina4::SQLTranslator.limit_to_rows(sql)
      expect(result).to eq(sql)
    end

    it "handles LIMIT 1 OFFSET 0 correctly" do
      sql = "SELECT * FROM users LIMIT 1 OFFSET 0"
      result = Tina4::SQLTranslator.limit_to_rows(sql)
      expect(result).to eq("SELECT * FROM users ROWS 1 TO 1")
    end

    it "is case-insensitive" do
      sql = "SELECT * FROM users limit 5 offset 10"
      result = Tina4::SQLTranslator.limit_to_rows(sql)
      expect(result).to eq("SELECT * FROM users ROWS 11 TO 15")
    end
  end

  describe ".limit_to_top" do
    it "converts LIMIT to MSSQL TOP N" do
      sql = "SELECT * FROM users LIMIT 10"
      result = Tina4::SQLTranslator.limit_to_top(sql)
      expect(result).to eq("SELECT TOP 10 * FROM users")
    end

    it "leaves queries with OFFSET unchanged" do
      sql = "SELECT * FROM users LIMIT 10 OFFSET 5"
      result = Tina4::SQLTranslator.limit_to_top(sql)
      expect(result).to eq(sql)
    end

    it "leaves SQL without LIMIT unchanged" do
      sql = "SELECT * FROM users WHERE id = 1"
      result = Tina4::SQLTranslator.limit_to_top(sql)
      expect(result).to eq(sql)
    end
  end

  describe ".boolean_to_int" do
    it "converts TRUE to 1" do
      sql = "SELECT * FROM users WHERE active = TRUE"
      result = Tina4::SQLTranslator.boolean_to_int(sql)
      expect(result).to eq("SELECT * FROM users WHERE active = 1")
    end

    it "converts FALSE to 0" do
      sql = "UPDATE users SET active = FALSE WHERE id = 1"
      result = Tina4::SQLTranslator.boolean_to_int(sql)
      expect(result).to eq("UPDATE users SET active = 0 WHERE id = 1")
    end

    it "converts both TRUE and FALSE in the same query" do
      sql = "SELECT * FROM users WHERE active = TRUE AND deleted = FALSE"
      result = Tina4::SQLTranslator.boolean_to_int(sql)
      expect(result).to eq("SELECT * FROM users WHERE active = 1 AND deleted = 0")
    end

    it "is case-insensitive" do
      sql = "SELECT * FROM users WHERE active = true"
      result = Tina4::SQLTranslator.boolean_to_int(sql)
      expect(result).to eq("SELECT * FROM users WHERE active = 1")
    end
  end

  describe ".ilike_to_like" do
    it "converts ILIKE to LOWER() LIKE LOWER()" do
      sql = "name ILIKE '%john%'"
      result = Tina4::SQLTranslator.ilike_to_like(sql)
      expect(result).to eq("LOWER(name) LIKE LOWER('%john%')")
    end

    it "is case-insensitive" do
      sql = "name ilike '%test%'"
      result = Tina4::SQLTranslator.ilike_to_like(sql)
      expect(result).to eq("LOWER(name) LIKE LOWER('%test%')")
    end
  end

  describe ".concat_pipes_to_func" do
    it "converts || to CONCAT()" do
      sql = "'hello' || ' ' || 'world'"
      result = Tina4::SQLTranslator.concat_pipes_to_func(sql)
      expect(result).to eq("CONCAT('hello', ' ', 'world')")
    end

    it "leaves SQL without || unchanged" do
      sql = "SELECT * FROM users"
      result = Tina4::SQLTranslator.concat_pipes_to_func(sql)
      expect(result).to eq(sql)
    end
  end

  describe ".placeholder_style" do
    it "converts ? to %s" do
      sql = "SELECT * FROM users WHERE id = ? AND name = ?"
      result = Tina4::SQLTranslator.placeholder_style(sql, "%s")
      expect(result).to eq("SELECT * FROM users WHERE id = %s AND name = %s")
    end

    it "converts ? to numbered placeholders :1, :2" do
      sql = "SELECT * FROM users WHERE id = ? AND name = ?"
      result = Tina4::SQLTranslator.placeholder_style(sql, ":")
      expect(result).to eq("SELECT * FROM users WHERE id = :1 AND name = :2")
    end

    it "returns original SQL for unknown style" do
      sql = "SELECT * FROM users WHERE id = ?"
      result = Tina4::SQLTranslator.placeholder_style(sql, "unknown")
      expect(result).to eq(sql)
    end
  end

  describe ".auto_increment_syntax" do
    it "converts AUTOINCREMENT to AUTO_INCREMENT for MySQL" do
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)"
      result = Tina4::SQLTranslator.auto_increment_syntax(sql, "mysql")
      expect(result).to include("AUTO_INCREMENT")
    end

    it "converts to SERIAL PRIMARY KEY for PostgreSQL" do
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)"
      result = Tina4::SQLTranslator.auto_increment_syntax(sql, "postgresql")
      expect(result).to include("SERIAL PRIMARY KEY")
    end

    it "converts to IDENTITY(1,1) for MSSQL" do
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)"
      result = Tina4::SQLTranslator.auto_increment_syntax(sql, "mssql")
      expect(result).to include("IDENTITY(1,1)")
    end

    it "removes AUTOINCREMENT for Firebird" do
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)"
      result = Tina4::SQLTranslator.auto_increment_syntax(sql, "firebird")
      expect(result).not_to include("AUTOINCREMENT")
    end

    it "leaves SQL unchanged for SQLite (default)" do
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)"
      result = Tina4::SQLTranslator.auto_increment_syntax(sql, "sqlite")
      expect(result).to eq(sql)
    end
  end

  describe ".query_key" do
    it "returns a string starting with 'query:'" do
      key = Tina4::SQLTranslator.query_key("SELECT 1")
      expect(key).to start_with("query:")
    end

    it "produces different keys for different SQL" do
      key1 = Tina4::SQLTranslator.query_key("SELECT 1")
      key2 = Tina4::SQLTranslator.query_key("SELECT 2")
      expect(key1).not_to eq(key2)
    end

    it "produces different keys when params differ" do
      key1 = Tina4::SQLTranslator.query_key("SELECT ?", [1])
      key2 = Tina4::SQLTranslator.query_key("SELECT ?", [2])
      expect(key1).not_to eq(key2)
    end
  end
end

RSpec.describe Tina4::QueryCache do
  let(:cache) { Tina4::QueryCache.new(default_ttl: 10, max_size: 3) }

  describe "#set / #get" do
    it "stores and retrieves a value" do
      cache.set("key1", "value1")
      expect(cache.get("key1")).to eq("value1")
    end

    it "returns default when key is missing" do
      expect(cache.get("missing")).to be_nil
      expect(cache.get("missing", "fallback")).to eq("fallback")
    end
  end

  describe "TTL expiry" do
    it "expires entries after TTL" do
      cache.set("key1", "value1", ttl: 0)
      # TTL of 0 means it expires immediately
      sleep(0.01)
      expect(cache.get("key1")).to be_nil
    end

    it "returns value before TTL expires" do
      cache.set("key1", "value1", ttl: 60)
      expect(cache.get("key1")).to eq("value1")
    end
  end

  describe "eviction at max_size" do
    it "evicts oldest entry when capacity is reached" do
      cache.set("a", 1)
      cache.set("b", 2)
      cache.set("c", 3)
      cache.set("d", 4) # Should evict "a"
      expect(cache.get("a")).to be_nil
      expect(cache.get("d")).to eq(4)
      expect(cache.size).to eq(3)
    end
  end

  describe "#sweep" do
    it "removes expired entries" do
      cache.set("expired", "old", ttl: 0)
      cache.set("fresh", "new", ttl: 60)
      sleep(0.01)
      removed = cache.sweep
      expect(removed).to eq(1)
      expect(cache.get("fresh")).to eq("new")
      expect(cache.get("expired")).to be_nil
    end
  end

  describe "#remember" do
    it "caches block results" do
      call_count = 0
      result1 = cache.remember("key", 60) { call_count += 1; "computed" }
      result2 = cache.remember("key", 60) { call_count += 1; "recomputed" }
      expect(result1).to eq("computed")
      expect(result2).to eq("computed")
      expect(call_count).to eq(1)
    end

    it "recomputes when expired" do
      call_count = 0
      cache.remember("key", 0) { call_count += 1; "first" }
      sleep(0.01)
      cache.remember("key", 60) { call_count += 1; "second" }
      expect(call_count).to eq(2)
    end
  end

  describe "#clear_tag (tag-based invalidation)" do
    it "clears entries with a specific tag" do
      cache.set("user:1", "data1", tags: ["users"])
      cache.set("user:2", "data2", tags: ["users"])
      cache.set("post:1", "data3", tags: ["posts"])
      removed = cache.clear_tag("users")
      expect(removed).to eq(2)
      expect(cache.get("user:1")).to be_nil
      expect(cache.get("user:2")).to be_nil
      expect(cache.get("post:1")).to eq("data3")
    end
  end

  describe "#has?" do
    it "returns true for existing, non-expired keys" do
      cache.set("key", "value", ttl: 60)
      expect(cache.has?("key")).to be true
    end

    it "returns false for missing keys" do
      expect(cache.has?("missing")).to be false
    end

    it "returns false for expired keys" do
      cache.set("key", "value", ttl: 0)
      sleep(0.01)
      expect(cache.has?("key")).to be false
    end
  end

  describe "#delete" do
    it "removes a key" do
      cache.set("key", "value")
      expect(cache.delete("key")).to be true
      expect(cache.get("key")).to be_nil
    end

    it "returns false for missing keys" do
      expect(cache.delete("missing")).to be false
    end
  end

  describe "#clear" do
    it "removes all entries" do
      cache.set("a", 1)
      cache.set("b", 2)
      cache.clear
      expect(cache.size).to eq(0)
    end
  end
end
