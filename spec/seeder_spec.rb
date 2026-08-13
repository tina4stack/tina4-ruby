# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Test ORM models for seeding
class SeedTestUser < Tina4::ORM
  table_name "seed_users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :first_name
  string_field :last_name
  string_field :email
  integer_field :age, default: 0
  float_field :balance, default: 0.0
  text_field :bio
end

class SeedTestCategory < Tina4::ORM
  table_name "seed_categories"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  text_field :description
end

class SeedTestProduct < Tina4::ORM
  table_name "seed_products"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  float_field :price, default: 0.0
  integer_field :category_id
  string_field :status
end

# ===================================================================
# FakeData Tests
# ===================================================================

RSpec.describe Tina4::FakeData do
  describe "deterministic seeding" do
    it "produces identical output with the same seed" do
      a = Tina4::FakeData.new(seed: 42)
      b = Tina4::FakeData.new(seed: 42)

      expect(a.name).to eq(b.name)
      expect(a.email).to eq(b.email)
      expect(a.integer).to eq(b.integer)
    end

    it "produces different output with different seeds" do
      a = Array.new(10) { Tina4::FakeData.new(seed: 1).name }
      b = Array.new(10) { Tina4::FakeData.new(seed: 999).name }
      expect(a).not_to eq(b)
    end
  end

  describe "name generators" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "#first_name returns a non-empty string" do
      expect(fake.first_name).to be_a(String)
      expect(fake.first_name.length).to be > 0
    end

    it "#last_name returns a non-empty string" do
      expect(fake.last_name).to be_a(String)
      expect(fake.last_name.length).to be > 0
    end

    it "#name returns first + last" do
      expect(fake.name).to include(" ")
    end
  end

  describe "contact generators" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "#email contains @" do
      expect(fake.email).to include("@")
    end

    it "#email from name uses the name" do
      email = fake.email(from_name: "John Smith")
      expect(email).to start_with("john.smith")
    end

    it "#phone starts with +1" do
      expect(fake.phone).to start_with("+1")
    end
  end

  describe "text generators" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "#sentence ends with period" do
      expect(fake.sentence).to end_with(".")
    end

    it "#sentence has correct word count" do
      s = fake.sentence(words: 8)
      word_count = s.chomp(".").split.length
      expect(word_count).to eq(8)
    end

    it "#sentence capitalizes first word" do
      s = fake.sentence
      expect(s[0]).to match(/[A-Z]/)
    end

    it "#paragraph returns multi-sentence text" do
      expect(fake.paragraph.length).to be > 20
    end

    it "#text respects max_length" do
      t = fake.text(max_length: 50)
      expect(t.length).to be <= 50
    end

    it "#word returns a single word" do
      expect(fake.word).not_to include(" ")
    end

    it "#slug uses hyphens" do
      slug = fake.slug(words: 3)
      expect(slug.split("-").length).to eq(3)
    end

    it "#url starts with https" do
      expect(fake.url).to start_with("https://")
    end
  end

  describe "number generators" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "#integer stays in range" do
      100.times do
        val = fake.integer(min: 10, max: 20)
        expect(val).to be_between(10, 20)
      end
    end

    it "#numeric stays in range" do
      100.times do
        val = fake.numeric(min: 0.0, max: 10.0)
        expect(val).to be_between(0.0, 10.0)
      end
    end

    it "#boolean returns a native true or false" do
      vals = Set.new(100.times.map { fake.boolean })
      expect(vals).to eq(Set[true, false])
      vals.each { |v| expect(v).to be(true).or be(false) }
    end
  end

  describe "date/time generators" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "#datetime returns a Time" do
      expect(fake.datetime).to be_a(Time)
    end

    it "#date returns YYYY-MM-DD" do
      expect(fake.date).to match(/^\d{4}-\d{2}-\d{2}$/)
    end

    it "#timestamp returns YYYY-MM-DD HH:MM:SS" do
      expect(fake.timestamp).to match(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/)
    end
  end

  describe "other generators" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "#blob returns bytes" do
      b = fake.blob(size: 32)
      expect(b).to be_a(String)
      expect(b.bytesize).to eq(32)
    end

    it "#json_data returns a hash" do
      expect(fake.json_data).to be_a(Hash)
      expect(fake.json_data.length).to be_between(2, 5)
    end

    it "#json_data with keys uses those keys" do
      data = fake.json_data(keys: %w[name value])
      expect(data.keys).to match_array(%w[name value])
    end

    it "#city picks a real value from the fixed CITIES list" do
      cities = Array.new(20) { fake.city }
      # Every generated city is an actual member of the curated list...
      cities.each { |c| expect(Tina4::FakeData::CITIES).to include(c) }
      # ...and none escapes the list (proves it's a generated city, not any String).
      expect(cities - Tina4::FakeData::CITIES).to be_empty
    end

    it "#country picks a real value from the fixed COUNTRIES list" do
      countries = Array.new(20) { fake.country }
      countries.each { |c| expect(Tina4::FakeData::COUNTRIES).to include(c) }
      expect(countries - Tina4::FakeData::COUNTRIES).to be_empty
    end

    it "#address has number and street" do
      expect(fake.address.split.length).to be >= 3
    end

    it "#zip_code is 5 digits" do
      expect(fake.zip_code).to match(/^\d{5}$/)
    end

    it "#company contains a space" do
      expect(fake.company).to include(" ")
    end

    it "#color_hex is a valid hex color" do
      expect(fake.color_hex).to match(/^#[0-9a-f]{6}$/)
    end

    it "#uuid has correct format" do
      u = fake.uuid
      expect(u.split("-").length).to eq(5)
      expect(u.length).to eq(36)
    end

    it "#password returns alphanumeric" do
      p = fake.password(length: 16)
      expect(p.length).to eq(16)
      expect(p).to match(/^[a-zA-Z0-9]+$/)
    end
  end

  describe "#for_field" do
    let(:fake) { Tina4::FakeData.new(seed: 1) }

    it "returns nil for auto-increment primary key" do
      field = { type: :integer, primary_key: true, auto_increment: true }
      expect(fake.for_field(field, :id)).to be_nil
    end

    it "generates age in range" do
      50.times do
        val = fake.for_field({ type: :integer }, :age)
        expect(val).to be_between(18, 85)
      end
    end

    it "generates email with @" do
      val = fake.for_field({ type: :string, length: 255 }, :email)
      expect(val).to include("@")
    end

    it "generates full name for 'name' column" do
      val = fake.for_field({ type: :string, length: 255 }, :name)
      expect(val).to include(" ")
    end

    it "generates status from predefined list" do
      val = fake.for_field({ type: :string, length: 255 }, :status)
      expect(%w[active inactive pending archived]).to include(val)
    end

    it "generates price in range" do
      val = fake.for_field({ type: :float }, :price)
      expect(val).to be_between(0.01, 9999.99)
    end

    it "generates timestamp for datetime field" do
      val = fake.for_field({ type: :datetime }, :created_at)
      expect(val).to match(/^\d{4}-\d{2}-\d{2}/)
    end

    it "generates json for json field" do
      val = fake.for_field({ type: :json }, :metadata)
      expect(val).to be_a(Hash)
    end

    it "respects max_length" do
      val = fake.for_field({ type: :string, length: 10 }, :email)
      expect(val.length).to be <= 10
    end
  end
end

# ===================================================================
# seed_orm Tests
# ===================================================================

RSpec.describe "Tina4.seed_orm" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seeder_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE IF NOT EXISTS seed_users (id INTEGER PRIMARY KEY AUTOINCREMENT, first_name TEXT, last_name TEXT, email TEXT, age INTEGER DEFAULT 0, balance REAL DEFAULT 0.0, bio TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS seed_categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, description TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS seed_products (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, price REAL DEFAULT 0.0, category_id INTEGER, status TEXT)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "seeds the correct number of records" do
    count = Tina4.seed_orm(SeedTestUser, count: 5, seed: 42)
    expect(count).to eq(5)

    result = db.fetch_one("SELECT count(*) as cnt FROM seed_users")
    expect(result[:cnt]).to eq(5)
  end

  it "generates quality data" do
    Tina4.seed_orm(SeedTestUser, count: 3, seed: 42)

    results = db.fetch("SELECT * FROM seed_users")
    results.each do |row|
      expect(row[:first_name]).not_to be_nil
      expect(row[:last_name]).not_to be_nil
      expect(row[:email].to_s).to include("@")
    end
  end

  it "supports static overrides" do
    Tina4.seed_orm(SeedTestUser, count: 3, overrides: { first_name: "TestName" }, seed: 42)

    results = db.fetch("SELECT first_name FROM seed_users")
    results.each do |row|
      expect(row[:first_name]).to eq("TestName")
    end
  end

  it "supports callable overrides" do
    Tina4.seed_orm(SeedTestUser, count: 5, overrides: {
      age: ->(fake) { fake.integer(min: 25, max: 25) }
    }, seed: 42)

    results = db.fetch("SELECT age FROM seed_users")
    results.each do |row|
      expect(row[:age]).to eq(25)
    end
  end

  it "clears before seeding with clear: true" do
    Tina4.seed_orm(SeedTestUser, count: 10, clear: true, seed: 1)
    Tina4.seed_orm(SeedTestUser, count: 3, clear: true, seed: 2)

    result = db.fetch_one("SELECT count(*) as cnt FROM seed_users")
    expect(result[:cnt]).to eq(3)
  end

  it "does NOT skip by default even when enough records already exist (SEED-RUBY-QUIRKS fix)" do
    # Parity fix: the idempotency short-circuit used to run unconditionally,
    # silently dropping a caller's explicit seed request. Python/PHP/Node
    # never had this behaviour, so the default is now "always seed" like them.
    Tina4.seed_orm(SeedTestUser, count: 5, seed: 42)
    count2 = Tina4.seed_orm(SeedTestUser, count: 5, seed: 99)
    expect(count2).to eq(5)

    result = db.fetch_one("SELECT count(*) as cnt FROM seed_users")
    expect(result[:cnt]).to eq(10)
  end

  it "skips when enough records exist WITH idempotent: true (opt-in)" do
    Tina4.seed_orm(SeedTestUser, count: 5, seed: 42)
    count2 = Tina4.seed_orm(SeedTestUser, count: 5, seed: 99, idempotent: true)
    expect(count2).to eq(0)

    result = db.fetch_one("SELECT count(*) as cnt FROM seed_users")
    expect(result[:cnt]).to eq(5)
  end

  it "is deterministic with same seed" do
    Tina4.seed_orm(SeedTestUser, count: 3, seed: 42)
    first_run = db.fetch("SELECT first_name, last_name FROM seed_users ORDER BY id").to_a

    db.execute("DELETE FROM seed_users")
    Tina4.seed_orm(SeedTestUser, count: 3, seed: 42)
    second_run = db.fetch("SELECT first_name, last_name FROM seed_users ORDER BY id").to_a

    first_run.zip(second_run).each do |r1, r2|
      expect(r1[:first_name]).to eq(r2[:first_name])
      expect(r1[:last_name]).to eq(r2[:last_name])
    end
  end

  it "seeds zero records with count: 0" do
    count = Tina4.seed_orm(SeedTestUser, count: 0, seed: 42)
    expect(count).to eq(0)
  end

  it "returns 0 when no database" do
    Tina4.bind_database(nil)
    count = Tina4.seed_orm(SeedTestUser, count: 5)
    expect(count).to eq(0)
  end
end

# ===================================================================
# seed_table Tests
# ===================================================================

RSpec.describe "Tina4.seed_table" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seeder_table_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE IF NOT EXISTS raw_test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, score INTEGER)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "seeds correct number of records" do
    count = Tina4.seed_table("raw_test", { name: :string, score: :integer }, count: 10)
    expect(count).to eq(10)

    result = db.fetch_one("SELECT count(*) as cnt FROM raw_test")
    expect(result[:cnt]).to eq(10)
  end

  it "supports overrides" do
    Tina4.seed_table("raw_test", { name: :string, score: :integer }, count: 5, overrides: { score: 99 })

    results = db.fetch("SELECT score FROM raw_test")
    results.each do |row|
      expect(row[:score]).to eq(99)
    end
  end

  it "clears before seeding" do
    Tina4.seed_table("raw_test", { name: :string }, count: 10)
    Tina4.seed_table("raw_test", { name: :string }, count: 3, clear: true)

    result = db.fetch_one("SELECT count(*) as cnt FROM raw_test")
    expect(result[:cnt]).to eq(3)
  end
end

# ===================================================================
# seed_batch Tests
# ===================================================================

RSpec.describe "Tina4.seed_batch" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seed_batch_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE IF NOT EXISTS seed_users (id INTEGER PRIMARY KEY AUTOINCREMENT, first_name TEXT, last_name TEXT, email TEXT, age INTEGER DEFAULT 0, balance REAL DEFAULT 0.0, bio TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS seed_categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, description TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS seed_products (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, price REAL DEFAULT 0.0, category_id INTEGER, status TEXT)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "seeds a single class" do
    results = Tina4.seed_batch([
      { orm_class: SeedTestUser, count: 7, seed: 42 }
    ])

    expect(results["SeedTestUser"]).to eq(7)
  end

  it "seeds multiple classes" do
    results = Tina4.seed_batch([
      { orm_class: SeedTestUser, count: 5, seed: 1 },
      { orm_class: SeedTestCategory, count: 3, seed: 2 }
    ])

    expect(results["SeedTestUser"]).to eq(5)
    expect(results["SeedTestCategory"]).to eq(3)
  end

  it "clears in reverse order" do
    Tina4.seed_orm(SeedTestUser, count: 20, clear: true, seed: 1)

    results = Tina4.seed_batch([
      { orm_class: SeedTestUser, count: 3, seed: 99 }
    ], clear: true)

    expect(results["SeedTestUser"]).to eq(3)
    result = db.fetch_one("SELECT count(*) as cnt FROM seed_users")
    expect(result[:cnt]).to eq(3)
  end

  it "supports overrides" do
    Tina4.seed_batch([
      { orm_class: SeedTestCategory, count: 5, overrides: { name: "Test" }, seed: 42 }
    ])

    results = db.fetch("SELECT name FROM seed_categories")
    results.each do |row|
      expect(row[:name]).to eq("Test")
    end
  end
end

# ===================================================================
# Auto-Discovery Tests
# ===================================================================

RSpec.describe "Tina4.seed_dir (auto-discovery)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seed_discovery") }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it "handles non-existent folder gracefully" do
    expect { Tina4.seed_dir(seed_folder: "/tmp/nonexistent_seeds_999") }.not_to raise_error
  end

  it "handles empty folder gracefully" do
    expect { Tina4.seed_dir(seed_folder: tmp_dir) }.not_to raise_error
  end

  it "skips files starting with _" do
    File.write(File.join(tmp_dir, "_helper.rb"), 'raise "Should not be loaded"')
    expect { Tina4.seed_dir(seed_folder: tmp_dir) }.not_to raise_error
  end

  it "runs files in sorted order" do
    tracker = File.join(tmp_dir, "order.txt")

    %w[002_second 001_first 003_third].each do |name|
      File.write(File.join(tmp_dir, "#{name}.rb"), <<~RUBY)
        File.open("#{tracker}", "a") { |f| f.puts "#{name}" }
      RUBY
    end

    Tina4.seed_dir(seed_folder: tmp_dir)

    order = File.read(tracker).strip.split("\n")
    expect(order).to eq(%w[001_first 002_second 003_third])
  end

  it "catches errors in seed files" do
    File.write(File.join(tmp_dir, "001_broken.rb"), 'raise "test error"')
    expect { Tina4.seed_dir(seed_folder: tmp_dir) }.not_to raise_error
  end
