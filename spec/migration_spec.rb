# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Migration do
  let(:tmp_dir) { Dir.mktmpdir("tina4_mig_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }
  let(:mig_dir) { File.join(tmp_dir, "migrations") }
  let(:migration) { Tina4::Migration.new(db, migrations_dir: mig_dir) }

  after(:each) do
    db.close rescue nil
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#initialize" do
    it "creates migration tracking table" do
      migration # force lazy evaluation
      expect(db.table_exists?("tina4_migration")).to be true
    end
  end

  describe "#create" do
    it "creates migration files" do
      path = migration.create("add users table")
      expect(File.exist?(path)).to be true
      expect(File.basename(path)).to match(/\d{14}_add_users_table\.sql/)
    end

    it "creates migration with SQL comment header" do
      path = migration.create("add users table")
      content = File.read(path)
      expect(content).to include("-- Migration: add users table")
      expect(content).to include("-- Created:")
    end
  end

  describe "#run" do
    it "runs pending migrations" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_create_test.sql"),
                 "CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)")

      results = migration.run
      expect(results.length).to eq(1)
      expect(results[0][:status]).to eq("success")
      expect(db.table_exists?("test_table")).to be true
    end

    it "skips already completed migrations" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_create_test.sql"),
                 "CREATE TABLE test_table (id INTEGER PRIMARY KEY)")

      migration.run
      results = migration.run
      expect(results).to be_empty
    end

    it "handles migration errors" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_bad.sql"), "SELECT * FROM this_table_does_not_exist_xyz")

      results = migration.run
      expect(results[0][:status]).to eq("failed")
    end
  end

  describe "#status" do
    it "shows completed and pending migrations" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_first.sql"),
                 "CREATE TABLE first_table (id INTEGER PRIMARY KEY)")
      File.write(File.join(mig_dir, "000002_second.sql"),
                 "CREATE TABLE second_table (id INTEGER PRIMARY KEY)")

      migration.run
      status = migration.status
      expect(status[:completed].length).to eq(2)
      expect(status[:pending]).to be_empty
    end

    it "shows pending migrations before any run" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_pending.sql"),
                 "CREATE TABLE pending_table (id INTEGER PRIMARY KEY)")

      status = migration.status
      expect(status[:pending]).not_to be_empty
      expect(status[:completed]).to be_empty
    end

    it "shows mixed completed and pending" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_done.sql"),
                 "CREATE TABLE done_table (id INTEGER PRIMARY KEY)")
      migration.run

      File.write(File.join(mig_dir, "000002_todo.sql"),
                 "CREATE TABLE todo_table (id INTEGER PRIMARY KEY)")
      migration2 = Tina4::Migration.new(db, migrations_dir: mig_dir)
      status = migration2.status
      expect(status[:completed]).not_to be_empty
      expect(status[:pending]).not_to be_empty
    end
  end

  describe "#run with multiple migrations" do
    it "runs migrations in order" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_create_a.sql"),
                 "CREATE TABLE a_table (id INTEGER PRIMARY KEY)")
      File.write(File.join(mig_dir, "000002_create_b.sql"),
                 "CREATE TABLE b_table (id INTEGER PRIMARY KEY)")

      results = migration.run
      expect(results.length).to eq(2)
      expect(db.table_exists?("a_table")).to be true
      expect(db.table_exists?("b_table")).to be true
    end

    it "handles multi-statement SQL migration" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_multi.sql"),
                 "CREATE TABLE t1 (id INTEGER PRIMARY KEY);\nCREATE TABLE t2 (id INTEGER PRIMARY KEY);")

      results = migration.run
      expect(results.length).to eq(1)
      expect(db.table_exists?("t1")).to be true
      expect(db.table_exists?("t2")).to be true
    end

    it "runs nothing from empty migration directory" do
      FileUtils.mkdir_p(mig_dir)
      results = migration.run
      expect(results).to be_empty
    end

    it "handles missing migration directory" do
      missing_mig = Tina4::Migration.new(db, migrations_dir: File.join(tmp_dir, "nonexistent"))
      results = missing_mig.run
      expect(results).to be_empty
    end
  end

  describe "#create with various descriptions" do
    it "sanitizes special characters in description" do
      FileUtils.mkdir_p(mig_dir)
      path = migration.create("add email & phone fields!")
      expect(File.exist?(path)).to be true
      expect(File.basename(path)).to match(/add_email/)
    end

    it "creates the migrations directory if it does not exist" do
      new_mig_dir = File.join(tmp_dir, "new_migrations")
      new_migration = Tina4::Migration.new(db, migrations_dir: new_mig_dir)
      path = new_migration.create("test_migration")
      expect(Dir.exist?(new_mig_dir)).to be true
      expect(File.exist?(path)).to be true
    end

    it "uses timestamp format in filenames" do
      FileUtils.mkdir_p(mig_dir)
      path = migration.create("timestamp_test")
      basename = File.basename(path)
      expect(basename).to match(/\A\d{14}_/)
    end
  end

  describe "SQL with comments" do
    it "handles SQL with line comments" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_comments.sql"),
                 "-- Comment\nCREATE TABLE commented (id INTEGER PRIMARY KEY);\n-- Another comment\n")
      results = migration.run
      expect(results.length).to eq(1)
      expect(db.table_exists?("commented")).to be true
    end
  end

  describe "#get_applied / #get_applied_migrations" do
    it "returns empty array when no migrations have run" do
      expect(migration.get_applied).to eq([])
      expect(migration.get_applied_migrations).to eq([])
    end

    it "returns applied migration filenames after running" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_create_foo.sql"),
                 "CREATE TABLE foo (id INTEGER PRIMARY KEY)")
      migration.run
      expect(migration.get_applied).to include("000001_create_foo.sql")
      expect(migration.get_applied_migrations).to include("000001_create_foo.sql")
    end

    it "get_applied and get_applied_migrations return identical results" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_alias_test.sql"),
                 "CREATE TABLE alias_test (id INTEGER PRIMARY KEY)")
      migration.run
      expect(migration.get_applied).to eq(migration.get_applied_migrations)
    end
  end

  describe "#get_pending" do
    it "returns empty array when no migration files exist" do
      expect(migration.get_pending).to eq([])
    end

    it "lists pending migration filenames" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_pending_a.sql"),
                 "CREATE TABLE pending_a (id INTEGER PRIMARY KEY)")
      File.write(File.join(mig_dir, "000002_pending_b.sql"),
                 "CREATE TABLE pending_b (id INTEGER PRIMARY KEY)")
      expect(migration.get_pending).to include("000001_pending_a.sql", "000002_pending_b.sql")
    end

    it "does not list already-applied migrations" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_applied.sql"),
                 "CREATE TABLE applied_check (id INTEGER PRIMARY KEY)")
      File.write(File.join(mig_dir, "000002_still_pending.sql"),
                 "CREATE TABLE still_pending (id INTEGER PRIMARY KEY)")
      migration.run # applies both
      expect(migration.get_pending).to eq([])
    end
  end

  describe "#get_files" do
    it "returns empty array when migrations directory is empty" do
      FileUtils.mkdir_p(mig_dir)
      expect(migration.get_files).to eq([])
    end

    it "lists all migration files (excluding .down.sql)" do
      FileUtils.mkdir_p(mig_dir)
      File.write(File.join(mig_dir, "000001_up.sql"), "SELECT 1")
      File.write(File.join(mig_dir, "000001_up.down.sql"), "SELECT 1")
      File.write(File.join(mig_dir, "000002_other.sql"), "SELECT 1")
      files = migration.get_files
      expect(files).to include("000001_up.sql", "000002_other.sql")
      expect(files).not_to include("000001_up.down.sql")
    end
  end

  describe ".create_migration" do
    it "creates a sql migration via class method" do
      path = Tina4::Migration.create_migration("add orders table", migrations_dir: mig_dir, kind: "sql")
      expect(File.exist?(path)).to be true
      expect(File.basename(path)).to match(/\d{14}_add_orders_table\.sql/)
    end

    it "creates a ruby migration via class method" do
      path = Tina4::Migration.create_migration("add orders table", migrations_dir: mig_dir, kind: "ruby")
      expect(File.exist?(path)).to be true
      expect(File.basename(path)).to match(/\d{14}_add_orders_table\.rb/)
    end
  end
end
