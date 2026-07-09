# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# The migrations dir default was backwards (preferred src/migrations/); it now prefers migrations/
# at the project root (the Python reference + CLI + auto-migrate), with src/migrations/ as a legacy
# fallback. Real SQLite, real migration files, no mocks.
RSpec.describe "Migration default path resolution" do
  let(:project) { Dir.mktmpdir("tina4_mig_default") }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(project, "test.db")) }

  around { |example| Dir.chdir(project) { example.run } }
  after  { FileUtils.remove_entry(project) rescue nil }

  def write_migration(dir, table)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "000001_create_#{table}.sql"),
               "CREATE TABLE #{table} (id INTEGER PRIMARY KEY);")
  end

  it "defaults to migrations/ at the project root" do
    write_migration("migrations", "widgets_root")
    Tina4::Migration.new(db).migrate
    expect(db.table_exists?("widgets_root")).to be true
  end

  it "falls back to legacy src/migrations/ when migrations/ is absent" do
    write_migration("src/migrations", "widgets_legacy")
    Tina4::Migration.new(db).migrate
    expect(db.table_exists?("widgets_legacy")).to be true
  end

  it "prefers migrations/ over legacy src/migrations/ when both exist" do
    write_migration("migrations", "widgets_win")
    write_migration("src/migrations", "widgets_lose")
    Tina4::Migration.new(db).migrate
    expect(db.table_exists?("widgets_win")).to be true
    expect(db.table_exists?("widgets_lose")).to be false
  end
end
