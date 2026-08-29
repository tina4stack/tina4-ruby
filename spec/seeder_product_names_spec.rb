# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Product-name seeding — a generic `name`/`full_name` column on a product-ish
# table gets product names ("Wireless Keyboard"), not person names ("John
# Smith").
#
# No mocks: the integration examples seed a REAL SQLite table/model and read the
# rows back. The heuristic examples call the real FakeData/seeder over real
# strings (pure — no dependency, no double). Product and person vocabularies are
# disjoint, so the first word of a generated value tells which generator ran.
# Mirrors the Python master's tests/test_seeder_product_names.py.

# Top-level test models — declared here (NOT as bare constants inside a
# describe block, which leak onto Object; see
# reference_ruby_constants_are_global_in_rspec) exactly like spec/seeder_spec.rb.
# The class NAME carries the product signal that seed_orm threads (orm_class.name),
# and the table name agrees so the fixture is unambiguous.
class ProdSeedProduct < Tina4::ORM
  table_name "products"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class ProdSeedUser < Tina4::ORM
  table_name "users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

# Instance helper shared only with the groups that include it (no global leak).
module ProductSeedFirstWord
  def first_word(value)
    value.to_s.split(" ", 2).first
  end

  PRODUCT_ADJ = Tina4::FakeData::PRODUCT_ADJECTIVES
  PERSON_FIRST = Tina4::FakeData::FIRST_NAMES
end

RSpec.describe "Tina4::FakeData#product" do
  include ProductSeedFirstWord

  it "is an adjective + noun (at least two words)" do
    fake = Tina4::FakeData.new(seed: 1)
    p = fake.product
    expect(ProductSeedFirstWord::PRODUCT_ADJ).to include(first_word(p)) # first word is an adjective
    expect(p).to include(" ")
    expect(p.split.length).to be >= 2
  end

  it "is deterministic under a seed and varies across draws (not one constant)" do
    a = Array.new(3) { Tina4::FakeData.new(seed: 7).product }
    b = Array.new(3) { Tina4::FakeData.new(seed: 7).product }
    expect(a).to eq(b)

    fake = Tina4::FakeData.new(seed: 3)
    expect(Array.new(30) { fake.product }.uniq.length).to be > 1
  end

  it "draws its noun from the PRODUCT_NOUNS list" do
    fake = Tina4::FakeData.new(seed: 5)
    20.times do
      # split once: leading adjective (always single word) then the full noun,
      # which may itself be multi-word ("Coffee Beans").
      noun = fake.product.split(" ", 2).last
      expect(Tina4::FakeData::PRODUCT_NOUNS).to include(noun)
    end
  end

  it "product vocabulary is disjoint from person first-names" do
    # This disjointness is what makes the first-word, table-aware assertions
    # below unambiguous: a product's first word is never a person first-name.
    expect(Tina4::FakeData::PRODUCT_ADJECTIVES & Tina4::FakeData::FIRST_NAMES).to eq([])
  end
end

RSpec.describe "Tina4::FakeData.product_table?" do
  ["products", "Product", "order_items", "catalog", "inventory", "sku_table", "listings"].each do |t|
    it "is true for product-ish #{t.inspect}" do
      expect(Tina4::FakeData.product_table?(t)).to be true
    end
  end

  ["users", "people", "customers", "employees", nil, "", "orders"].each do |t|
    it "is false for non-product #{t.inspect} (nil/empty keep the person default)" do
      expect(Tina4::FakeData.product_table?(t)).to be false
    end
  end
end

