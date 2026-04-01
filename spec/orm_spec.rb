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

      result = TestUser.select_one("SELECT * FROM test_users WHERE name = ?", ["Alice"])
      expect(result).to be_a(TestUser)
      expect(result.name).to eq("Alice")
    end

    it "returns nil when no rows match" do
      result = TestUser.select_one("SELECT * FROM test_users WHERE name = ?", ["Nonexistent"])
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

  describe "#load" do
    it "loads data into existing instance" do
      created = TestUser.create(name: "LoadMe", email: "load@test.com")
      user = TestUser.new
      user.id = created.id
      result = user.load
      expect(result).to be true
      expect(user.name).to eq("LoadMe")
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
end
