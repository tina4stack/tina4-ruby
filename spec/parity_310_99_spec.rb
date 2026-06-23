# frozen_string_literal: true

require "spec_helper"

# ── ORM model with snake_case fields for to_h case tests ─────────────────
class ParityArticle < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  string_field :image_url, length: 255
  string_field :created_at
end

# ── ORM subclass with no explicit auto_map setting ───────────────────────
class ParityDefault < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

# ── ORM subclass that exercises what auto_map drives: column<->field
#    mapping. field_mapping is {ruby_attribute => db_column} (the canonical
#    Python-master direction, "python_attribute": "db_column"). Here the DB
#    stores a snake_case column `created_by` while the model exposes a
#    camelCase-style attribute `createdBy`, so loading a row proves the
#    mapping is actually performed (not just that a config getter exists).
class ParityMapped < Tina4::ORM
  table_name "parity_mapped"
  self.field_mapping = { "createdBy" => "created_by" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :createdBy
end

RSpec.describe "v3.10.99 parity tests" do
  # =========================================================================
  # ORM — to_h case: :snake (default)
  # =========================================================================

  describe "ORM#to_h case: snake (default)" do
    it "returns snake_case keys by default" do
      article = ParityArticle.new(
        title: "Hello",
        image_url: "https://example.com/img.png",
        created_at: "2024-01-15"
      )
      hash = article.to_h
      expect(hash).to have_key(:image_url)
      expect(hash).to have_key(:created_at)
      expect(hash[:image_url]).to eq("https://example.com/img.png")
      expect(hash[:created_at]).to eq("2024-01-15")
    end
  end

  # =========================================================================
  # ORM — to_h case: :camel
  # =========================================================================

  describe "ORM#to_h case: camel" do
    it "returns camelCase keys when case is 'camel'" do
      article = ParityArticle.new(
        title: "Hello",
        image_url: "https://example.com/img.png",
        created_at: "2024-01-15"
      )
      hash = article.to_h(case: "camel")
      expect(hash).to have_key(:imageUrl)
      expect(hash).to have_key(:createdAt)
      expect(hash[:imageUrl]).to eq("https://example.com/img.png")
      expect(hash[:createdAt]).to eq("2024-01-15")
      # snake_case keys should not be present
      expect(hash).not_to have_key(:image_url)
      expect(hash).not_to have_key(:created_at)
    end
  end

  # =========================================================================
  # ORM — auto_map defaults to true
  # =========================================================================

  describe "ORM auto_map default" do
    # auto_map defaults to true, and what that default DRIVES is the
    # column<->field mapping: a row read out of the database lands its DB
    # column value on the model's mapped Ruby attribute. We prove the real
    # behaviour against a live SQLite database — create the table, INSERT a
    # row into the snake_case `created_by` column, then load it back via
    # find_by_id and assert the value surfaced on the camelCase `createdBy`
    # attribute. (A plain getter assertion exercised no logic.)
    let(:tmp_dir) { Dir.mktmpdir("tina4_parity_310_99") }
    let(:db_path) { File.join(tmp_dir, "test.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

    before(:each) do
      Tina4.bind_database(db)
      db.execute(
        "CREATE TABLE IF NOT EXISTS parity_mapped " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, created_by TEXT)"
      )
    end

    after(:each) do
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    it "defaults to true and drives the DB-column to Ruby-attribute mapping on load" do
      # Default is on (not explicitly set on ParityMapped).
      expect(ParityMapped.auto_map).to be true

      # Write through the real driver into the snake_case DB column.
      result = db.execute("INSERT INTO parity_mapped (created_by) VALUES (?)", ["Andre"])
      id = db.get_last_id || result.first[:id]

      # Read it back: the mapping must move the `created_by` column value onto
      # the mapped `createdBy` attribute (and the unmapped `id` lands straight).
      loaded = ParityMapped.find_by_id(id)
      expect(loaded).not_to be_nil
      expect(loaded.createdBy).to eq("Andre")
      expect(loaded.id).to eq(id)

      # And the round-trip out of to_h preserves the mapped attribute key.
      expect(loaded.to_h[:createdBy]).to eq("Andre")
    end
  end

  # =========================================================================
  # Frond — replace filter with Hash argument
  # =========================================================================

  describe "Frond replace filter with Hash arg" do
    let(:engine) { Tina4::Frond.new }

    it "applies multiple replacements from a hash" do
      template = '{{ val|replace({"T": " ", "-": "/"}) }}'
      data = { "val" => "2024-01-15T10:30:00" }
      result = engine.render_string(template, data)
      expect(result).to eq("2024/01/15 10:30:00")
    end
  end

  # =========================================================================
  # Frond — replace filter with positional args
  # =========================================================================

  describe "Frond replace filter with positional args" do
    let(:engine) { Tina4::Frond.new }

    it "replaces old with new using two string arguments" do
      template = '{{ val|replace("hello", "world") }}'
      data = { "val" => "say hello" }
      result = engine.render_string(template, data)
      expect(result).to eq("say world")
    end
  end

  # =========================================================================
  # ServiceRunner — background registration
  # =========================================================================

  describe "ServiceRunner background registration" do
    before(:each) do
      Tina4::ServiceRunner.clear!
    end

    after(:each) do
      Tina4::ServiceRunner.clear!
    end

    it "registers a task without starting a server" do
      Tina4::ServiceRunner.register("parity_test", interval: 60) do |ctx|
        # no-op
      end

      services = Tina4::ServiceRunner.list
      expect(services.length).to eq(1)
      expect(services.first[:name]).to eq("parity_test")
      expect(services.first[:running]).to be false
    end
  end
end
