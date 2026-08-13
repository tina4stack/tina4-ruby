# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::SQLTranslator do
  # SQLTRANS-DEC-01/02/03. limit_to_rows / limit_to_top / placeholder_style and
  # the duplicate query_key were REMOVED (the drivers own pagination/placeholders,
  # and QueryCache.query_key is the live cache key) - see the design note in
  # lib/tina4/sql_translator.rb. concat/bool/ilike are now literal-safe.

  describe ".concat_pipes_to_func" do
    it "converts a bare || chain to CONCAT()" do
      expect(Tina4::SQLTranslator.concat_pipes_to_func("'hello' || ' ' || 'world'"))
        .to eq("CONCAT('hello', ' ', 'world')")
    end

    it "rewrites only the operand chain in a full statement (no whole-statement split)" do
      sql = "SELECT first_name || ' ' || last_name AS fullname FROM users WHERE id = ?"
      expect(Tina4::SQLTranslator.concat_pipes_to_func(sql))
        .to eq("SELECT CONCAT(first_name, ' ', last_name) AS fullname FROM users WHERE id = ?")
    end

    it "leaves a || that is INSIDE a string literal untouched" do
      sql = "SELECT id FROM t WHERE data = 'a||b'"
      expect(Tina4::SQLTranslator.concat_pipes_to_func(sql)).to eq(sql)
    end

    it "rewrites a real || while preserving a || inside a literal" do
      sql = "SELECT a || b FROM t WHERE note = 'x||y'"
      expect(Tina4::SQLTranslator.concat_pipes_to_func(sql))
        .to eq("SELECT CONCAT(a, b) FROM t WHERE note = 'x||y'")
    end

    it "leaves SQL without || unchanged" do
      expect(Tina4::SQLTranslator.concat_pipes_to_func("SELECT * FROM users"))
        .to eq("SELECT * FROM users")
    end
  end

  describe ".boolean_to_int" do
    it "converts bare TRUE/FALSE to 1/0" do
      expect(Tina4::SQLTranslator.boolean_to_int("SELECT * FROM users WHERE active = TRUE AND deleted = FALSE"))
        .to eq("SELECT * FROM users WHERE active = 1 AND deleted = 0")
    end

    it "is case-insensitive" do
      expect(Tina4::SQLTranslator.boolean_to_int("SELECT * FROM users WHERE active = true"))
        .to eq("SELECT * FROM users WHERE active = 1")
    end

    it "leaves a TRUE/FALSE that is INSIDE a string literal untouched" do
      sql = "SELECT id FROM t WHERE label = 'TRUE' AND active = TRUE"
      expect(Tina4::SQLTranslator.boolean_to_int(sql))
        .to eq("SELECT id FROM t WHERE label = 'TRUE' AND active = 1")
    end
  end

  describe ".ilike_to_like" do
    it "converts ILIKE to LOWER() LIKE LOWER()" do
      expect(Tina4::SQLTranslator.ilike_to_like("name ILIKE '%john%'"))
        .to eq("LOWER(name) LIKE LOWER('%john%')")
    end

    it "is case-insensitive" do
      expect(Tina4::SQLTranslator.ilike_to_like("name ilike '%test%'"))
        .to eq("LOWER(name) LIKE LOWER('%test%')")
    end

    it "captures a multi-word pattern WHOLE (no greedy truncation)" do
      sql = "SELECT id FROM t WHERE bio ILIKE '%two words%'"
      expect(Tina4::SQLTranslator.ilike_to_like(sql))
        .to eq("SELECT id FROM t WHERE LOWER(bio) LIKE LOWER('%two words%')")
    end

    it "leaves an ILIKE that is INSIDE a string literal untouched" do
      sql = "SELECT id FROM t WHERE note = 'do it ILIKE this'"
      expect(Tina4::SQLTranslator.ilike_to_like(sql)).to eq(sql)
    end
  end

  describe ".auto_increment_syntax" do
    it "converts AUTOINCREMENT to AUTO_INCREMENT for MySQL" do
      result = Tina4::SQLTranslator.auto_increment_syntax("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)", "mysql")
      expect(result).to include("AUTO_INCREMENT")
    end

    it "converts INTEGER PRIMARY KEY AUTOINCREMENT to SERIAL for PostgreSQL" do
      result = Tina4::SQLTranslator.auto_increment_syntax("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)", "postgresql")
      expect(result).to include("SERIAL PRIMARY KEY")
    end

    it "converts BIGINT PRIMARY KEY AUTOINCREMENT to BIGSERIAL for PostgreSQL" do
      result = Tina4::SQLTranslator.auto_increment_syntax("CREATE TABLE t (id BIGINT PRIMARY KEY AUTOINCREMENT, name VARCHAR(50))", "postgresql")
      expect(result).to eq("CREATE TABLE t (id BIGSERIAL PRIMARY KEY, name VARCHAR(50))")
    end

    it "preserves BIGINT for MySQL (BIGINT ... AUTO_INCREMENT)" do
      result = Tina4::SQLTranslator.auto_increment_syntax("CREATE TABLE t (id BIGINT PRIMARY KEY AUTOINCREMENT)", "mysql")
      expect(result).to eq("CREATE TABLE t (id BIGINT PRIMARY KEY AUTO_INCREMENT)")
    end

    it "converts to IDENTITY(1,1) for MSSQL" do
      result = Tina4::SQLTranslator.auto_increment_syntax("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)", "mssql")
      expect(result).to include("IDENTITY(1,1)")
    end

    it "removes AUTOINCREMENT for Firebird" do
      result = Tina4::SQLTranslator.auto_increment_syntax("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)", "firebird")
      expect(result).not_to include("AUTOINCREMENT")
    end

    it "leaves SQL unchanged for SQLite (default)" do
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)"
      expect(Tina4::SQLTranslator.auto_increment_syntax(sql, "sqlite")).to eq(sql)
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