RSpec.describe "Tina4::FakeData#for_field is table-aware for generic name columns" do
  include ProductSeedFirstWord

  let(:meta) { { type: :string, length: 255 } }

  it "a generic name column -> product on a product table" do
    fake = Tina4::FakeData.new(seed: 1)
    expect(ProductSeedFirstWord::PRODUCT_ADJ).to include(first_word(fake.for_field(meta, :name, "products")))
  end

  it "a generic name column -> person on a non-product table" do
    fake = Tina4::FakeData.new(seed: 1)
    expect(ProductSeedFirstWord::PERSON_FIRST).to include(first_word(fake.for_field(meta, :name, "users")))
  end

  it "a generic name column -> person with NO table context (back-compat)" do
    fake = Tina4::FakeData.new(seed: 1)
    expect(ProductSeedFirstWord::PERSON_FIRST).to include(first_word(fake.for_field(meta, :name)))
  end

  it "full_name and fullname also switch to product on a product-ish table" do
    %i[full_name fullname].each do |col|
      fake = Tina4::FakeData.new(seed: 1)
      expect(ProductSeedFirstWord::PRODUCT_ADJ).to include(first_word(fake.for_field(meta, col, "inventory")))
    end
  end

  it "first_name / last_name / user_name stay person even on a product table" do
    fake = Tina4::FakeData.new(seed: 1)
    # first_name/last_name return the bare name; user_name is username-style.
    expect(ProductSeedFirstWord::PERSON_FIRST).to include(fake.for_field(meta, :first_name, "products"))
    expect(Tina4::FakeData::LAST_NAMES).to include(fake.for_field(meta, :last_name, "products"))
    un = fake.for_field(meta, :user_name, "products")
    expect(ProductSeedFirstWord::PRODUCT_ADJ).not_to include(first_word(un))
  end
end

RSpec.describe "product-name seeding — real SQLite (no mocks)" do
  include ProductSeedFirstWord

  let(:tmp_dir) { Dir.mktmpdir("tina4_product_seed") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE IF NOT EXISTS products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL)")
    db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "seed_orm on a Product model fills its name column with product names" do
    Tina4.seed_orm(ProdSeedProduct, count: 8, seed: 42)
    names = db.fetch("SELECT name FROM products", [], limit: 100).to_a.map { |r| r[:name] }
    expect(names.length).to eq(8)
    names.each { |n| expect(ProductSeedFirstWord::PRODUCT_ADJ).to include(first_word(n)), n.to_s }
  end

  it "seed_orm on a User model fills its name column with person names" do
    Tina4.seed_orm(ProdSeedUser, count: 8, seed: 42)
    names = db.fetch("SELECT name FROM users", [], limit: 100).to_a.map { |r| r[:name] }
    expect(names.length).to eq(8)
    names.each { |n| expect(ProductSeedFirstWord::PERSON_FIRST).to include(first_word(n)), n.to_s }
  end

  it "seed_table on a raw products table fills name with product names (auto-field-map/dev-admin/MCP path)" do
    Tina4.seed_table("products", { name: :string, price: :float }, count: 8)
    names = db.fetch("SELECT name FROM products", [], limit: 100).to_a.map { |r| r[:name] }
    expect(names.length).to eq(8)
    names.each { |n| expect(ProductSeedFirstWord::PRODUCT_ADJ).to include(first_word(n)), n.to_s }
  end

  it "seed_table on a raw users table fills name with person names" do
    Tina4.seed_table("users", { name: :string }, count: 8)
    names = db.fetch("SELECT name FROM users", [], limit: 100).to_a.map { |r| r[:name] }
    expect(names.length).to eq(8)
    names.each { |n| expect(ProductSeedFirstWord::PERSON_FIRST).to include(first_word(n)), n.to_s }
  end

  it "seed_orm product names are reproducible with the same seed" do
    Tina4.seed_orm(ProdSeedProduct, count: 6, clear: true, seed: 99)
    first = db.fetch("SELECT name FROM products ORDER BY id", [], limit: 100).to_a.map { |r| r[:name] }

    Tina4.seed_orm(ProdSeedProduct, count: 6, clear: true, seed: 99)
    second = db.fetch("SELECT name FROM products ORDER BY id", [], limit: 100).to_a.map { |r| r[:name] }

    expect(first).to eq(second)
    expect(first.length).to eq(6)
    # ...and they really are product names, not person names.
    first.each { |n| expect(ProductSeedFirstWord::PRODUCT_ADJ).to include(first_word(n)), n.to_s }
  end
end
