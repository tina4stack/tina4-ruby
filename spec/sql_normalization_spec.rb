# frozen_string_literal: true

# Tina4 Ruby -- v3.13.12 SQL normalization + implicit binding fix.
#
# Two checks:
#
#   1. ``Tina4::Database.strip_trailing_semicolons`` strips trailing
#      ; and whitespace, leaves internal ;s alone.
#   2. ``Tina4::ORM.db`` falls through to ``auto_discover_db`` when
#      neither @db nor ``Tina4.database`` is set — using
#      ``TINA4_DATABASE_URL`` from the environment.

require "spec_helper"
require "tempfile"

RSpec.describe "v3.13.12 SQL normalization + ORM binding" do
  describe "Tina4::Database.strip_trailing_semicolons" do
    it "leaves clean SQL unchanged" do
      expect(Tina4::Database.strip_trailing_semicolons("SELECT 1")).to eq("SELECT 1")
    end

    it "strips a single trailing semicolon" do
      expect(Tina4::Database.strip_trailing_semicolons("SELECT 1;")).to eq("SELECT 1")
    end

    it "strips trailing whitespace and semicolons" do
      expect(Tina4::Database.strip_trailing_semicolons("SELECT 1   ;   ")).to eq("SELECT 1")
    end

    it "strips multiple trailing semicolons" do
      expect(Tina4::Database.strip_trailing_semicolons("SELECT 1;;;")).to eq("SELECT 1")
    end

    it "strips newline + semicolon combos" do
      expect(Tina4::Database.strip_trailing_semicolons("SELECT 1\n;\n")).to eq("SELECT 1")
    end

    it "leaves an empty string unchanged" do
      expect(Tina4::Database.strip_trailing_semicolons("")).to eq("")
    end

    it "leaves nil unchanged" do
      expect(Tina4::Database.strip_trailing_semicolons(nil)).to be_nil
    end

    it "leaves internal semicolons in literals alone" do
      expect(Tina4::Database.strip_trailing_semicolons("SELECT ';' AS x;")).to eq("SELECT ';' AS x")
    end
  end

  describe "fetch survives a trailing ; on user SQL" do
    let(:db_file) { Tempfile.new(["tina4_sql_norm", ".db"]).tap(&:close).path }
    let(:db) { Tina4::Database.new("sqlite://#{db_file}") }

    before do
      db.execute("CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      5.times { |i| db.execute("INSERT INTO widgets (name) VALUES (?)", ["widget-#{i}"]) }
    end

    after do
      db.close rescue nil
      File.unlink(db_file) if File.exist?(db_file)
    end

    it "fetch with trailing ; returns rows" do
      # Pre-v3.13.12: SQLite throws "near ';': syntax error" because
      # the driver's apply_limit appends LIMIT 100 OFFSET 0 after the ;
      result = db.fetch("SELECT * FROM widgets;")
      expect(result.records.length).to eq(5)
    end

    it "fetch_one with trailing ; returns the first row" do
      row = db.fetch_one("SELECT * FROM widgets WHERE id = ?;", [1])
      expect(row).not_to be_nil
      expect(row[:name]).to eq("widget-0")
    end

    it "fetch with double trailing ; works" do
      result = db.fetch("SELECT * FROM widgets;;")
      expect(result.records.length).to eq(5)
    end

    it "clean SQL is unaffected" do
      result = db.fetch("SELECT * FROM widgets WHERE name = ?", ["widget-2"])
      expect(result.records.length).to eq(1)
      expect(result.records[0][:name]).to eq("widget-2")
    end
  end

  describe "Tina4::ORM.db auto-discovery from TINA4_DATABASE_URL" do
    before do
      # Snapshot + clear so we can simulate "fresh app boot".
      @saved_url = ENV["TINA4_DATABASE_URL"]
      @saved_database = Tina4.database
      Tina4.bind_database(nil)
    end

    after do
      Tina4.bind_database(@saved_database)
      if @saved_url
        ENV["TINA4_DATABASE_URL"] = @saved_url
      else
        ENV.delete("TINA4_DATABASE_URL")
      end
    end

    it "falls through to TINA4_DATABASE_URL when neither @db nor Tina4.database is set" do
      # Use a sqlite tempfile so we don't depend on PG/MySQL being up.
      tmp = Tempfile.new(["tina4_orm_implicit", ".db"]).tap(&:close)
      ENV["TINA4_DATABASE_URL"] = "sqlite://#{tmp.path}"

      # Reset any per-class @db; using a fresh anonymous class so the
      # spec doesn't depend on whichever models happen to be loaded.
      klass = Class.new(Tina4::ORM)
      expect(klass.db).not_to be_nil
      expect(klass.db).to be_a(Tina4::Database)

      Tina4.database.close rescue nil
      File.unlink(tmp.path) if File.exist?(tmp.path)
    end

    it "returns nil when TINA4_DATABASE_URL is not set" do
      ENV.delete("TINA4_DATABASE_URL")
      klass = Class.new(Tina4::ORM)
      expect(klass.db).to be_nil
    end
  end

  describe "fetch_all returns ALL rows by default (v3.13.12)" do
    let(:db_file) { Tempfile.new(["tina4_fetch_all", ".db"]).tap(&:close).path }
    let(:db) { Tina4::Database.new("sqlite://#{db_file}") }

    before do
      db.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER)")
      # 150 rows — bigger than the legacy silent-truncation default of 100
      150.times { |i| db.execute("INSERT INTO rows (n) VALUES (?)", [i]) }
    end

    after do
      db.close rescue nil
      File.unlink(db_file) if File.exist?(db_file)
    end

    it "fetch_all returns ALL 150 rows by default" do
      # Pre-v3.13.12: silently truncated to 100 because fetch_all defaulted
      # to limit: 100. v3.13.12 changed the default to limit: nil → no LIMIT.
      rows = db.fetch_all("SELECT * FROM rows ORDER BY n")
      expect(rows.length).to eq(150)
    end

    it "fetch_all with explicit limit still caps" do
      rows = db.fetch_all("SELECT * FROM rows ORDER BY n", limit: 10)
      expect(rows.length).to eq(10)
    end

    it "fetch_all with explicit limit and offset returns the slice" do
      rows = db.fetch_all("SELECT * FROM rows ORDER BY n", limit: 5, offset: 20)
      expect(rows.length).to eq(5)
      expect(rows.first[:n]).to eq(20)
      expect(rows.last[:n]).to eq(24)
    end

    it "fetch_all composes with the trailing-; strip" do
      rows = db.fetch_all("SELECT * FROM rows ORDER BY n;")
      expect(rows.length).to eq(150)
    end
  end
end
