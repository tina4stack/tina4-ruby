# frozen_string_literal: true

# Real coverage for the migration-dialect fix (parity with the Python master's
# tests/test_migration_dialect_firebird.py).
#
# The scaffolding used to emit SQLite-only DDL (TEXT, REAL, created_at TEXT,
# CREATE TABLE IF NOT EXISTS) that Firebird rejects (-607 on TEXT). The fix is two
# parts, both exercised here:
#
#   * the generator emits portable canonical types (VARCHAR(255) for strings,
#     TIMESTAMP for datetimes/created_at, REAL kept for floats), and
#   * Tina4::SQLTranslator.ddl_types completes the APPLY-time translation, wired
#     into the Firebird/MSSQL/MySQL drivers right after auto_increment_syntax
#     (mirroring the Python master's _translate_sql). So TEXT -> BLOB SUB_TYPE
#     TEXT, REAL -> DOUBLE PRECISION, and IF NOT EXISTS is stripped on Firebird
#     (and TIMESTAMP -> DATETIME2/DATETIME on MSSQL/MySQL) as the DDL is executed.
#
# No mocks: the round-trip runs against a LIVE Firebird (TINA4_TEST_FIREBIRD_URL)
# and applies the REALLY-generated migration DDL, then inserts and reads a row.
# The translation-unit tests are pure functions over strings (no dependency, no
# double). The generator test runs the REAL `generate migration` CLI path.

