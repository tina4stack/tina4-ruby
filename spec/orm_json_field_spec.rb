# frozen_string_literal: true

require "spec_helper"

# JSON-document column model. `json_field` maps a Hash/Array attribute to a
# JSON column: the value is JSON-encoded on write and JSON-decoded back on read
# (parity with the Python master's JSONField).
class JsonDoc < Tina4::ORM
  table_name "jsondoc"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  json_field :payload
  json_field :tags
end

# Model with a mutable default — locks in that two instances never alias the
# same default object (the Python master needs an explicit deepcopy for this).
class JsonDefaultDoc < Tina4::ORM
  table_name "jsondefaultdoc"
  integer_field :id, primary_key: true, auto_increment: true
  json_field :meta, default: {}
end

# NO MOCKS: every example runs against a REAL SQLite database on disk,
# exercising the full path create_table -> save (serialize) -> fetch ->
# from_hash (parse). The engine-aware DDL type and native-JSON read
# normalisation (PostgreSQL JSONB / MySQL JSON) are covered by the gated
# cross-engine suite in CI; the string-backed path is fully exercised here.
RSpec.describe "ORM JSONField" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_json_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    JsonDoc.create_table
    JsonDefaultDoc.create_table
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe "round trip" do
    it "round-trips a Hash as a Hash" do
      doc = JsonDoc.new(name: "click", payload: { "x" => 1, "nested" => { "a" => [1, 2, 3] } })
      expect(doc.save).to eq(doc)

      got = JsonDoc.select_one("SELECT * FROM jsondoc WHERE id = ?", [doc.id])
      expect(got.payload).to be_a(Hash)                     # not a JSON string
      expect(got.payload).to eq({ "x" => 1, "nested" => { "a" => [1, 2, 3] } })
      expect(got.payload["nested"]["a"]).to eq([1, 2, 3])
    end

    it "round-trips an Array as an Array" do
      doc = JsonDoc.new(name: "tagged", tags: %w[a b c])
      doc.save

      got = JsonDoc.select_one("SELECT * FROM jsondoc WHERE id = ?", [doc.id])
      expect(got.tags).to eq(%w[a b c])
    end

    it "round-trips nil as nil" do
      doc = JsonDoc.new(name: "empty")
      doc.save

      got = JsonDoc.select_one("SELECT * FROM jsondoc WHERE id = ?", [doc.id])
      expect(got.payload).to be_nil
      expect(got.tags).to be_nil
    end

    it "replaces the JSON on update" do
      doc = JsonDoc.new(name: "v", payload: { "v" => 1 })
      doc.save

      doc.payload = { "v" => 2, "changed" => true }
      doc.save

      got = JsonDoc.select_one("SELECT * FROM jsondoc WHERE id = ?", [doc.id])
      expect(got.payload).to eq({ "v" => 2, "changed" => true })
    end

    it "preserves unicode and special characters" do
      body = { "emoji" => "cafe ☕", "quote" => 'he said "hi"', "slash" => "a/b\\c" }
      doc = JsonDoc.new(name: "u", payload: body)
      doc.save

      got = JsonDoc.select_one("SELECT * FROM jsondoc WHERE id = ?", [doc.id])
      expect(got.payload).to eq(body)
    end
  end

  describe "engine-aware DDL" do
    it "maps a JSON column to TEXT on SQLite" do
      row = db.fetch_one("SELECT sql FROM sqlite_master WHERE type='table' AND name='jsondoc'")
      ddl = row[:sql].upcase
      # Two JSON columns, both TEXT on SQLite (no native JSON type).
      expect(ddl).to include("PAYLOAD TEXT")
      expect(ddl).to include("TAGS TEXT")
    end
  end

  describe "validation / hydration" do
    it "parses a raw JSON string on read" do
      # A raw JSON string in the column (as a text-backed engine returns) is
      # decoded to a Hash by from_hash on hydration.
      db.execute("INSERT INTO jsondoc (name, payload) VALUES (?, ?)", ["raw", '{"from": "string"}'])
      got = JsonDoc.select_one("SELECT * FROM jsondoc WHERE name = ?", ["raw"])
      expect(got.payload).to eq({ "from" => "string" })
    end

    it "fails loud on a non-serialisable value" do
      # Float::NAN cannot be JSON-encoded -> save fails loud (returns false),
      # rolls back, and records the cause. Nothing is persisted.
      doc = JsonDoc.new(name: "bad", payload: { "n" => Float::NAN })
      expect(doc.save).to be false
      expect(doc.get_error).not_to be_nil
      expect(JsonDoc.select_one("SELECT * FROM jsondoc WHERE name = ?", ["bad"])).to be_nil
    end
  end

  describe "default isolation" do
    it "never shares a mutable default between instances" do
      a = JsonDefaultDoc.new
      b = JsonDefaultDoc.new
      a.meta["only_a"] = true
      expect(b.meta).to eq({}), "instances must not alias the same default Hash"
    end
  end
end
