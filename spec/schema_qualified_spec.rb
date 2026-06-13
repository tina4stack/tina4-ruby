# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Tina4 Ruby — v3.13.14 (#48) schema-qualified table introspection.
#
# A model whose table name is schema/catalog-qualified was invisible to
# table_exists?/columns/tables — Database#table_exists? scanned tables (always
# the default schema) and matched the dotted string as one flat name. SQLite's
# "schema" is an ATTACH alias, which needs no external server, so it gives the
# schema-qualified path real coverage here. PostgreSQL/MySQL/MSSQL use the same
# split_schema helper (unit-tested below); their live behaviour is covered when
# a container is present.
RSpec.describe "Schema-qualified table introspection (#48)" do
  describe "Tina4::Drivers::SchemaSplit#split_schema" do
    # Mix the module into a bare object to exercise the shared helper directly.
    let(:helper) { Object.new.extend(Tina4::Drivers::SchemaSplit) }

    it "returns [nil, name] for a bare name" do
      expect(helper.split_schema("users")).to eq([nil, "users"])
    end

    it "splits a schema-qualified name on the first dot" do
      expect(helper.split_schema("gift_cards.gift_card")).to eq(["gift_cards", "gift_card"])
    end

    it "splits on the FIRST dot only" do
      expect(helper.split_schema("a.b.c")).to eq(["a", "b.c"])
    end

    it "coerces symbols to strings" do
      expect(helper.split_schema(:users)).to eq([nil, "users"])
    end
  end

  describe "SQLite attached-database integration (no server needed)" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:main_path) { File.join(tmpdir, "main.db") }
    let(:att_path)  { File.join(tmpdir, "extra.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + main_path) }

    before do
      db.execute("ATTACH DATABASE '#{att_path}' AS extra")
      db.execute("CREATE TABLE extra.widget (id INTEGER PRIMARY KEY, name TEXT, is_deleted INTEGER DEFAULT 0)")
      db.execute("CREATE TABLE local_only (id INTEGER PRIMARY KEY)")
    end

    after do
      db.close rescue nil
      FileUtils.rm_rf(tmpdir)
    end

    it "finds a table in an attached schema" do
      expect(db.table_exists?("extra.widget")).to be true
    end

    it "returns false for an absent table in an attached schema" do
      expect(db.table_exists?("extra.nope")).to be false
    end

    it "still finds a bare table in the main schema" do
      expect(db.table_exists?("local_only")).to be true
    end

    it "introspects columns of a table in an attached schema" do
      cols = db.columns("extra.widget")
      names = cols.map { |c| c[:name] }
      expect(names).to eq(%w[id name is_deleted])
      id_col = cols.find { |c| c[:name] == "id" }
      expect(id_col[:primary_key]).to be true
    end
  end
end
