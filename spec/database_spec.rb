# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Tina4::Database do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before do
    db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT, age INTEGER)")
  end

  after do
    db.close rescue nil
    FileUtils.rm_rf(tmpdir)
  end

  describe ".new" do
    it "connects to SQLite database" do
      expect(db).not_to be_nil
    end

    it "creates the database file" do
      expect(File.exist?(db_path)).to be true
    end
  end

  describe "#execute" do
    it "executes raw SQL" do
      expect { db.execute("CREATE TABLE test (id INTEGER)") }.not_to raise_error
    end

    # execute() FAILS LOUD — it raises on a SQL error (mirroring fetch/fetch_one
    # and the Python master) instead of swallowing the cause and returning false.
    # The cause stays readable through get_error after the raise.
    it "raises on a bad statement and still populates get_error" do
      expect { db.execute("INSERT INTO no_such_table (x) VALUES (1)") }.to raise_error(StandardError)
      expect(db.get_error).not_to be_nil
    end

    it "raises on a constraint violation and does NOT write the row" do
      db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
      expect { db.execute("INSERT INTO widget (id, name) VALUES (1, NULL)") }.to raise_error(StandardError)
      expect(db.fetch("SELECT * FROM widget").count).to eq(0)
    end

    it "returns truthy (never false) and clears the error on a successful write" do
      result = db.execute("INSERT INTO users (name, email, age) VALUES ('ok', 'ok@example.com', 1)")
      expect(result).not_to be false
      expect(result).not_to be_nil
      expect(db.get_error).to be_nil
      expect(db.fetch("SELECT * FROM users").count).to eq(1)
    end
  end

  describe "#insert" do
    it "inserts a record" do
      result = db.insert("users", { name: "Alice", email: "alice@example.com", age: 30 })
      expect(result).to be_truthy
    end

    it "inserts multiple records" do
      db.insert("users", { name: "Bob", email: "bob@example.com", age: 25 })
      db.insert("users", { name: "Charlie", email: "charlie@example.com", age: 35 })
      result = db.fetch("SELECT COUNT(*) as cnt FROM users")
      count = result.first["cnt"] || result.first[:cnt]
      expect(count.to_i).to eq(2)
    end
  end

  describe "#fetch" do
    before do
      db.insert("users", { name: "Alice", email: "alice@example.com", age: 30 })
      db.insert("users", { name: "Bob", email: "bob@example.com", age: 25 })
      db.insert("users", { name: "Charlie", email: "charlie@example.com", age: 35 })
    end

    it "returns a DatabaseResult" do
      result = db.fetch("SELECT * FROM users")
      expect(result).to be_a(Tina4::DatabaseResult)
    end

    it "fetches all records" do
      result = db.fetch("SELECT * FROM users")
      expect(result.count).to eq(3)
    end

    it "supports parameterized queries" do
      result = db.fetch("SELECT * FROM users WHERE age > ?", [28])
      expect(result.count).to eq(2)
    end

    it "supports limit" do
      result = db.fetch("SELECT * FROM users", [], limit: 2)
      # The limit caps the ROWS RETURNED; `count` is the TRUE TOTAL for the
      # filter, so a 2-row page of a 3-row table reports 3. This used to assert
      # count == 2 and pinned the old rows-returned meaning, which made a
      # truncated read indistinguishable from a complete one.
      expect(result.records.size).to eq(2)
      expect(result.count).to eq(3)
    end
  end

  describe "#fetch_one" do
    before do
      db.insert("users", { name: "Alice", email: "alice@example.com", age: 30 })
    end

    it "returns a single hash" do
      result = db.fetch_one("SELECT * FROM users WHERE name = ?", ["Alice"])
      expect(result).to be_a(Hash)
    end

    it "returns nil for no results" do
      result = db.fetch_one("SELECT * FROM users WHERE name = ?", ["Nobody"])
      expect(result).to be_nil
    end
  end

  describe "#update" do
    before do
      db.insert("users", { name: "Alice", email: "alice@example.com", age: 30 })
    end

    it "updates a record" do
      db.update("users", { name: "Alice Updated" }, { id: 1 })
      result = db.fetch_one("SELECT name FROM users WHERE id = ?", [1])
      name = result["name"] || result[:name]
      expect(name).to eq("Alice Updated")
    end
  end

  describe "#delete" do
    before do
      db.insert("users", { name: "Alice", email: "alice@example.com", age: 30 })
    end

    it "deletes a record" do
      db.delete("users", { id: 1 })
      result = db.fetch("SELECT * FROM users")
      expect(result.count).to eq(0)
    end
  end

  describe "#transaction" do
    it "commits on success" do
      db.transaction do |txn_db|
        txn_db.insert("users", { name: "TxnUser", email: "txn@test.com", age: 20 })
      end
      result = db.fetch_one("SELECT * FROM users WHERE name = ?", ["TxnUser"])
      expect(result).not_to be_nil
    end
  end

  describe "#tables" do
    it "lists database tables" do
      tables = db.tables
      expect(tables).to include("users")
    end
  end

  describe "#table_exists?" do
    it "returns true for existing tables" do
      expect(db.table_exists?("users")).to be true
    end

    it "returns false for non-existing tables" do
      expect(db.table_exists?("nonexistent")).to be false
    end
  end

  describe "#columns" do
    it "returns column information" do
      cols = db.columns("users")
      expect(cols).to be_an(Array)
      expect(cols.length).to be >= 4
      names = cols.map { |c| c[:name] || c["name"] }
      expect(names).to include("name")
      expect(names).to include("email")
    end
  end

  describe "#close" do
    it "closes the connection without error" do
      expect { db.close }.not_to raise_error
    end
  end

  describe "#get_next_id" do
    it "returns 1 for an empty table" do
      next_id = db.get_next_id("users")
      expect(next_id).to eq(1)
    end

    it "returns MAX(pk) + 1 when rows exist" do
      db.insert("users", { name: "Alice", email: "a@test.com", age: 30 })
      db.insert("users", { name: "Bob", email: "b@test.com", age: 25 })
      next_id = db.get_next_id("users")
      expect(next_id).to be >= 3
    end

    it "increments monotonically on successive calls" do
      ids = 5.times.map { db.get_next_id("users") }
      expect(ids).to eq(ids.sort)
      expect(ids.uniq.length).to eq(5)
    end

    it "creates the tina4_sequences table automatically" do
      expect(db.table_exists?("tina4_sequences")).to be false
      db.get_next_id("users")
      expect(db.table_exists?("tina4_sequences")).to be true
    end

    it "supports custom pk_column" do
      db.execute("CREATE TABLE items (item_id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("INSERT INTO items (item_id, name) VALUES (10, 'Widget')")
      next_id = db.get_next_id("items", pk_column: "item_id")
      expect(next_id).to eq(11)
    end

    it "supports custom generator_name" do
      id1 = db.get_next_id("users", generator_name: "my_custom_seq")
      id2 = db.get_next_id("users", generator_name: "my_custom_seq")
      expect(id2).to eq(id1 + 1)
    end

    it "keeps separate counters for different tables" do
      db.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL)")
      id_users = db.get_next_id("users")
      id_orders = db.get_next_id("orders")
      # Both should start at 1 for empty tables
      expect(id_users).to eq(1)
      expect(id_orders).to eq(1)
      # Second call for users should be 2, orders still at 1 from last call
      id_users2 = db.get_next_id("users")
      expect(id_users2).to eq(2)
    end
  end
end
