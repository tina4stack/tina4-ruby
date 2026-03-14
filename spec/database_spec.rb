# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Tina4::Database do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite://#{db_path}") }

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
      expect(result.count).to eq(2)
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
end
