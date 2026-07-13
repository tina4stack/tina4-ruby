# frozen_string_literal: true

# Lock-in tests for the tina4_migration bookkeeping table's `passed` column
# (issues #129 / #172). Real SQLite, NO mocks or doubles.
#
# Canonical v3 tracking-table shape (identical across all four Tina4 frameworks):
#   id, migration_name VARCHAR(500) NOT NULL UNIQUE, description VARCHAR(500),
#   batch INTEGER NOT NULL DEFAULT 1, executed_at VARCHAR(50) NOT NULL,
#   passed INTEGER NOT NULL DEFAULT 1
#
# Contract these tests pin (verified against the live source in
# tina4-ruby/lib/tina4/migration.rb):
#   * "applied" == a tracking row with passed = 1. The applied-read is
#     `WHERE passed = 1` (completed_migrations / get_applied).
#   * migrate records ONLY passed:1 rows. A failed file rolls back and records
#     NOTHING (never a passed:0 row); the run stops at the failure.
#   * record_migration(name, batch, passed: N) CAN write a passed:0 row; a
#     passed:0 row is NOT treated as applied, so its migration stays pending /
#     eligible to re-run (it is never silently skipped).
#   * delete-before-insert (fix (b)): _record_migration deletes any existing row
#     for a migration_name before inserting the fresh row, so a leftover passed:0
#     row is superseded and the migration re-applies cleanly instead of colliding
#     on the UNIQUE migration_name. The table holds AT MOST ONE row per
#     migration_name, latest state wins.
#
# Ruby is v3-native (no v2), so there is no v2->v3 upgrade path to test — that
# is correct, not a gap.

require "spec_helper"

RSpec.describe "tina4_migration `passed` column (#129/#172)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_migration_passed") }
  let(:db_path) { File.join(tmp_dir, "x.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }
  let(:migrations_dir) { File.join(tmp_dir, "migrations") }
  let(:migration) { Tina4::Migration.new(db, migrations_dir: migrations_dir) }

  # Canonical column set for the v3 tracking table — identical across all four
  # Tina4 frameworks.
  CANONICAL_COLUMNS = %w[id migration_name description batch executed_at passed].freeze

  before(:each) do
    FileUtils.mkdir_p(migrations_dir)
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "fresh v3 tracking table has the passed column (and the full canonical set)" do
    migration # trigger lazy let -> ensure_tracking_table
    column_names = db.columns("tina4_migration").map { |c| c[:name] }

    expect(column_names).to include("passed")
    # Order-independent: the fresh table is exactly the canonical column set.
    expect(column_names.sort).to eq(CANONICAL_COLUMNS.sort)
  end

  it "an applied migration is recorded passed=1 and is not re-run" do
    name = "20240101000001_create_widget.sql"
    File.write(File.join(migrations_dir, name),
               "CREATE TABLE widget (id INTEGER PRIMARY KEY, name TEXT);")

    results = migration.migrate
    applied = results.find { |r| r[:name] == name }
    expect(applied).not_to be_nil
    expect(applied[:status]).to eq("success")
    expect(db.table_exists?("widget")).to be(true)

    # The tracking row was written with passed = 1 (the "applied" marker).
    row = db.fetch_one("SELECT passed FROM tina4_migration WHERE migration_name = ?", [name])
    expect(row).not_to be_nil
    expect(row[:passed]).to eq(1)

    # Re-running does not re-apply it — a fresh runner reads the passed=1 row and
    # reports nothing pending. The real table is untouched (no error, still there).
    rerun = Tina4::Migration.new(db, migrations_dir: migrations_dir).migrate
    expect(rerun).to be_empty
    expect(db.table_exists?("widget")).to be(true)
  end

  it "a leftover passed=0 row is pending, then re-applies cleanly (delete-before-insert supersedes it)" do
    # A real on-disk migration that would create a table.
    name = "20240101000002_create_gadget.sql"
    File.write(File.join(migrations_dir, name),
               "CREATE TABLE gadget (id INTEGER PRIMARY KEY, name TEXT);")

    # Write a passed:0 tracking row under the migration's real tracking name
    # (the basename - the same value run_migration records). This is what a
    # failed-and-recorded / carried-over passed:0 state looks like.
    migration.record_migration(name, 1, passed: 0)
    passed_row = db.fetch_one("SELECT passed FROM tina4_migration WHERE migration_name = ?", [name])
    expect(passed_row[:passed]).to eq(0)

    # CONTRACT part 1 (#129/#172): a passed:0 row is NOT applied. The applied-read
    # is `WHERE passed = 1`, so get_applied excludes it and the file is still
    # reported pending - i.e. eligible to re-run (never silently skipped).
    expect(migration.get_applied).not_to include(name)
    expect(migration.get_pending).to include(name)

    # CONTRACT part 2 (fix (b), delete-before-insert): re-running APPLIES the
    # migration cleanly. _record_migration deletes any existing row for this
    # migration_name before inserting the fresh passed:1 row, so the completion
    # INSERT no longer collides on the UNIQUE migration_name - a previously-failed
    # migration re-applies instead of wedging. The file's SQL runs for real and
    # the table is created. (Identical in the Python master - this mirrors its
    # new delete-then-insert scenario.)
    results = migration.migrate
    applied = results.find { |r| r[:name] == name }
    expect(applied).not_to be_nil, "migrate must attempt+apply the passed:0 migration, not skip it"
    expect(applied[:status]).to eq("success")
    expect(db.table_exists?("gadget")).to be(true)

    # Exactly ONE row now remains for that migration_name (the stale passed:0 row
    # was superseded - at most one row per migration_name, latest state wins),
    # and it is passed=1.
    count_row = db.fetch_one("SELECT COUNT(*) AS c FROM tina4_migration WHERE migration_name = ?", [name])
    expect(count_row[:c]).to eq(1)
    final = db.fetch_one("SELECT passed FROM tina4_migration WHERE migration_name = ?", [name])
    expect(final[:passed]).to eq(1)

    # It now counts as applied, and a fresh runner reads the same state from the
    # table: applied, no longer pending, and not re-run.
    expect(migration.get_applied).to include(name)
    expect(migration.get_pending).not_to include(name)
    fresh = Tina4::Migration.new(db, migrations_dir: migrations_dir)
    expect(fresh.get_applied).to include(name)
    expect(fresh.get_pending).not_to include(name)
  end
end
