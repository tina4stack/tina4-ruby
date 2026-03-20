# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Migration do
  let(:tmp_dir) { Dir.mktmpdir("tina4_mig_test") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite://#{db_path}") }
  let(:mig_dir) { File.join(tmp_dir, "migrations") }
  let(:migration) { Tina4::Migration.new(db, migrations_dir: mig_dir) }

  after(:each) do
    db.close rescue nil
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#initialize" do
    it "creates migration tracking table" do
      migration # force lazy evaluation
      expect(db.table_exists?("tina4_migrations")).to be true
    end
  end

  describe "#create" do
    it "creates migration files" do
      path = migration.create("add users table")
      expect(File.exist?(path)).to be true
      expect(File.basename(path)).to match(/\d{14}_add_users_table\.rb/)
    end

    it "creates migration with up and down methods" do
      path = migration.create("add users table")
      content = File.read(path)
      expect(content).to include("def up(db)")
      expect(content).to include("def down(db)")
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
      File.write(File.join(mig_dir, "000001_bad.sql"), "INVALID SQL STATEMENT")

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
  end
end
