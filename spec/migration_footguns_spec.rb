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

  # ── [#54] a ';' inside a comment or string literal must NOT split a statement ──

  describe "split_sql_statements is comment- and string-aware (#54)" do
    it "does not fragment on a ';' inside a -- line comment" do
      sql = <<~SQL
        CREATE TABLE users (
            id INTEGER PRIMARY KEY,   -- drop then re-add; old way
            name TEXT NOT NULL
        );
      SQL
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.length).to eq(1), "';' inside a -- comment fragmented the statement: #{stmts.inspect}"
      expect(stmts[0]).to include("id INTEGER PRIMARY KEY")
      expect(stmts[0]).to include("name TEXT NOT NULL")
      expect(stmts[0]).not_to include("old way"), "line comment text was not stripped"
    end

    it "does not fragment on a ';' inside a /* */ block comment" do
      sql = "CREATE TABLE t (id INTEGER /* a; b; c */, name TEXT);"
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.length).to eq(1), stmts.inspect
      expect(stmts[0]).not_to include("a; b; c"), "block comment text was not stripped"
    end

    it "does not split on a ';' inside a string literal" do
      sql = "INSERT INTO t (v) VALUES ('a;b;c'); INSERT INTO t (v) VALUES ('d');"
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.length).to eq(2), "';' inside a string literal split the statement: #{stmts.inspect}"
      expect(stmts[0]).to include("'a;b;c'")
    end

    it "does not treat '--' inside a string literal as a comment" do
      sql = "INSERT INTO t (v) VALUES ('a--b'); INSERT INTO t (v) VALUES ('c');"
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.length).to eq(2), stmts.inspect
      expect(stmts[0]).to include("'a--b'")
    end

    it "honours the '' doubled-quote escape so a later ';' still splits" do
      sql = "INSERT INTO t (v) VALUES ('O''Brien; Jr'); SELECT 1;"
      stmts = migration.send(:split_sql_statements, sql, ";")
      expect(stmts.length).to eq(2), stmts.inspect
      expect(stmts[0]).to include("'O''Brien; Jr'")
    end

    it "applies a real migration whose CREATE TABLE has a ';' in a -- comment" do
      Dir.mktmpdir("tina4_mig54") do |dir|
        db = Tina4::Database.new("sqlite:///" + File.join(dir, "mig54.db"))
        mig_dir = File.join(dir, "migrations")
        FileUtils.mkdir_p(mig_dir)
        File.write(File.join(mig_dir, "000001_create_users.sql"), <<~SQL)
          CREATE TABLE users (
              id INTEGER PRIMARY KEY,   -- drop then re-add; old way
              name TEXT NOT NULL
          );
        SQL
        ran = Tina4::Migration.new(db, migrations_dir: mig_dir).migrate
        # migrate returns [{name:, status:}] — the file applied successfully.
        expect(ran.length).to eq(1)
        expect(ran[0][:name]).to eq("000001_create_users.sql")
        expect(ran[0][:status]).to eq("success")
        expect(db.table_exists?("users")).to be(true)
        # The table is real and usable (count is key-shape-agnostic via values.first).
        db.execute("INSERT INTO users (name) VALUES (?)", ["Alice"])
        count = db.fetch("SELECT COUNT(*) AS c FROM users").records[0].values.first
        expect(count).to eq(1)
        db.close
      end
    end
  end
end