require "spec_helper"
require "tina4/cli"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe "Migration dialect translation (ddl_types)" do
  # ── Pure-function translation — the DRY core that fixes migrations AND
  #    ORM.create_table AND hand-written DDL. No dependency, no double.
  describe "Tina4::SQLTranslator.ddl_types" do
    let(:raw) do
      "CREATE TABLE IF NOT EXISTS t (\n" \
        "  id INTEGER PRIMARY KEY,\n" \
        "  bio TEXT,\n" \
        "  price REAL,\n" \
        "  due TIMESTAMP\n)"
    end

    it "firebird: maps TEXT/REAL and strips IF NOT EXISTS" do
      out = Tina4::SQLTranslator.ddl_types(raw, "firebird")
      expect(out).not_to include("IF NOT EXISTS")
      expect(out).to include("BLOB SUB_TYPE TEXT")
      expect(out).to include("DOUBLE PRECISION")
      # No bare TEXT/REAL survive (BLOB SUB_TYPE TEXT is not a bare TEXT).
      expect(out.upcase.scan("TEXT").length).to eq(out.upcase.scan("SUB_TYPE TEXT").length)
      expect(out.upcase).not_to match(/\bREAL\b/)
    end

    it "firebird: leaves an existing BLOB SUB_TYPE TEXT intact (no double-map)" do
      ddl = "CREATE TABLE t (bio BLOB SUB_TYPE TEXT, note TEXT)"
      out = Tina4::SQLTranslator.ddl_types(ddl, "firebird")
      # Both columns end as exactly one BLOB SUB_TYPE TEXT — the pre-existing one
      # must not become BLOB SUB_TYPE BLOB SUB_TYPE TEXT.
      expect(out.scan("BLOB SUB_TYPE TEXT").length).to eq(2)
      expect(out).not_to include("SUB_TYPE BLOB")
    end

    it "mssql: strips IF NOT EXISTS and maps TIMESTAMP -> DATETIME2" do
      out = Tina4::SQLTranslator.ddl_types(raw, "mssql")
      expect(out).not_to include("IF NOT EXISTS")
      expect(out).to include("DATETIME2")
      expect(out.upcase).not_to match(/\bTIMESTAMP\b/)
    end

    it "mysql: maps TIMESTAMP -> DATETIME" do
      out = Tina4::SQLTranslator.ddl_types(raw, "mysql")
      expect(out.upcase).to include("DATETIME")
      expect(out.upcase).not_to match(/\bTIMESTAMP\b/)
    end

    it "is DDL-gated: a SELECT that merely mentions TEXT/REAL is never rewritten" do
      q = "SELECT id, note FROM t WHERE kind = 'TEXT' AND ratio > 0.5"
      expect(Tina4::SQLTranslator.ddl_types(q, "firebird")).to eq(q)
    end

    it "is DDL-gated: an INSERT is never rewritten" do
      ins = "INSERT INTO t (kind) VALUES ('TEXT')"
      expect(Tina4::SQLTranslator.ddl_types(ins, "firebird")).to eq(ins)
    end

    it "tolerates leading -- comment lines before the CREATE (migration header)" do
      commented = "-- Migration: x\n-- Created: now\n\n#{raw}"
      out = Tina4::SQLTranslator.ddl_types(commented, "firebird")
      expect(out).to include("BLOB SUB_TYPE TEXT")
      expect(out).not_to include("IF NOT EXISTS")
    end

    it "leaves postgres/sqlite DDL unchanged (only firebird/mssql/mysql translate)" do
      expect(Tina4::SQLTranslator.ddl_types(raw, "postgres")).to eq(raw)
      expect(Tina4::SQLTranslator.ddl_types(raw, "sqlite")).to eq(raw)
    end
  end

  # ── The REAL generator emits portable canonical types. ──────────────────
  describe "generated migration DDL" do
    around(:each) do |example|
      Dir.mktmpdir("tina4_dialect_gen") do |dir|
        @tmp_dir = dir
        Dir.chdir(dir) { example.run }
      end
    end

    it "emits VARCHAR(255)/TIMESTAMP (not SQLite-only TEXT), keeps IF NOT EXISTS, floats stay REAL" do
      sql = generated_create_sql(@tmp_dir)
      expect(sql).to include("name VARCHAR(255)")
      expect(sql).not_to include("name TEXT")          # not SQLite-only TEXT
      expect(sql).to include("created_at TIMESTAMP")
      expect(sql).not_to include("created_at TEXT")    # Firebird -607 guard
      expect(sql).to include("due TIMESTAMP")          # datetime field -> TIMESTAMP
      expect(sql).to include("price REAL")             # float stays REAL (task spec)
      expect(sql).to include("CREATE TABLE IF NOT EXISTS") # kept in the FILE
    end
  end

  # ── The REAL proof: the generated migration DDL applies on a live Firebird and
  #    a row round-trips — where the old TEXT/REAL/IF NOT EXISTS/AUTOINCREMENT
  #    DDL raised -607/-104/"Token unknown AUTOINCREMENT".
  describe "live Firebird round-trip", :firebird do
    fb_url = ENV["TINA4_TEST_FIREBIRD_URL"].to_s

    around(:each) do |example|
      skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)" if fb_url.empty?
      Dir.mktmpdir("tina4_dialect_fb") do |dir|
        @tmp_dir = dir
        Dir.chdir(dir) { example.run }
      end
    end

    it "applies the REALLY-generated migration and round-trips a row" do
      sql = generated_create_sql(@tmp_dir)
      db = connect_firebird_or_skip(fb_url)
      begin
        drop_probe(db)
        # db.execute -> the Firebird driver's auto_increment_syntax + ddl_types
        # make the SQLite-canonical generated DDL Firebird-legal on the way in.
        db.execute(sql)
        db.execute(
          "INSERT INTO dialect_probe (id, name, bio, price, active, due) " \
          "VALUES (?, ?, ?, ?, ?, ?)",
          [1, "Alice", "a long bio", 9.99, 1, "2026-01-02 03:04:05"]
        )
        row = db.fetch_one("SELECT id, name, bio, price FROM dialect_probe WHERE id = ?", [1])
        expect(row).not_to be_nil
        expect(field(row, "name")).to eq("Alice")
        expect(field(row, "bio").to_s).to eq("a long bio")          # BLOB SUB_TYPE TEXT round-trip
        expect(field(row, "price").to_f).to be_within(1e-6).of(9.99) # DOUBLE PRECISION round-trip
      ensure
        drop_probe(db)
        db.close if db.respond_to?(:close)
      end
    end
  end

  # ── helpers (real, no doubles) ─────────────────────────────────────────

  # Run the REAL `generate migration` CLI path and return its CREATE TABLE
  # statement, exactly like the Python master's _generated_create_sql.
  def generated_create_sql(tmp_dir)
    silence_stdout do
      Tina4::CLI.new.run(
        ["generate", "migration", "create_dialect_probe",
         "--fields", "name:string,bio:text,price:float,active:bool,due:datetime"]
      )
    end
    up = Dir.glob(File.join(tmp_dir, "migrations", "*.sql")).reject { |f| f.include?("down") }.first
    raise "no generated migration found in #{tmp_dir}/migrations" if up.nil?

    # The generator writes exactly one CREATE TABLE per up-file.
    File.read(up).split(";").find { |stmt| stmt.upcase.include?("CREATE TABLE") }
  end

  def connect_firebird_or_skip(url)
    Tina4::Database.new(url, username: "SYSDBA", password: "masterkey")
  rescue LoadError => e
    # The `fb` gem's C extension links libfbclient; a host without it cannot run
    # this. A genuine absent-platform-library exclusion, NOT a mock.
    skip "fb gem / libfbclient unavailable [needs:absent-lib=libfbclient]: #{e.message}"
  end

  def drop_probe(db)
    db.execute("DROP TABLE dialect_probe")
  rescue StandardError
    nil # first run has nothing to drop
  end

  # Firebird folds unquoted identifiers to UPPERCASE and the driver hands back
  # lowercased SYMBOL keys — normalise so the assertion is key-shape agnostic.
  def field(row, name)
    return nil if row.nil?

    row.each { |k, v| return v if k.to_s.downcase == name }
    nil
  end

  def silence_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
