# frozen_string_literal: true

# Lock-in tests for the migration footgun fixes (v3.13.39) — mirrors
# tina4-python tests/test_migration_footguns.py.
#
# - [10] `//` delimiter no longer swallows a URL (`https://…`) as a stored-proc block.
# - [8]  discovery sort is numeric-aware (`9_` before `10_`).
# - [9]  CREATE TABLE is idempotent on engines lacking IF NOT EXISTS (Firebird/MSSQL).

require "spec_helper"

RSpec.describe "Tina4::Migration footguns" do
  # A migration instance with no real DB — the helpers under test never touch
  # @db except should_skip_create_table, which we exercise via a fake below.
  let(:migration) { Tina4::Migration.allocate.tap { |m| m.instance_variable_set(:@migrations_dir, "migrations") } }

  # Minimal fake DB for the CREATE TABLE idempotency guard.
  class FakeDB
    def initialize(engine, table_exists)
      @engine = engine
      @exists = table_exists
    end

    def get_database_type
      @engine
    end

    def table_exists?(_name)
      @exists
    end
  end

  # ── [10] `//` delimiter must not swallow a URL ──────────────────────────

  describe "split does not swallow a URL scheme" do
    it "keeps two INSERTs containing https:// as two statements" do
      sql = "INSERT INTO cfg (k, v) VALUES ('home', 'https://a.example.com');\n" \
            "INSERT INTO cfg (k, v) VALUES ('cb', 'https://b.example.com');"
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.length).to eq(2), "URL `//` was captured as a block, breaking split: #{stmts.inspect}"
      expect(stmts[0]).to include("https://a.example.com")
      expect(stmts[1]).to include("https://b.example.com")
    end

    it "still keeps a real // stored-proc block intact" do
      sql = "CREATE PROCEDURE foo() // BEGIN SELECT 1; SELECT 2; END //;"
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.any? { |s| s.include?("BEGIN SELECT 1; SELECT 2; END") }).to be(true), stmts.inspect
    end
  end

  # ── smart/curly quotes normalized so the SQL runs ───────────────────────

  describe "smart/curly quotes normalized before split" do
    it "normalizes smart quotes before splitting so the statement runs" do
      # Smart double quotes around an identifier + smart single quotes around a
      # value — as an editor/doc would produce. They must become straight ASCII
      # so the statement actually runs.
      sql = "CREATE TABLE “users” (name TEXT DEFAULT ‘guest’);"
      joined = migration.send(:split_sql_statements, sql, ";").join(" ")
      ["“", "”", "‘", "’", "′", "″"].each do |smart|
        expect(joined).not_to include(smart), "smart quote #{smart.inspect} survived"
      end
      expect(joined).to include('"users"')
      expect(joined).to include("'guest'")
    end

    it "leaves a plain statement with straight quotes unchanged" do
      # Straight quotes and ordinary apostrophe-free content are untouched.
      sql = "INSERT INTO t (v) VALUES ('plain');"
      expect(migration.send(:normalize_quotes, sql)).to eq(sql)
    end
  end

  # ── [8] numeric-aware discovery order ───────────────────────────────────

  describe "migration_sort_key is numeric-aware" do
    it "sorts 9_ before 10_ and unprefixed last" do
      names = ["10_b.sql", "9_a.sql", "2_x.sql", "alpha.sql"]
      sorted = names.sort_by { |n| migration.send(:migration_sort_key, n) }
      expect(sorted).to eq(["2_x.sql", "9_a.sql", "10_b.sql", "alpha.sql"])
    end
  end

  # ── [9] CREATE TABLE idempotency on Firebird/MSSQL ──────────────────────

  describe "should_skip_create_table" do
    def skip_reason(engine, exists, stmt)
      m = Tina4::Migration.allocate
      m.instance_variable_set(:@db, FakeDB.new(engine, exists))
      m.send(:should_skip_create_table, stmt)
    end

    it "skips on MSSQL when the table exists" do
      reason = skip_reason("mssql", true, "CREATE TABLE users (id INT)")
      expect(reason).to include("users")
    end

    it "skips on Firebird (quoted name) when the table exists" do
      reason = skip_reason("firebird", true, 'CREATE TABLE "Orders" (id INT)')
      expect(reason).to include("Orders")
    end

    it "does NOT skip when the table is absent" do
      expect(skip_reason("firebird", false, "CREATE TABLE users (id INT)")).to be_nil
    end

    it "does NOT skip on sqlite/postgres (IF NOT EXISTS engines)" do
      expect(skip_reason("sqlite", true, "CREATE TABLE users (id INT)")).to be_nil
      expect(skip_reason("postgres", true, "CREATE TABLE users (id INT)")).to be_nil
    end

    it "ignores a non-CREATE statement" do
      expect(skip_reason("mssql", true, "INSERT INTO users VALUES (1)")).to be_nil
    end
  end
end
