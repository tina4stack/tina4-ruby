# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe "Migration v3 features" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_migration_v3") }
  let(:db_path) { File.join(tmp_dir, "migration.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }
  let(:migrations_dir) { File.join(tmp_dir, "migrations") }
  let(:migration) { Tina4::Migration.new(db, migrations_dir: migrations_dir) }

  before(:each) do
    FileUtils.mkdir_p(migrations_dir)
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe "tracking table" do
    it "creates tracking table on init" do
      migration  # trigger lazy let
      expect(db.table_exists?("tina4_migration")).to be true
    end

    it "tracking table has batch column" do
      migration  # trigger lazy let
      cols = db.columns("tina4_migration")
      col_names = cols.map { |c| c[:name] }
      expect(col_names).to include("batch")
    end
  end

  describe "#migrate with SQL files" do
    it "runs pending SQL migrations" do
      File.write(File.join(migrations_dir, "20240101000001_create_users.sql"), <<~SQL)
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
      SQL

      results = migration.migrate
      expect(results.length).to eq(1)
      expect(results.first[:status]).to eq("success")
      expect(db.table_exists?("users")).to be true
    end

    it "tracks migration with batch number" do
      File.write(File.join(migrations_dir, "20240101000001_first.sql"), <<~SQL)
        CREATE TABLE first_table (id INTEGER PRIMARY KEY);
      SQL

      migration.migrate

      result = db.fetch_one("SELECT batch FROM tina4_migration WHERE migration_name = ?",
                            ["20240101000001_first.sql"])
      expect(result[:batch]).to eq(1)
    end

    it "increments batch for subsequent runs" do
      File.write(File.join(migrations_dir, "20240101000001_batch1.sql"), <<~SQL)
        CREATE TABLE batch1 (id INTEGER PRIMARY KEY);
      SQL

      migration.migrate

      File.write(File.join(migrations_dir, "20240101000002_batch2.sql"), <<~SQL)
        CREATE TABLE batch2 (id INTEGER PRIMARY KEY);
      SQL

      # Need a new Migration instance to pick up new files
      migration2 = Tina4::Migration.new(db, migrations_dir: migrations_dir)
      migration2.migrate

      result = db.fetch_one("SELECT batch FROM tina4_migration WHERE migration_name = ?",
                            ["20240101000002_batch2.sql"])
      expect(result[:batch]).to eq(2)
    end

    it "does not re-run completed migrations" do
      File.write(File.join(migrations_dir, "20240101000001_once.sql"), <<~SQL)
        CREATE TABLE once_table (id INTEGER PRIMARY KEY);
      SQL

      migration.migrate
      results = migration.migrate
      expect(results).to be_empty
    end
  end

  describe "#migrate with Ruby files" do
    it "runs Ruby migration up method" do
      File.write(File.join(migrations_dir, "20240101000001_create_products.rb"), <<~RUBY)
        class CreateProducts < Tina4::MigrationBase
          def up(db)
            db.execute("CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price INTEGER)")
          end

          def down(db)
            db.execute("DROP TABLE IF EXISTS products")
          end
        end
      RUBY

      results = migration.migrate
      expect(results.length).to eq(1)
      expect(results.first[:status]).to eq("success")
      expect(db.table_exists?("products")).to be true
    end
  end

  describe "#rollback" do
    it "rolls back SQL migrations" do
      File.write(File.join(migrations_dir, "20240101000001_create_rollback_test.sql"), <<~SQL)
        CREATE TABLE rollback_test (id INTEGER PRIMARY KEY);
      SQL
      File.write(File.join(migrations_dir, "20240101000001_create_rollback_test.down.sql"), <<~SQL)
        DROP TABLE IF EXISTS rollback_test;
      SQL

      migration.migrate
      expect(db.table_exists?("rollback_test")).to be true

      results = migration.rollback
      expect(results.length).to eq(1)
      expect(results.first[:status]).to eq("rolled_back")
      expect(db.table_exists?("rollback_test")).to be false
    end

    it "rolls back Ruby migrations" do
      File.write(File.join(migrations_dir, "20240101000001_create_rb_rollback.rb"), <<~RUBY)
        class CreateRbRollback < Tina4::MigrationBase
          def up(db)
            db.execute("CREATE TABLE rb_rollback (id INTEGER PRIMARY KEY, val TEXT)")
          end

          def down(db)
            db.execute("DROP TABLE IF EXISTS rb_rollback")
          end
        end
      RUBY

      migration.migrate
      expect(db.table_exists?("rb_rollback")).to be true

      migration.rollback
      expect(db.table_exists?("rb_rollback")).to be false
    end

    it "rolls back only the last batch" do
      File.write(File.join(migrations_dir, "20240101000001_batch_a.sql"), <<~SQL)
        CREATE TABLE batch_a (id INTEGER PRIMARY KEY);
      SQL

      migration.migrate

      File.write(File.join(migrations_dir, "20240101000002_batch_b.sql"), <<~SQL)
        CREATE TABLE batch_b (id INTEGER PRIMARY KEY);
      SQL
      File.write(File.join(migrations_dir, "20240101000002_batch_b.down.sql"), <<~SQL)
        DROP TABLE IF EXISTS batch_b;
      SQL

      migration2 = Tina4::Migration.new(db, migrations_dir: migrations_dir)
      migration2.migrate

      expect(db.table_exists?("batch_a")).to be true
      expect(db.table_exists?("batch_b")).to be true

      migration2.rollback(1)
      expect(db.table_exists?("batch_a")).to be true
      expect(db.table_exists?("batch_b")).to be false
    end
  end

  describe "#status" do
    it "returns completed and pending migrations" do
      File.write(File.join(migrations_dir, "20240101000001_done.sql"), "SELECT 1;")
      File.write(File.join(migrations_dir, "20240101000002_todo.sql"), "SELECT 2;")

      migration.migrate  # Runs both

      File.write(File.join(migrations_dir, "20240101000003_new.sql"), "SELECT 3;")
      migration2 = Tina4::Migration.new(db, migrations_dir: migrations_dir)
      status = migration2.status

      expect(status[:completed]).to include("20240101000001_done.sql")
      expect(status[:completed]).to include("20240101000002_todo.sql")
      expect(status[:pending]).to include("20240101000003_new.sql")
    end
  end

  describe "#create" do
    it "creates a Ruby migration file" do
      filepath = migration.create("add_users_table", "ruby")
      expect(File.exist?(filepath)).to be true
      content = File.read(filepath)
      expect(content).to include("class AddUsersTable")
      expect(content).to include("< Tina4::MigrationBase")
      expect(content).to include("def up(db = nil)")
      expect(content).to include("def down(db = nil)")
    end

    it "uses timestamp in filename" do
      filepath = migration.create("test_migration")
      basename = File.basename(filepath)
      # Default kind is "sql" (parity with Python/PHP/Node)
      expect(basename).to match(/\A\d{14}_test_migration\.sql\z/)
    end
  end

  describe "alias #run" do
    it "run is an alias for migrate" do
      expect(migration.method(:run)).to eq(migration.method(:migrate))
    end
  end
end

# Regression spec for the engine-aware migration tracking-table fix.
#
# Before the fix, ensure_tracking_table emitted SQLite-only DDL on every
# non-Firebird engine: `id INTEGER PRIMARY KEY AUTOINCREMENT` (via the bare
# `id INTEGER PRIMARY KEY` + AUTOINCREMENT semantics) — actually it emitted
# `id INTEGER PRIMARY KEY` for the else branch, but the auto-increment keyword
# variants (AUTOINCREMENT) are SQLite-specific. On PostgreSQL the CREATE blew
# up with `syntax error at or near "AUTOINCREMENT"` so constructing the
# Migration runner (which calls ensure_tracking_table) threw, making migrations
# unusable on PG. The fix makes the non-Firebird branch engine-aware:
# PostgreSQL -> SERIAL, MySQL -> AUTO_INCREMENT, MSSQL -> IDENTITY, SQLite ->
# AUTOINCREMENT (unchanged).
#
# This boots a real PostgreSQL (Docker at localhost:55432) and asserts the
# runner constructs, the tracking table is created, a real migration applies a
# table + seeds a row, and a tracking row was recorded with an auto-assigned id.
#
# The spec skips automatically when the pg gem is missing or the database is
# unreachable, so CI without PostgreSQL just no-ops (same gate as the other PG
# specs).

PGMIG_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PGMIG_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
PGMIG_USER = ENV.fetch("TINA4_TEST_PG_USER", "tina4")
PGMIG_PASS = ENV.fetch("TINA4_TEST_PG_PASS", "tina4")
PGMIG_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pgmig_reachable?
  TCPSocket.new(PGMIG_HOST, PGMIG_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def pgmig_gem_available?
  require "pg"
  true
rescue LoadError
  false
end

RSpec.describe "Migration tracking table on real PostgreSQL" do
  before(:all) do
    @skip_reason = if !pgmig_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pgmig_reachable?
                     "PostgreSQL not reachable at #{PGMIG_HOST}:#{PGMIG_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PGMIG_HOST}:#{PGMIG_PORT}/#{PGMIG_DB}",
      username: PGMIG_USER, password: PGMIG_PASS
    )
    # DROP the tracking table AND the target table first so the create path
    # actually runs (this is the call that used to throw AUTOINCREMENT).
    @db.execute("DROP TABLE IF EXISTS mig_rb_widget")
    @db.execute("DROP TABLE IF EXISTS tina4_migration")

    @tmp_dir = Dir.mktmpdir("tina4_migration_pg")
    @migrations_dir = File.join(@tmp_dir, "migrations")
    FileUtils.mkdir_p(@migrations_dir)
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS mig_rb_widget")
      @db.execute("DROP TABLE IF EXISTS tina4_migration")
    ensure
      @db.close rescue nil
      FileUtils.rm_rf(@tmp_dir) if @tmp_dir
    end
  end

  it "constructs the runner (creates the tracking table) without an AUTOINCREMENT syntax error" do
    # This is the call that used to throw `syntax error at or near "AUTOINCREMENT"`.
    expect { Tina4::Migration.new(@db, migrations_dir: @migrations_dir) }.not_to raise_error
    expect(@db.table_exists?("tina4_migration")).to be(true)
  end

  it "emits a SERIAL auto-increment PK on the tracking table (not AUTOINCREMENT)" do
    Tina4::Migration.new(@db, migrations_dir: @migrations_dir)
    col = @db.columns("tina4_migration").find { |c| c[:name] == "id" }
    expect(col).not_to be_nil
    expect(col[:type]).to eq("integer")
    # A SERIAL column is backed by a sequence -> default is nextval(...).
    expect(col[:default].to_s).to include("nextval")
  end

  it "runs a real migration: creates mig_rb_widget, seeds a row, records a tracking row with an auto-assigned id" do
    File.write(File.join(@migrations_dir, "20240101000001_create_mig_rb_widget.sql"), <<~SQL)
      CREATE TABLE mig_rb_widget (id SERIAL PRIMARY KEY, name VARCHAR(50));
      INSERT INTO mig_rb_widget (name) VALUES ('bolt');
    SQL

    migration = Tina4::Migration.new(@db, migrations_dir: @migrations_dir)
    results = migration.migrate

    expect(results.length).to eq(1)
    expect(results.first[:status]).to eq("success")

    # tina4_migration exists, mig_rb_widget exists.
    expect(@db.table_exists?("tina4_migration")).to be(true)
    expect(@db.table_exists?("mig_rb_widget")).to be(true)

    # The seeded row is readable.
    row = @db.fetch_one("SELECT name FROM mig_rb_widget WHERE name = ?", ["bolt"])
    expect(row).not_to be_nil
    expect(row[:name]).to eq("bolt")

    # A tracking row was recorded with an auto-assigned (SERIAL) id.
    tracked = @db.fetch_one(
      "SELECT id, migration_name, batch, passed FROM tina4_migration WHERE migration_name = ?",
      ["20240101000001_create_mig_rb_widget.sql"]
    )
    expect(tracked).not_to be_nil
    expect(tracked[:id].to_i).to be > 0
    expect(tracked[:batch].to_i).to eq(1)
    expect(tracked[:passed].to_i).to eq(1)
  end
end
