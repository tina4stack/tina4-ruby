# frozen_string_literal: true

# Shared migration contract -- feature 15 (OWNER-DECISIONS.md Batch 4,
# feature doc 015-migrations.md, MIG-DEC-01/02/03). Real engines only
# (SQLite, PostgreSQL, MySQL, MSSQL, Firebird 5) -- no mocks, no fakes. The
# SAME case names are proven in all four frameworks; the shared fixture is
# tina4-documentation/plan/v3/fixtures/migrations_contract.json.
#
# MIG-DEC-02: rollback_migration used to Tina4::Log.warning a missing down
# artifact and still fall through to the unconditional _remove_migration_record
# -- the tracking row was silently dropped even though nothing was reversed.
# It now RAISES (wrapped in its own transaction, mirroring the Python
# reference model), which skips the delete.
# failed_or_missing_down_does_not_drop_ledger proves the row survives.
#
# MIG-DEC-03: firebird_mssql_create_add_idempotency_real replaces the
# migration_footguns_spec.rb FakeDB ("MIG-FBMSSQL-MOCK") with REAL Firebird 5
# / REAL MSSQL, modelled on tina4-php's MigrationFootgunsLiveEngineTest
# ("NO DOUBLES").
#
# migrate_status_prints_without_crashing drives the REAL CLI entry point
# (exe/tina4ruby, a real child process -- mirrors spec/cli_test_exit_code_spec.rb)
# -- Ruby's migrate:status was NOT flagged broken by the audit (only Python +
# PHP were), so this is a NEW regression lock on already-correct behaviour,
# not a fix.
#
# Mutation-proved on the .99 lab, then restored: reinstate the
# Tina4::Log.warning-then-delete rollback path ->
# failed_or_missing_down_does_not_drop_ledger goes RED (the row vanishes).
#
# Env contract (identical to the write-path/pgprovider/mysqlprovider/
# mssqlprovider/firebirdprovider runners): TINA4_TEST_PG_HOST/_PORT/_USERNAME/
# _PASSWORD/_DB (default 127.0.0.1:55432, tina4/tina4); TINA4_TEST_MYSQL_HOST/
# _PORT/_USERNAME/_PASSWORD/_DB (default 127.0.0.1:3306, tina4/tina4);
# TINA4_TEST_MSSQL_HOST/_PORT/_USERNAME/_PASSWORD/_DB (default 127.0.0.1:1433,
# sa/TinaSQL123!Secure); TINA4_TEST_FIREBIRD_URL (a live Firebird 5 URL; unset
# means the Firebird cases skip locally -- the lab gate's own preflight FATALs
# if it is unreachable there, a skipped required engine is a ghost).