end

# ===================================================================
# Large Batch / Edge Cases
# ===================================================================

RSpec.describe "FakeData edge cases" do
  it "FakeData holds its invariants across 1000 calls" do
    fake = Tina4::FakeData.new(seed: 1)
    1000.times do
      # name is "First Last" (two-part, space-joined)
      name = fake.name
      expect(name).to include(" ")
      # email is well-formed: has a local part, an @, and a domain from the list
      email = fake.email
      expect(email).to include("@")
      local, domain = email.split("@", 2)
      expect(local).not_to be_empty
      expect(Tina4::FakeData::DOMAINS).to include(domain)
      # integer stays inside the documented default 0..10_000 range
      expect(fake.integer).to be_between(0, 10_000)
      # sentence is capitalized and period-terminated
      sentence = fake.sentence
      expect(sentence[0]).to match(/[A-Z]/)
      expect(sentence).to end_with(".")
      # json_data is a Hash with 2..5 keys (its documented default shape)
      data = fake.json_data
      expect(data).to be_a(Hash)
      expect(data.length).to be_between(2, 5)
    end
  end

  it "generates mostly unique emails" do
    fake = Tina4::FakeData.new(seed: 42)
    emails = Set.new(200.times.map { fake.email })
    expect(emails.length).to be > 150
  end

  describe "large batch" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_seeder_large") }
    let(:db_path) { File.join(tmp_dir, "test.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

    before(:each) do
      Tina4.bind_database(db)
      db.execute("CREATE TABLE IF NOT EXISTS seed_users (id INTEGER PRIMARY KEY AUTOINCREMENT, first_name TEXT, last_name TEXT, email TEXT, age INTEGER DEFAULT 0, balance REAL DEFAULT 0.0, bio TEXT)")
    end

    after(:each) do
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    it "seeds 200 records" do
      count = Tina4.seed_orm(SeedTestUser, count: 200, seed: 42)
      expect(count).to eq(200)
    end
  end
end

# ── run_seeds (folder runner, renamed from seed) ─────────────────

RSpec.describe "Tina4.run_seeds" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_run_seeds_test") }
  let(:seeds_dir) { File.join(tmp_dir, "seeds") }

  before(:each) do
    FileUtils.mkdir_p(seeds_dir)
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  it "is defined as a class method on Tina4" do
    expect(Tina4).to respond_to(:run_seeds)
  end

  it "no longer exposes Tina4.seed as the folder runner" do
    # Tina4.seed as a folder-runner must be removed to avoid name collision
    # with Python/PHP/Node's seed(n) PRNG-seed API. No alias allowed.
    expect(Tina4).not_to respond_to(:seed)
  end

  it "logs info when seeds folder does not exist" do
    missing = File.join(tmp_dir, "nope")
    expect { Tina4.run_seeds(seed_folder: missing) }.not_to raise_error
  end

  it "loads and executes seed files in the folder" do
    File.write(
      File.join(seeds_dir, "001_flag.rb"),
      "$tina4_run_seeds_flag = (($tina4_run_seeds_flag || 0) + 1)\n"
    )
    $tina4_run_seeds_flag = 0
    Tina4.run_seeds(seed_folder: seeds_dir)
    expect($tina4_run_seeds_flag).to eq(1)
  end

  it "skips files starting with underscore" do
    File.write(File.join(seeds_dir, "_skip.rb"), "$tina4_skip_flag = true\n")
    $tina4_skip_flag = false
    Tina4.run_seeds(seed_folder: seeds_dir)
    expect($tina4_skip_flag).to be false
  end

  it "accepts clear: keyword without raising" do
    expect { Tina4.run_seeds(seed_folder: seeds_dir, clear: false) }.not_to raise_error
  end
end

# ===================================================================
# SEEDING FULL OVERHAUL — lock-in tests (engine-agnostic SQLite)
# Mirrors tests/test_seeder_overhaul.py from the Python master.
# ===================================================================

# Model whose `email` column has a UNIQUE constraint in the table DDL, so a
# repeated value violates the constraint (used to exercise P1 error handling).
class SeedUniqueEmail < Tina4::ORM
  table_name "seed_unique_emails"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :email
end

# FK-related models for topological ordering (P4a).
class SeedAuthor < Tina4::ORM
  table_name "seed_authors"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class SeedBook < Tina4::ORM
  table_name "seed_books"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  foreign_key_field :author_id, references: SeedAuthor
end

RSpec.describe "Seeding overhaul — P1 error handling" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seed_overhaul") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    # email UNIQUE so the SECOND identical override row violates the constraint.
    db.execute("CREATE TABLE IF NOT EXISTS seed_unique_emails (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "test_summary_shape — SeedSummary exposes seeded/failed/errors + int contract" do
    summary = Tina4.seed_orm(SeedUniqueEmail, count: 3, seed: 1)
    expect(summary.seeded).to eq(3)
    expect(summary.failed).to eq(0)
    expect(summary.errors).to eq([])
    # Hash-style + dict-style access
    expect(summary[:seeded]).to eq(3)
    expect(summary["failed"]).to eq(0)
    expect(summary.to_h).to eq({ seeded: 3, failed: 0, errors: [] })
    # Backward-compatible int contract
    expect(summary).to eq(3)
    expect(summary.to_i).to eq(3)
  end

  it "test_constraint_violation_does_not_crash_and_is_not_silent" do
    # Force every row to the same email -> first inserts, rest violate UNIQUE.
    summary = nil
    expect {
      summary = Tina4.seed_orm(
        SeedUniqueEmail, count: 5, clear: true, seed: 1,
        overrides: { email: "dup@example.com" }
      )
    }.not_to raise_error

    expect(summary.failed).to be >= 1            # NOT silently all-success
    expect(summary.seeded).to be < 5             # at least one row skipped
    expect(summary.seeded + summary.failed).to eq(5)
    expect(summary.errors.length).to eq(summary.failed)
    expect(summary.errors.first).to include(:row, :message)
  end

  it "test_strict_reraises_on_first_failure" do
    expect {
      Tina4.seed_orm(
        SeedUniqueEmail, count: 5, clear: true, strict: true, seed: 1,
        overrides: { email: "dup@example.com" }
      )
    }.to raise_error(StandardError)

    # Strict re-raises on the FIRST failure: row 0 inserted, row 1 raised.
    result = db.fetch_one("SELECT count(*) as cnt FROM seed_unique_emails")
    expect(result[:cnt]).to eq(1)
  end

  it "test_partial_success_counts — good rows seeded, bad rows counted" do
    # 1 unique email succeeds, then 4 duplicate-email rows fail.
    emails = ["unique1@example.com"] + Array.new(4) { "same@example.com" }
    idx = -1
    summary = Tina4.seed_orm(
      SeedUniqueEmail, count: 5, clear: true,
      overrides: { email: ->(_f) { idx += 1; emails[idx] } }
    )
    expect(summary.seeded).to eq(2)   # unique1 + first 'same'
    expect(summary.failed).to eq(3)   # remaining 3 'same' rows
  end
end

RSpec.describe "Seeding overhaul — P2 idempotency (seed_table clear)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seed_idempotency") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE IF NOT EXISTS idem_test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, score INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS idem_pk (code INTEGER PRIMARY KEY, label TEXT)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "test_clear_avoids_duplicates_on_rerun" do
    Tina4.seed_table("idem_test", { name: :string, score: :integer }, count: 10, clear: true)
    first = db.fetch_one("SELECT count(*) as cnt FROM idem_test")[:cnt]

    Tina4.seed_table("idem_test", { name: :string, score: :integer }, count: 10, clear: true)
    second = db.fetch_one("SELECT count(*) as cnt FROM idem_test")[:cnt]

    expect(first).to eq(10)
    expect(second).to eq(10)   # clear prevented duplicates on the re-run
  end

  it "test_clear_prevents_unique_pk_violation" do
    # A fixed non-auto PK collides on the second run unless we clear first.
    counter = 0
    pk_gen = ->(_f) { counter += 1 }
    run = lambda do
      counter = 0
      Tina4.seed_table(
        "idem_pk", { code: :integer, label: :string },
        count: 5, clear: true, overrides: { code: pk_gen }
      )
    end

    s1 = run.call
    s2 = run.call
    expect(s1.failed).to eq(0)
    expect(s2.failed).to eq(0)   # clear truncated before the second run
    expect(db.fetch_one("SELECT count(*) as cnt FROM idem_pk")[:cnt]).to eq(5)
  end
end

RSpec.describe "Seeding overhaul — P3 reproducibility" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seed_repro") }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it "test_same_seed_identical_data — FakeData same seed → identical sequence" do
    a = Tina4::FakeData.new(seed: 7)
    b = Tina4::FakeData.new(seed: 7)
    rows_a = Array.new(20) { [a.name, a.email, a.integer] }
    rows_b = Array.new(20) { [b.name, b.email, b.integer] }
    expect(rows_a).to eq(rows_b)
  end

  it "test_seed_orm_seed_param_reproducible — same seed → identical rows across two DBs" do
    paths = [File.join(tmp_dir, "a.db"), File.join(tmp_dir, "b.db")]
    captured = paths.map do |p|
      db = Tina4::Database.new("sqlite:///" + p)
      Tina4.bind_database(db)
      db.execute("CREATE TABLE IF NOT EXISTS seed_users (id INTEGER PRIMARY KEY AUTOINCREMENT, first_name TEXT, last_name TEXT, email TEXT, age INTEGER DEFAULT 0, balance REAL DEFAULT 0.0, bio TEXT)")
      Tina4.seed_orm(SeedTestUser, count: 5, clear: true, seed: 12345)
      rows = db.fetch("SELECT first_name, last_name, email FROM seed_users ORDER BY id").to_a
      db.close
      rows
    end

    expect(captured[0]).to eq(captured[1])
  end
end

RSpec.describe "Seeding overhaul — P4a FK ordering" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_seed_fk") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    # SQLite enforces FKs when PRAGMA foreign_keys=ON. The Ruby sqlite driver
    # enables it on connect; assert it so the test is a real FK guard.
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("CREATE TABLE IF NOT EXISTS seed_authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS seed_books (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, author_id INTEGER REFERENCES seed_authors(id))")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "test_wrong_declared_order_still_seeds_parents_first" do
    # Pass the models in the WRONG order (child before parent). Topo-sort must
    # seed authors first, then books referencing real author ids — no FK
    # violation, no orphan.
    results = Tina4.seed_models([SeedBook, SeedAuthor], count: 5, clear: true, seed: 3)

    expect(results["SeedAuthor"].failed).to eq(0)
    expect(results["SeedBook"].failed).to eq(0)
    expect(results["SeedAuthor"].seeded).to eq(5)
    expect(results["SeedBook"].seeded).to eq(5)

    # Every book references a real author (no orphans).
    orphans = db.fetch_one(
      "SELECT count(*) as cnt FROM seed_books b LEFT JOIN seed_authors a ON b.author_id = a.id WHERE a.id IS NULL"
    )[:cnt]
    expect(orphans).to eq(0)
  end

  it "test_clear_runs_in_reverse_topo_order" do
    # Seed once, then re-seed with clear: true. The clear must remove children
    # (books) BEFORE parents (authors) so the parent delete doesn't trip the
    # FK constraint — no error, and the re-run lands clean counts.
    Tina4.seed_models([SeedAuthor, SeedBook], count: 4, clear: true, seed: 1)

    expect {
      Tina4.seed_models([SeedAuthor, SeedBook], count: 4, clear: true, seed: 2)
    }.not_to raise_error

    expect(db.fetch_one("SELECT count(*) as cnt FROM seed_authors")[:cnt]).to eq(4)
    expect(db.fetch_one("SELECT count(*) as cnt FROM seed_books")[:cnt]).to eq(4)
  end
end
