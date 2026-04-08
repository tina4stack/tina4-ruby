# frozen_string_literal: true

require "spec_helper"

# Test model with soft delete
class SoftDeleteUser < Tina4::ORM
  self.soft_delete = true
  self.soft_delete_field = :is_deleted

  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  string_field :email
  integer_field :is_deleted, default: 0
end

# Test model with field mapping
class MappedUser < Tina4::ORM
  self.field_mapping = { "user_name" => "name", "user_email" => "email" }

  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :email
end

# Models for relationship testing
class Author < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false

  has_many :books, class_name: "Book", foreign_key: "author_id"
  has_one :profile, class_name: "AuthorProfile", foreign_key: "author_id"
end

class Book < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title, nullable: false
  integer_field :author_id

  belongs_to :author, class_name: "Author", foreign_key: "author_id"
end

class AuthorProfile < Tina4::ORM
  table_name "author_profiles"
  integer_field :id, primary_key: true, auto_increment: true
  integer_field :author_id
  string_field :bio
end

RSpec.describe "ORM v3 features" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_orm_v3") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite://#{db_path}") }

  before(:each) do
    Tina4.database = db
    db.execute("CREATE TABLE IF NOT EXISTS softdeleteusers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, is_deleted INTEGER DEFAULT 0)")
    db.execute("CREATE TABLE IF NOT EXISTS mappedusers (id INTEGER PRIMARY KEY AUTOINCREMENT, user_name TEXT, user_email TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, author_id INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS author_profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, author_id INTEGER, bio TEXT)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe "Soft delete" do
    it "marks record as deleted instead of removing" do
      user = SoftDeleteUser.new(name: "Alice", email: "alice@test.com")
      user.save
      id = user.id

      user.delete
      # Record still exists in DB but flagged
      result = db.fetch_one("SELECT * FROM softdeleteusers WHERE id = ?", [id])
      expect(result).not_to be_nil
      expect(result[:is_deleted]).to eq(1)
    end

    it "excludes soft-deleted records from find" do
      user = SoftDeleteUser.new(name: "Bob")
      user.save
      user.delete

      found = SoftDeleteUser.find_by_id(user.id)
      expect(found).to be_nil
    end

    it "excludes soft-deleted records from all" do
      SoftDeleteUser.new(name: "Active").save
      deleted = SoftDeleteUser.new(name: "Deleted")
      deleted.save
      deleted.delete

      results = SoftDeleteUser.all
      expect(results.length).to eq(1)
      expect(results.first.name).to eq("Active")
    end

    it "excludes soft-deleted records from where" do
      SoftDeleteUser.new(name: "Keep").save
      del = SoftDeleteUser.new(name: "Remove")
      del.save
      del.delete

      results = SoftDeleteUser.where("1=1")
      expect(results.length).to eq(1)
    end

    it "excludes soft-deleted records from count" do
      SoftDeleteUser.new(name: "A").save
      SoftDeleteUser.new(name: "B").save
      del = SoftDeleteUser.new(name: "C")
      del.save
      del.delete

      expect(SoftDeleteUser.count).to eq(2)
    end
  end

  describe "Per-model database" do
    it "allows setting a per-model database" do
      other_dir = Dir.mktmpdir("tina4_orm_other")
      other_path = File.join(other_dir, "other.db")
      other_db = Tina4::Database.new("sqlite://#{other_path}")
      other_db.execute("CREATE TABLE IF NOT EXISTS softdeleteusers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, is_deleted INTEGER DEFAULT 0)")

      begin
        SoftDeleteUser.db = other_db
        user = SoftDeleteUser.new(name: "OtherDB")
        user.save
        expect(user.persisted?).to be true

        found = SoftDeleteUser.find_by_id(user.id)
        expect(found).not_to be_nil
        expect(found.name).to eq("OtherDB")
      ensure
        SoftDeleteUser.db = nil  # Reset
        other_db.close
        FileUtils.rm_rf(other_dir)
      end
    end
  end

  describe "Relationships" do
    it "has_many returns associated records" do
      author = Author.new(name: "Tolkien")
      author.save

      Book.new(title: "The Hobbit", author_id: author.id).save
      Book.new(title: "The Silmarillion", author_id: author.id).save

      books = author.books
      expect(books.length).to eq(2)
      expect(books.map(&:title)).to contain_exactly("The Hobbit", "The Silmarillion")
    end

    it "has_one returns single associated record" do
      author = Author.new(name: "Tolkien")
      author.save

      profile = AuthorProfile.new(author_id: author.id, bio: "Fantasy author")
      profile.save

      loaded_profile = author.profile
      expect(loaded_profile).not_to be_nil
      expect(loaded_profile.bio).to eq("Fantasy author")
    end

    it "belongs_to returns parent record" do
      author = Author.new(name: "Tolkien")
      author.save

      book = Book.new(title: "The Hobbit", author_id: author.id)
      book.save

      loaded_author = book.author
      expect(loaded_author).not_to be_nil
      expect(loaded_author.name).to eq("Tolkien")
    end

    it "returns empty array for has_many with no matches" do
      author = Author.new(name: "New Author")
      author.save
      expect(author.books).to eq([])
    end

    it "returns nil for has_one with no match" do
      author = Author.new(name: "No Profile")
      author.save
      expect(author.profile).to be_nil
    end
  end

  describe "find with filter hash" do
    it "finds records by criteria" do
      Author.new(name: "Alice").save
      Author.new(name: "Bob").save

      results = Author.find({name: "Alice"})
      expect(results.length).to eq(1)
      expect(results.first.name).to eq("Alice")
    end
  end

  describe "to_h and to_json" do
    it "converts to hash" do
      author = Author.new(name: "Test")
      hash = author.to_h
      expect(hash[:name]).to eq("Test")
    end

    it "converts to JSON" do
      author = Author.new(name: "JSON Author")
      json = JSON.parse(author.to_json)
      expect(json["name"]).to eq("JSON Author")
    end

    it "to_hash is alias for to_h" do
      author = Author.new(name: "Alias")
      expect(author.to_hash).to eq(author.to_h)
    end
  end

  describe "all with offset" do
    it "supports offset parameter" do
      Author.new(name: "A").save
      Author.new(name: "B").save
      Author.new(name: "C").save

      results = Author.all(limit: 2, offset: 1, order_by: "name ASC")
      expect(results.length).to eq(2)
      expect(results.first.name).to eq("B")
    end
  end

  describe "Eager loading" do
    it "eager loads has_many with include" do
      a1 = Author.new(name: "A")
      a1.save
      a2 = Author.new(name: "B")
      a2.save

      Book.new(title: "B1", author_id: a1.id).save
      Book.new(title: "B2", author_id: a1.id).save
      Book.new(title: "B3", author_id: a2.id).save

      results = Author.all(include: ["books"])
      expect(results.length).to eq(2)

      author_a = results.find { |a| a.name == "A" }
      author_b = results.find { |a| a.name == "B" }
      expect(author_a.books.length).to eq(2)
      expect(author_b.books.length).to eq(1)
    end

    it "eager loads has_one with include" do
      author = Author.new(name: "WithProfile")
      author.save
      AuthorProfile.new(author_id: author.id, bio: "Bio text").save

      results = Author.where("name = ?", ["WithProfile"], include: ["profile"])
      expect(results.length).to eq(1)
      expect(results[0].profile).not_to be_nil
      expect(results[0].profile.bio).to eq("Bio text")
    end

    it "eager loads belongs_to with include" do
      author = Author.new(name: "Parent")
      author.save
      Book.new(title: "Child", author_id: author.id).save

      books = Book.where("title = ?", ["Child"], include: ["author"])
      expect(books.length).to eq(1)
      expect(books[0].author).not_to be_nil
      expect(books[0].author.name).to eq("Parent")
    end
  end

  describe "to_h with include" do
    it "includes has_many relationships" do
      author = Author.new(name: "Alice")
      author.save
      Book.new(title: "Hello", author_id: author.id).save

      hash = author.to_h(include: ["books"])
      expect(hash[:books]).not_to be_nil
      expect(hash[:books].length).to eq(1)
      expect(hash[:books][0][:title]).to eq("Hello")
    end

    it "includes belongs_to relationships" do
      author = Author.new(name: "Bob")
      author.save
      book = Book.new(title: "Mine", author_id: author.id)
      book.save

      hash = book.to_h(include: ["author"])
      expect(hash[:author]).not_to be_nil
      expect(hash[:author][:name]).to eq("Bob")
    end

    it "includes nil for missing has_one" do
      author = Author.new(name: "NoProfile")
      author.save

      hash = author.to_h(include: ["profile"])
      expect(hash.key?(:profile)).to be true
      expect(hash[:profile]).to be_nil
    end
  end

  describe "Relationship cache clears on save" do
    it "clears relationship cache when save is called" do
      author = Author.new(name: "Cached")
      author.save
      Book.new(title: "Before", author_id: author.id).save

      _ = author.books  # Fill cache
      author.name = "Updated"
      author.save

      # Cache was cleared, so accessing books triggers fresh load
      books = author.books
      expect(books.length).to eq(1)
    end
  end
end
