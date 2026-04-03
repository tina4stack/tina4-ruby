# frozen_string_literal: true

require "spec_helper"

# Define a test model
class TestUser < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  string_field :email, length: 255
  integer_field :age, default: 0
end

RSpec.describe Tina4::ORM do
  let(:tmp_dir) { Dir.mktmpdir("tina4_orm_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite://#{db_path}") }

  before(:each) do
    Tina4.database = db
    db.execute("CREATE TABLE IF NOT EXISTS testusers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, age INTEGER DEFAULT 0)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe "field definitions" do
    it "defines fields with accessors" do
      user = TestUser.new
      user.name = "Alice"
      expect(user.name).to eq("Alice")
    end

    it "tracks primary key field" do
      expect(TestUser.primary_key_field).to eq(:id)
    end

    it "auto-generates table name" do
      expect(TestUser.table_name).to eq("testusers")
    end

    it "sets default values" do
      user = TestUser.new(name: "Bob")
      expect(user.age).to eq(0)
    end
  end

  describe "#save (create)" do
    it "inserts a new record" do
      user = TestUser.new(name: "Alice", email: "alice@test.com")
      result = user.save
      expect(result).to be true
      expect(user.persisted?).to be true
    end

    it "sets the auto-increment id" do
      user = TestUser.new(name: "Alice")
      user.save
      expect(user.id).to be_a(Integer)
      expect(user.id).to be > 0
    end
  end

  describe "#save (update)" do
    it "updates an existing record" do
      user = TestUser.new(name: "Alice")
      user.save
      user.name = "Alice Updated"
      user.save

      loaded = TestUser.find(user.id)
      expect(loaded.name).to eq("Alice Updated")
    end
  end

  describe ".find" do
    it "finds a record by primary key" do
      user = TestUser.new(name: "Bob", email: "bob@test.com")
      user.save

      found = TestUser.find(user.id)
      expect(found).not_to be_nil
      expect(found.name).to eq("Bob")
      expect(found.email).to eq("bob@test.com")
    end

    it "returns nil for non-existent record" do
      expect(TestUser.find(99999)).to be_nil
    end
  end

  describe ".select_one" do
    it "returns a single ORM instance for a matching query" do
      TestUser.new(name: "Alice", age: 25).save
      TestUser.new(name: "Bob", age: 30).save

      result = TestUser.select_one("SELECT * FROM testusers WHERE name = ?", ["Alice"])
      expect(result).to be_a(TestUser)
      expect(result.name).to eq("Alice")
    end

    it "returns nil when no rows match" do
      result = TestUser.select_one("SELECT * FROM testusers WHERE name = ?", ["Nonexistent"])
      expect(result).to be_nil
    end
  end

  describe ".where" do
    it "returns matching records" do
      TestUser.new(name: "Alice", age: 25).save
      TestUser.new(name: "Bob", age: 30).save
      TestUser.new(name: "Eve", age: 25).save

      results = TestUser.where("age = ?", [25])
      expect(results.length).to eq(2)
      expect(results.map(&:name)).to contain_exactly("Alice", "Eve")
    end
  end

  describe ".all" do
    it "returns all records" do
      TestUser.new(name: "A").save
      TestUser.new(name: "B").save
      results = TestUser.all
      expect(results.length).to eq(2)
    end
  end

  describe ".create" do
    it "creates and saves in one step" do
      user = TestUser.create(name: "Quick")
      expect(user.persisted?).to be true
      expect(user.id).to be > 0
    end
  end

  describe "#delete" do
    it "removes the record" do
      user = TestUser.create(name: "ToDelete")
      id = user.id
      user.delete
      expect(TestUser.find(id)).to be_nil
    end
  end

  describe ".load" do
    it "loads data by primary key via select_one" do
      created = TestUser.create(name: "LoadMe", email: "load@test.com")
      user = TestUser.load("SELECT * FROM testusers WHERE id = ?", [created.id])
      expect(user).not_to be_nil
      expect(user.name).to eq("LoadMe")
    end

    it "loads data with a filter SQL and params" do
      TestUser.create(name: "FilterUser", email: "filter@test.com")
      user = TestUser.load("SELECT * FROM testusers WHERE email = ?", ["filter@test.com"])
      expect(user).not_to be_nil
      expect(user.name).to eq("FilterUser")
      expect(user.email).to eq("filter@test.com")
    end

    it "returns nil when filter matches no records" do
      result = TestUser.load("SELECT * FROM testusers WHERE email = ?", ["nonexistent@test.com"])
      expect(result).to be_nil
    end
  end

  describe "#to_hash" do
    it "converts to hash" do
      user = TestUser.new(name: "Hash", email: "hash@test.com", age: 20)
      hash = user.to_hash
      expect(hash[:name]).to eq("Hash")
      expect(hash[:email]).to eq("hash@test.com")
    end
  end

  describe "#to_json" do
    it "converts to JSON string" do
      user = TestUser.new(name: "JSON", age: 30)
      json = JSON.parse(user.to_json)
      expect(json["name"]).to eq("JSON")
    end
  end

  # ── Validation Tests ───────────────────────────────────────────

  describe "#validate" do
    it "returns empty array for valid model" do
      user = TestUser.new(name: "Valid")
      errors = user.validate
      expect(errors).to eq([])
    end

    it "returns errors for missing required field" do
      user = TestUser.new
      errors = user.validate
      expect(errors.length).to be >= 1
      expect(errors.any? { |e| e.downcase.include?("name") || e.downcase.include?("required") || e.downcase.include?("null") }).to be true
    end

    it "accepts valid values for all fields" do
      user = TestUser.new(name: "Test", email: "test@example.com", age: 25)
      expect(user.validate).to eq([])
    end
  end

  # ── find_by_id Tests ───────────────────────────────────────────

  describe ".find_by_id" do
    it "finds a record by its primary key (alias)" do
      user = TestUser.create(name: "FindById")
      found = TestUser.find(user.id)
      expect(found).not_to be_nil
      expect(found.name).to eq("FindById")
    end
  end

  # ── Auto-increment IDs ────────────────────────────────────────

  describe "auto-increment IDs" do
    it "assigns sequential IDs" do
      u1 = TestUser.create(name: "First")
      u2 = TestUser.create(name: "Second")
      expect(u2.id).to be > u1.id
    end
  end

  # ── .count ─────────────────────────────────────────────────────

  describe ".count" do
    it "returns the number of records" do
      TestUser.create(name: "A")
      TestUser.create(name: "B")
      TestUser.create(name: "C")
      expect(TestUser.count).to eq(3)
    end

    it "returns 0 for empty table" do
      expect(TestUser.count).to eq(0)
    end
  end

  # ── .select with SQL ──────────────────────────────────────────

  describe ".select" do
    it "returns records via raw SQL" do
      TestUser.create(name: "Alice")
      TestUser.create(name: "Bob")

      results = TestUser.select("SELECT * FROM testusers ORDER BY name")
      expect(results.length).to eq(2)
      expect(results.first.name).to eq("Alice")
      expect(results.last.name).to eq("Bob")
    end

    it "supports parameterized queries" do
      TestUser.create(name: "Alice", age: 25)
      TestUser.create(name: "Bob", age: 30)

      results = TestUser.select("SELECT * FROM testusers WHERE age > ?", [26])
      expect(results.length).to eq(1)
      expect(results.first.name).to eq("Bob")
    end
  end

  # ── persisted? ─────────────────────────────────────────────────

  describe "#persisted?" do
    it "is false for new unsaved record" do
      user = TestUser.new(name: "New")
      expect(user.persisted?).to be false
    end

    it "is true after save" do
      user = TestUser.new(name: "Saved")
      user.save
      expect(user.persisted?).to be true
    end
  end

  # ── update semantics ───────────────────────────────────────────

  describe "update semantics" do
    it "keeps the same id after update" do
      user = TestUser.create(name: "Original")
      original_id = user.id
      user.name = "Updated"
      user.save
      expect(user.id).to eq(original_id)
    end

    it "only updates changed fields" do
      user = TestUser.create(name: "Alice", email: "alice@test.com", age: 25)
      user.name = "Alice Updated"
      user.save

      reloaded = TestUser.find(user.id)
      expect(reloaded.name).to eq("Alice Updated")
      expect(reloaded.email).to eq("alice@test.com")
      expect(reloaded.age).to eq(25)
    end
  end

  # ── to_h / to_hash aliases ────────────────────────────────────

  describe "#to_h and #to_hash" do
    it "to_h returns a hash of fields" do
      user = TestUser.new(name: "Hash", email: "hash@test.com", age: 20)
      hash = user.to_h
      expect(hash[:name]).to eq("Hash")
      expect(hash[:email]).to eq("hash@test.com")
    end

    it "to_hash is an alias for to_h" do
      user = TestUser.new(name: "Alias")
      expect(user.to_hash).to eq(user.to_h)
    end
  end

  # ── default values ─────────────────────────────────────────────

  describe "default values" do
    it "applies default from field definition" do
      user = TestUser.new(name: "Defaults")
      expect(user.age).to eq(0)
    end

    it "allows overriding defaults" do
      user = TestUser.new(name: "Override", age: 42)
      expect(user.age).to eq(42)
    end
  end

  # ── delete edge cases ─────────────────────────────────────────

  describe "delete edge cases" do
    it "delete removes from database" do
      user = TestUser.create(name: "Gone")
      uid = user.id
      user.delete
      expect(TestUser.find(uid)).to be_nil
    end

    it "find returns nil for non-existent" do
      expect(TestUser.find(99999)).to be_nil
    end
  end
end
