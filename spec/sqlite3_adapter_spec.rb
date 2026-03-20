# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Adapters::Sqlite3Adapter do
  let(:tmp_dir) { Dir.mktmpdir("tina4_sqlite3_adapter") }
  let(:db_path) { File.join(tmp_dir, "test_adapter.db") }
  let(:adapter) { Tina4::Adapters::Sqlite3Adapter.new("sqlite://#{db_path}") }

  after(:each) do
    adapter.close if adapter.connected?
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#connect" do
    it "connects to a SQLite database" do
      expect(adapter.connected?).to be true
    end

    it "strips sqlite:// prefix from path" do
      expect(adapter.db_path).to eq(db_path)
    end
  end

  describe "#close" do
    it "closes the connection" do
      adapter.close
      expect(adapter.connected?).to be false
    end
  end

  describe "#exec" do
    it "executes DDL statements" do
      adapter.exec("CREATE TABLE test_items (id INTEGER PRIMARY KEY, name TEXT)")
      expect(adapter.table_exists?("test_items")).to be true
    end
  end

  describe "#query" do
    before do
      adapter.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER)")
      adapter.exec("INSERT INTO users (name, age) VALUES (?, ?)", ["Alice", 30])
      adapter.exec("INSERT INTO users (name, age) VALUES (?, ?)", ["Bob", 25])
      adapter.exec("INSERT INTO users (name, age) VALUES (?, ?)", ["Eve", 35])
    end

    it "returns rows as symbol-keyed hashes" do
      rows = adapter.query("SELECT * FROM users")
      expect(rows.length).to eq(3)
      expect(rows.first).to have_key(:name)
      expect(rows.first).to have_key(:age)
    end

    it "supports parameterized queries" do
      rows = adapter.query("SELECT * FROM users WHERE age > ?", [28])
      expect(rows.length).to eq(2)
      names = rows.map { |r| r[:name] }
      expect(names).to contain_exactly("Alice", "Eve")
    end

    it "returns empty array for no matches" do
      rows = adapter.query("SELECT * FROM users WHERE age > ?", [100])
      expect(rows).to eq([])
    end
  end

  describe "#fetch" do
    before do
      adapter.exec("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      5.times { |i| adapter.exec("INSERT INTO items (name) VALUES (?)", ["item_#{i}"]) }
    end

    it "returns all rows without limit" do
      rows = adapter.fetch("SELECT * FROM items")
      expect(rows.length).to eq(5)
    end

    it "limits results" do
      rows = adapter.fetch("SELECT * FROM items ORDER BY id", 2)
      expect(rows.length).to eq(2)
    end

    it "supports offset with limit" do
      rows = adapter.fetch("SELECT * FROM items ORDER BY id", 2, 2)
      expect(rows.length).to eq(2)
      expect(rows.first[:name]).to eq("item_2")
    end
  end

  describe "#table_exists?" do
    it "returns true for existing table" do
      adapter.exec("CREATE TABLE existing (id INTEGER)")
      expect(adapter.table_exists?("existing")).to be true
    end

    it "returns false for non-existing table" do
      expect(adapter.table_exists?("nonexistent")).to be false
    end
  end

  describe "#tables" do
    it "lists all user tables" do
      adapter.exec("CREATE TABLE table_a (id INTEGER)")
      adapter.exec("CREATE TABLE table_b (id INTEGER)")
      tables = adapter.tables
      expect(tables).to include("table_a")
      expect(tables).to include("table_b")
    end
  end

  describe "#columns" do
    it "returns column metadata" do
      adapter.exec("CREATE TABLE metadata (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER DEFAULT 0)")
      cols = adapter.columns("metadata")
      expect(cols.length).to eq(3)

      id_col = cols.find { |c| c[:name] == "id" }
      expect(id_col[:primary_key]).to be true

      name_col = cols.find { |c| c[:name] == "name" }
      expect(name_col[:nullable]).to be false
    end
  end

  describe "#last_insert_id" do
    it "returns the last inserted row id" do
      adapter.exec("CREATE TABLE auto_inc (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)")
      adapter.exec("INSERT INTO auto_inc (val) VALUES (?)", ["test"])
      expect(adapter.last_insert_id).to eq(1)
      adapter.exec("INSERT INTO auto_inc (val) VALUES (?)", ["test2"])
      expect(adapter.last_insert_id).to eq(2)
    end
  end

  describe "Transactions" do
    before do
      adapter.exec("CREATE TABLE txn_test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    end

    it "commits on success" do
      adapter.transaction do |db|
        db.exec("INSERT INTO txn_test (name) VALUES (?)", ["committed"])
      end
      rows = adapter.query("SELECT * FROM txn_test")
      expect(rows.length).to eq(1)
      expect(rows.first[:name]).to eq("committed")
    end

    it "rolls back on error" do
      begin
        adapter.transaction do |db|
          db.exec("INSERT INTO txn_test (name) VALUES (?)", ["should_rollback"])
          raise "deliberate error"
        end
      rescue RuntimeError
        # Expected
      end
      rows = adapter.query("SELECT * FROM txn_test")
      expect(rows.length).to eq(0)
    end

    it "supports manual begin/commit" do
      adapter.begin_transaction
      adapter.exec("INSERT INTO txn_test (name) VALUES (?)", ["manual"])
      adapter.commit
      rows = adapter.query("SELECT * FROM txn_test")
      expect(rows.length).to eq(1)
    end

    it "supports manual rollback" do
      adapter.begin_transaction
      adapter.exec("INSERT INTO txn_test (name) VALUES (?)", ["will_rollback"])
      adapter.rollback
      rows = adapter.query("SELECT * FROM txn_test")
      expect(rows.length).to eq(0)
    end
  end

  describe "#placeholder and #placeholders" do
    it "returns ? as placeholder" do
      expect(adapter.placeholder).to eq("?")
    end

    it "returns comma-separated placeholders" do
      expect(adapter.placeholders(3)).to eq("?, ?, ?")
    end
  end

  describe "#apply_limit" do
    it "appends LIMIT and OFFSET" do
      sql = adapter.apply_limit("SELECT * FROM items", 10, 20)
      expect(sql).to eq("SELECT * FROM items LIMIT 10 OFFSET 20")
    end
  end
end
