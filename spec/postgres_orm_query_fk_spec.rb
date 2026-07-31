# frozen_string_literal: true
#
# Regression spec for two ORM/QueryBuilder bugs found by live PostgreSQL
# validation (v3.13.17 ORM fix batch):
#
#   Bug 1 — Model.query raised NoMethodError. ORM.query called
#           QueryBuilder.from(...) but the factory is QueryBuilder.from_table,
#           so MyModel.query.where(...).get blew up with
#           "undefined method 'from' for class Tina4::QueryBuilder".
#
#   Bug 2 — foreign_key_field's deferred / string-form references never wired
#           the has_many side. The string form (references: "Author") and any
#           forward reference populated @@_fk_registry, but apply_fk_registry!
#           was never invoked — there was no inherited hook — so author.posts
#           silently never wired (while post.author / the Class-first happy path
#           did). The fix adds a Tina4::ORM.inherited hook that re-applies the
#           registry as new model classes load, and resolves already-loaded
#           string references eagerly inside foreign_key_field.
#
# The spec boots a real PostgreSQL and asserts the documented behaviour works:
# Model.query round-trips, and BOTH relationship orderings (string ref with the
# declaring model defined first, and a Class ref) wire has_many AND belongs_to.
#
# It skips automatically when the pg gem is missing or the database is
# unreachable (same gate as the other PG specs), so CI without PostgreSQL
# just no-ops.

require "spec_helper"
require "socket"

PGQFK_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PGQFK_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "5432").to_i
PGQFK_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
PGQFK_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
PGQFK_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pgqfk_reachable?
  TCPSocket.new(PGQFK_HOST, PGQFK_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def pgqfk_gem_available?
  require "pg"
  true
rescue LoadError
  false
end

# --- Models -----------------------------------------------------------------
# String-form deferred reference: the declaring model (PgFkPost) is defined
# BEFORE the referenced model (PgFkAuthor). This is the path that silently
# failed before the fix.
class PgFkPost < Tina4::ORM
  table_name "pgfk_posts"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  foreign_key_field :author_id, references: "PgFkAuthor"
end

class PgFkAuthor < Tina4::ORM
  table_name "pgfk_authors"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  boolean_field :active
end

# Class-form reference, referenced model defined first (the happy path).
class PgFkCategory < Tina4::ORM
  table_name "pgfk_categories"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class PgFkProduct < Tina4::ORM
  table_name "pgfk_products"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  foreign_key_field :category_id, references: PgFkCategory, related_name: :products
end

RSpec.describe "PostgreSQL ORM Model.query + foreign_key_field wiring (v3.13.17)" do
  before(:all) do
    @skip_reason = if !pgqfk_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pgqfk_reachable?
                     "PostgreSQL not reachable at #{PGQFK_HOST}:#{PGQFK_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PGQFK_HOST}:#{PGQFK_PORT}/#{PGQFK_DB}",
      username: PGQFK_USER, password: PGQFK_PASS
    )
    @db.execute("DROP TABLE IF EXISTS pgfk_posts")
    @db.execute("DROP TABLE IF EXISTS pgfk_authors")
    @db.execute("DROP TABLE IF EXISTS pgfk_products")
    @db.execute("DROP TABLE IF EXISTS pgfk_categories")
    @db.execute("CREATE TABLE pgfk_authors (id SERIAL PRIMARY KEY, name VARCHAR(100), active BOOLEAN DEFAULT TRUE)")
    @db.execute("CREATE TABLE pgfk_posts (id SERIAL PRIMARY KEY, title VARCHAR(100), author_id INTEGER)")
    @db.execute("CREATE TABLE pgfk_categories (id SERIAL PRIMARY KEY, name VARCHAR(100))")
    @db.execute("CREATE TABLE pgfk_products (id SERIAL PRIMARY KEY, title VARCHAR(100), category_id INTEGER)")
    [PgFkPost, PgFkAuthor, PgFkCategory, PgFkProduct].each { |m| m.db = @db }
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS pgfk_posts")
      @db.execute("DROP TABLE IF EXISTS pgfk_authors")
      @db.execute("DROP TABLE IF EXISTS pgfk_products")
      @db.execute("DROP TABLE IF EXISTS pgfk_categories")
    ensure
      @db.close rescue nil
    end
  end

  # --- Bug 1 ----------------------------------------------------------------
  describe "Bug 1: Model.query" do
    it "returns a QueryBuilder (does not raise NoMethodError)" do
      expect { PgFkAuthor.query }.not_to raise_error
      expect(PgFkAuthor.query).to be_a(Tina4::QueryBuilder)
    end

    it "Model.query.where(...).get returns matching rows" do
      @db.execute("INSERT INTO pgfk_authors (name, active) VALUES (?, ?)", ["Alice", true])
      @db.execute("INSERT INTO pgfk_authors (name, active) VALUES (?, ?)", ["Bob", false])

      rows = PgFkAuthor.query.where("active = ?", [true]).order_by("name").get
      expect(@db.get_error).to be_nil
      expect(rows.count).to eq(1)
      expect(rows[0][:name]).to eq("Alice")
    end
  end

  # --- Bug 2: string / deferred reference (declaring model defined first) ---
  describe "Bug 2: string-form deferred foreign_key_field" do
    it "wires belongs_to on the declaring model" do
      expect(PgFkPost.relationship_definitions).to have_key(:author)
    end

    it "wires has_many on the referenced model (deferred resolution)" do
      # accessor name = declaring class lowercased + 's' = 'pgfkposts'
      expect(PgFkAuthor.instance_methods).to include(:pgfkposts)
      expect(PgFkAuthor.relationship_definitions).to have_key(:pgfkposts)
    end

    it "round-trips has_many and belongs_to against live PostgreSQL" do
      @db.execute("INSERT INTO pgfk_authors (name, active) VALUES (?, ?)", ["Alice", true])
      author_id = @db.fetch_one("SELECT id FROM pgfk_authors WHERE name = ?", ["Alice"])[:id]
      @db.execute("INSERT INTO pgfk_posts (title, author_id) VALUES (?, ?)", ["Hello", author_id])
      @db.execute("INSERT INTO pgfk_posts (title, author_id) VALUES (?, ?)", ["World", author_id])

      author = PgFkAuthor.find(author_id)
      titles = author.pgfkposts.map(&:title)
      expect(titles).to contain_exactly("Hello", "World")

      post = PgFkPost.where("title = ?", ["Hello"]).first
      expect(post.author).not_to be_nil
      expect(post.author.name).to eq("Alice")
    end
  end

  # --- Bug 2: Class-form reference (referenced model defined first) ---------
  describe "Bug 2: Class-form foreign_key_field with related_name override" do
    it "wires belongs_to on the declaring model and the overridden has_many" do
      expect(PgFkProduct.relationship_definitions).to have_key(:category)
      expect(PgFkCategory.instance_methods).to include(:products)
      expect(PgFkCategory.relationship_definitions).to have_key(:products)
    end

    it "round-trips has_many and belongs_to against live PostgreSQL" do
      @db.execute("INSERT INTO pgfk_categories (name) VALUES (?)", ["Widgets"])
      cat_id = @db.fetch_one("SELECT id FROM pgfk_categories WHERE name = ?", ["Widgets"])[:id]
      @db.execute("INSERT INTO pgfk_products (title, category_id) VALUES (?, ?)", ["Cog", cat_id])

      category = PgFkCategory.find(cat_id)
      expect(category.products.map(&:title)).to eq(["Cog"])

      product = PgFkProduct.find(1)
      expect(product.category&.name).to eq("Widgets")
    end
  end
end