require "spec_helper"
require "open3"
require "socket"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "Tina4 migration contract (feature 15)" do
  # Unique-prefixed constants -- a bare constant inside RSpec.describe leaks
  # onto Object and can collide with another spec file's.
  MIGCTR_PG_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  MIGCTR_PG_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  MIGCTR_PG_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  MIGCTR_PG_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  MIGCTR_PG_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  MIGCTR_MYSQL_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MIGCTR_MYSQL_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MIGCTR_MYSQL_USER = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
  MIGCTR_MYSQL_PASS = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  MIGCTR_MYSQL_DB   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

  MIGCTR_MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
  MIGCTR_MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  MIGCTR_MSSQL_USER = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
  MIGCTR_MSSQL_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
  MIGCTR_MSSQL_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

  def tcp_reachable?(host, port, timeout: 1.0)
    Socket.tcp(host, port, connect_timeout: timeout) { true }
  rescue StandardError
    false
  end

  def mysql_or_skip
    skip "MySQL not reachable at #{MIGCTR_MYSQL_HOST}:#{MIGCTR_MYSQL_PORT} (set TINA4_TEST_MYSQL_*)" \
      unless tcp_reachable?(MIGCTR_MYSQL_HOST, MIGCTR_MYSQL_PORT)
    Tina4::Database.new(
      "mysql://#{MIGCTR_MYSQL_HOST}:#{MIGCTR_MYSQL_PORT}/#{MIGCTR_MYSQL_DB}",
      username: MIGCTR_MYSQL_USER, password: MIGCTR_MYSQL_PASS
    )
  end

  def pg_or_skip
    skip "PostgreSQL not reachable at #{MIGCTR_PG_HOST}:#{MIGCTR_PG_PORT} (set TINA4_TEST_PG_*)" \
      unless tcp_reachable?(MIGCTR_PG_HOST, MIGCTR_PG_PORT)
    Tina4::Database.new(
      "postgres://#{MIGCTR_PG_HOST}:#{MIGCTR_PG_PORT}/#{MIGCTR_PG_DB}",
      username: MIGCTR_PG_USER, password: MIGCTR_PG_PASS
    )
  end

  def mssql_or_skip
    skip "MSSQL not reachable at #{MIGCTR_MSSQL_HOST}:#{MIGCTR_MSSQL_PORT} (set TINA4_TEST_MSSQL_*)" \
      unless tcp_reachable?(MIGCTR_MSSQL_HOST, MIGCTR_MSSQL_PORT)
    Tina4::Database.new(
      "mssql://#{MIGCTR_MSSQL_HOST}:#{MIGCTR_MSSQL_PORT}/#{MIGCTR_MSSQL_DB}",
      username: MIGCTR_MSSQL_USER, password: MIGCTR_MSSQL_PASS
    )
  end

  def firebird_url
    (ENV["TINA4_TEST_FIREBIRD_URL"] || "").strip
  end

  def firebird_or_skip
    url = firebird_url
    skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)" if url.empty?
    db = Tina4::Database.new(url, username: "SYSDBA", password: "masterkey")
    db.fetch_one("SELECT 1 AS N FROM RDB$DATABASE")
    db
  rescue StandardError => e
    skip "Firebird cannot connect at #{url} -- #{e.message}"
  end

  around(:each) do |example|
    Dir.mktmpdir("tina4_mig_contract") do |dir|
      @mig_dir = File.join(dir, "migrations")
      FileUtils.mkdir_p(@mig_dir)
      example.run
    end
  end

  # Best-effort delete of a stale tina4_migration row. On a genuinely fresh
  # database/engine the tracking table itself may not exist yet (nothing has
  # called migrate() there before) -- that is not a real failure, just
  # nothing to clean up. NOTE: no db.commit here -- Ruby's Database#commit
  # unconditionally forwards to the driver (no "nothing open" no-op guard),
  # and a bare COMMIT with no matching start_transaction is a hard error on
  # MSSQL/tiny_tds ("no corresponding BEGIN TRANSACTION"); autoCommit already
  # commits each standalone execute (see mssqlprovider_contract_spec.rb's own
  # established convention -- it never calls .commit after a bare .execute).
  def clean_ledger_row(db, migration_name)
    db.execute("DELETE FROM tina4_migration WHERE migration_name = ?", [migration_name])
  rescue StandardError
    nil
  end

  def write_migration(name, sql)
    File.write(File.join(@mig_dir, name), sql)
  end

  # ── ledger-row-commits-atomically-with-ddl ──────────────────────────────

  it "ledger_row_commits_atomically_with_ddl (SQLite happy path)" do
    write_migration("000001_create_widgets.sql", "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")
    db = Tina4::Database.new("sqlite://:memory:")
    begin
      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      results = m.migrate
      expect(results.map { |r| r[:status] }).to eq(["success"])
      expect(db.table_exists?("widgets")).to be true

      row = db.fetch_one(
        "SELECT migration_name, batch FROM tina4_migration WHERE migration_name = ?",
        ["000001_create_widgets.sql"]
      )
      expect(row).not_to be_nil, "ledger row was not written alongside the DDL"
      expect(row[:batch].to_i).to eq(1)
    ensure
      db.close
    end
  end

  it "ledger_row_commits_atomically_with_ddl (MySQL: never precedes/survives a failed DDL)" do
    db = mysql_or_skip
    table = "mig_rb_mysql_atomic"
    name = "000001_mysql_atomic.sql"
    begin
      db.execute("DROP TABLE IF EXISTS #{table}")
      clean_ledger_row(db, name)

      write_migration(name, "CREATE TABLE #{table} (id INT PRIMARY KEY);\nTHIS IS NOT VALID SQL;")

      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      results = m.migrate
      expect(results.map { |r| r[:status] }).to eq(["failed"])

      expect(db.table_exists?(table)).to be(true), "precondition: MySQL DDL auto-commits, the table must exist"
      row = db.fetch_one("SELECT 1 AS x FROM tina4_migration WHERE migration_name = ?", [name])
      expect(row).to be_nil, "the ledger row must never be written for a failed migration, even on non-transactional DDL"
    ensure
      db.execute("DROP TABLE IF EXISTS #{table}")
      clean_ledger_row(db, name)
      db.close
    end
  end

  # ── midfile-failure-rolls-back-on-transactional-ddl ─────────────────────

  it "midfile_failure_rolls_back_on_transactional_ddl (PostgreSQL)" do
    db = pg_or_skip
    table = "mig_rb_pg_midfile"
    name = "000001_pg_midfile.sql"
    begin
      db.execute("DROP TABLE IF EXISTS #{table}")
      clean_ledger_row(db, name)

      write_migration(name, "CREATE TABLE #{table} (id SERIAL PRIMARY KEY, name VARCHAR(50));\nTHIS IS NOT VALID SQL;")

      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      results = m.migrate
      expect(results.map { |r| r[:status] }).to eq(["failed"])

      expect(db.table_exists?(table)).to be(false),
        "PostgreSQL DDL is transactional -- the earlier CREATE TABLE in the same failed file must roll back too"
      row = db.fetch_one("SELECT 1 AS x FROM tina4_migration WHERE migration_name = ?", [name])
      expect(row).to be_nil, "no ledger row for a fully-rolled-back file"
    ensure
      db.execute("DROP TABLE IF EXISTS #{table}")
      clean_ledger_row(db, name)
      db.close
    end
  end

  it "a multi-statement failure rolls back the DDL on SQLite too (CLAUDE.md atomicity claim)" do
    write_migration("000001_sqlite_midfile.sql", "CREATE TABLE good (id INTEGER);\nTHIS WILL FAIL;")
    db = Tina4::Database.new("sqlite://:memory:")
    begin
      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      results = m.migrate
      expect(results.map { |r| r[:status] }).to eq(["failed"])
      expect(db.table_exists?("good")).to be(false),
        "SQLite DDL is transactional -- a CREATE TABLE earlier in a failed file must roll back too"
    ensure
      db.close
    end
  end

  # ── migrate-status-prints-without-crashing ──────────────────────────────

  def run_cli(args, dir, url)
    env = {
      "TINA4_DATABASE_URL" => url,
      "TINA4_AUTO_MIGRATE" => "false",
      "TINA4_DEBUG" => nil,
      "TINA4_SECRET" => "mig-contract-spec-secret"
    }
    Open3.capture2e(env, RbConfig.ruby, EXE, *args, chdir: dir)
  end

  it "migrate_status_prints_without_crashing" do
    Dir.mktmpdir("tina4_mig_contract_status") do |project_dir|
      migrations = File.join(project_dir, "migrations")
      FileUtils.mkdir_p(migrations)
      db_path = File.join(project_dir, "status.db")
      url = "sqlite:///#{db_path}"

      File.write(File.join(migrations, "000001_create_accounts.sql"),
                 "CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT)")

      apply_out, apply_status = run_cli(["migrate"], project_dir, url)
      expect(apply_status.exitstatus).to eq(0), "setup: migrate must succeed before status is checked\n#{apply_out}"

      # A SECOND, still-pending migration so status prints BOTH branches.
      File.write(File.join(migrations, "000002_add_index.sql"),
                 "CREATE INDEX idx_accounts_name ON accounts (name)")

      out, status = run_cli(["migrate:status"], project_dir, url)

      expect(status.exitstatus).to eq(0), "migrate:status must exit 0 against a real migrated DB.\n#{out}"
      expect(out).not_to include("NoMethodError"), "a crash regressed:\n#{out}"
      expect(out).not_to include("undefined method"), "a crash regressed:\n#{out}"
      expect(out).to include("Completed:")
      expect(out).to include("000001_create_accounts.sql")
      expect(out).to include("Pending:")
      expect(out).to include("000002_add_index.sql")
      expect(out).to include("Completed: 1  Pending: 1")
    end
  end

  it "migrate_status_prints_without_crashing (nothing applied yet)" do
    Dir.mktmpdir("tina4_mig_contract_status_empty") do |project_dir|
      migrations = File.join(project_dir, "migrations")
      FileUtils.mkdir_p(migrations)
      db_path = File.join(project_dir, "status_empty.db")
      url = "sqlite:///#{db_path}"

      File.write(File.join(migrations, "000001_never_applied.sql"),
                 "CREATE TABLE never_applied (id INTEGER PRIMARY KEY)")

      out, status = run_cli(["migrate:status"], project_dir, url)

      expect(status.exitstatus).to eq(0), out
      expect(out).to include("000001_never_applied.sql")
      expect(out).to include("Completed: 0  Pending: 1")
    end
  end

  # ── failed-or-missing-down-does-not-drop-ledger ─────────────────────────

  it "failed_or_missing_down_does_not_drop_ledger (missing .down.sql)" do
    write_migration("000001_no_down.sql", "CREATE TABLE nd (id INTEGER)")
    db = Tina4::Database.new("sqlite://:memory:")
    begin
      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      m.migrate

      row_before = db.fetch_one(
        "SELECT migration_name FROM tina4_migration WHERE migration_name = ?",
        ["000001_no_down.sql"]
      )
      expect(row_before).not_to be_nil, "precondition: the migration must be recorded"

      expect { m.rollback }.to raise_error(/no \.down\.sql file found/)

      row_after = db.fetch_one(
        "SELECT migration_name FROM tina4_migration WHERE migration_name = ?",
        ["000001_no_down.sql"]
      )
      expect(row_after).not_to be_nil,
        "a missing .down.sql must RAISE, never silently drop the ledger row -- the schema is still there and must stay tracked"
      expect(db.table_exists?("nd")).to be true
    ensure
      db.close
    end
  end

  it "failed_or_missing_down_does_not_drop_ledger (failing .down.sql statement)" do
    write_migration("000001_bad_down.sql", "CREATE TABLE bd (id INTEGER)")
    write_migration("000001_bad_down.down.sql", "THIS IS NOT VALID SQL")
    db = Tina4::Database.new("sqlite://:memory:")
    begin
      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      m.migrate

      expect { m.rollback }.to raise_error(StandardError)

      row_after = db.fetch_one(
        "SELECT migration_name FROM tina4_migration WHERE migration_name = ?",
        ["000001_bad_down.sql"]
      )
      expect(row_after).not_to be_nil, "a FAILING down statement must also never drop the ledger row"
    ensure
      db.close
    end
  end

  # ── firebird-mssql-create-add-idempotency-real ──────────────────────────
  # NO DOUBLES. Replaces migration_footguns_spec.rb's FakeDB
  # (MIG-FBMSSQL-MOCK) -- modelled on tina4-php's MigrationFootgunsLiveEngineTest.

  it "firebird_mssql_create_add_idempotency_real (MSSQL CREATE TABLE)" do
    db = mssql_or_skip
    table = "nomock_mig_ctr_rb_mssql"
    begin
      db.execute("IF OBJECT_ID('#{table}','U') IS NOT NULL DROP TABLE #{table}")
      db.execute("CREATE TABLE #{table} (id INT)")
      expect(db.table_exists?(table)).to be(true), "precondition: the real engine must report the table"

      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      reason = m.send(:should_skip_create_table, "CREATE TABLE #{table} (id INT)")
      expect(reason).not_to be_nil, "a really-existing MSSQL table must make CREATE TABLE skip"
      expect(reason).to include(table)

      absent_reason = m.send(:should_skip_create_table, "CREATE TABLE nomock_mig_ctr_rb_absent (id INT)")
      expect(absent_reason).to be_nil, "an absent table must NOT be skipped -- the migration has to run"
    ensure
      db.execute("IF OBJECT_ID('#{table}','U') IS NOT NULL DROP TABLE #{table}")
      db.close
    end
  end

  it "firebird_mssql_create_add_idempotency_real (Firebird CREATE TABLE + ALTER ADD)" do
    db = firebird_or_skip
    table = "NOMOCK_MIG_CTR_RB"
    begin
      begin
        db.execute("DROP TABLE #{table}")
      rescue StandardError
        nil
      end
      db.execute("CREATE TABLE #{table} (id INTEGER NOT NULL PRIMARY KEY)")
      expect(db.table_exists?(table)).to be(true), "precondition: the real engine must report the table"

      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      reason = m.send(:should_skip_create_table, "CREATE TABLE #{table} (id INTEGER NOT NULL PRIMARY KEY)")
      expect(reason).not_to be_nil, "a really-existing Firebird table must make CREATE TABLE skip"

      # ALTER TABLE ... ADD idempotency (Firebird-only guard).
      db.execute("ALTER TABLE #{table} ADD extra_col VARCHAR(50)")
      add_reason = m.send(:should_skip_for_firebird, "ALTER TABLE #{table} ADD extra_col VARCHAR(50)")
      expect(add_reason).not_to be_nil, "a really-existing Firebird column must make ALTER ADD skip"
      expect(add_reason).to include("extra_col")

      absent_add_reason = m.send(:should_skip_for_firebird, "ALTER TABLE #{table} ADD never_added VARCHAR(10)")
      expect(absent_add_reason).to be_nil, "an absent column must NOT be skipped -- the ADD has to run"
    ensure
      begin
        db.execute("DROP TABLE #{table}")
      rescue StandardError
        nil
      end
      db.close
    end
  end

  it "should_skip_create_table does NOT skip on sqlite/postgres (IF NOT EXISTS engines)" do
    db = Tina4::Database.new("sqlite://:memory:")
    begin
      m = Tina4::Migration.new(db, migrations_dir: @mig_dir)
      reason = m.send(:should_skip_create_table, "CREATE TABLE anything (id INT)")
      expect(reason).to be_nil
    ensure
      db.close
    end
  end
end
