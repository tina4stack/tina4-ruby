# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# Parity lock-in for the tina4-python #128 fix (its regression suite is
# tina4-python/tests/test_issue_115_v2_upgrade.py): a migration history recorded
# by a v2 project must NOT replay when the app first boots on v3.
#
# THE PYTHON BUG (#128): Python v2 recorded the identifier in a `description`
# column as the raw filename WITH its extension (".sql"/".py"). Python v3's
# v2->v3 backfill (`_resolve_migration_name`) matched that description against
# migration file STEMS (no extension), and `migrate()` compares recorded names
# against `mig_file.stem`. An extension-bearing description never matched a stem,
# so the WHOLE prior history looked unapplied and re-ran on the first v3 boot.
# The fix: also try the extension-stripped form of the recorded name.
#
# WHY RUBY IS STRUCTURALLY IMMUNE (verified against lib/tina4/migration.rb HEAD,
# and git origin/main for v2):
#   * Ruby v2 (main) recorded `migration_name = File.basename(file)` -- the FULL
#     filename WITH extension -- and detected pending via
#     `completed.include?(File.basename(f))` (full filename WITH extension).
#   * Ruby v3 does the IDENTICAL thing: run_migration sets
#     `name = File.basename(file)` (migration.rb:328), _record_migration stores
#     it in `migration_name` (migration.rb:709), and pending_migrations filters
#     with `completed.include?(File.basename(f))` (migration.rb:313).
#   So the extension is present on BOTH sides in BOTH versions. Ruby never
#   strips an extension and never compares against a stem -- there is no
#   stem/extension mismatch for a v2 history to trip on. There is nothing for
#   the Python resolver fix to mirror; adding extension-stripping here would be
#   inventing a change against a design that is already correct.
#
# These tests PIN that immunity so it cannot silently regress (e.g. if someone
# "aligned" Ruby to store stems like Python): an extension-bearing recorded
# migration is seen as APPLIED and does NOT re-run, and a genuinely-unapplied
# migration still runs. Real SQLite only -- NO mocks, stubs, or doubles.

require "spec_helper"

RSpec.describe "Migration v2 extension-bearing history does not replay (python #128 parity)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_v2_ext_replay") }
  let(:db_path) { File.join(tmp_dir, "v2ext.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }
  let(:migrations_dir) { File.join(tmp_dir, "migrations") }

  before(:each) do
    FileUtils.mkdir_p(migrations_dir)
  end

  after(:each) do
    db.close rescue nil
    FileUtils.rm_rf(tmp_dir)
  end

  # Insert a tracking row the way a v2 history reaches v3: `migration_name`
  # carries the file extension, exactly as v2's run_migration wrote it
  # (File.basename). Written into the v3-shaped table (real INSERT, no double).
  def record_v2_style(name, description)
    Tina4::Migration.new(db, migrations_dir: migrations_dir) # ensure v3 tracking table
    db.execute(
      "INSERT INTO tina4_migration (migration_name, description, batch, executed_at, passed) " \
      "VALUES (?, ?, 1, 'legacy', 1)",
      [name, description]
    )
  end

  it "does NOT replay a .sql migration recorded v2-style WITH its extension" do
    # Non-idempotent target: a replay would raise on the UNIQUE column, so a
    # regression fails LOUDLY instead of silently succeeding the way a
    # CREATE TABLE IF NOT EXISTS would. Mirrors Python's
    # test_v2_filenames_do_not_replay_on_upgrade.
    db.execute("CREATE TABLE checklist_item_group (group_name TEXT UNIQUE)")
    db.execute("INSERT INTO checklist_item_group (group_name) VALUES ('window_and_entrance')")

    name = "0000002_data_migration_for_show_room.sql"
    File.write(File.join(migrations_dir, name),
               "INSERT INTO checklist_item_group (group_name) VALUES ('window_and_entrance');")

    record_v2_style(name, "data migration for show room")

    results = Tina4::Migration.new(db, migrations_dir: migrations_dir).migrate

    expect(results).to eq([]),
                       "an extension-bearing recorded migration must not replay, got #{results.inspect}"

    # Proven APPLIED, not merely unseen: it is in completed, absent from pending.
    status = Tina4::Migration.new(db, migrations_dir: migrations_dir).status
    expect(status[:completed]).to include(name)
    expect(status[:pending]).not_to include(name)

    # The non-idempotent INSERT never re-ran: still exactly one row.
    row = db.fetch_one("SELECT COUNT(*) AS c FROM checklist_item_group")
    expect(row[:c] || row["c"]).to eq(1)
  end

  it "does NOT replay a .rb code migration recorded v2-style WITH its extension" do
    # Ruby's .rb code migration is the analogue of Python's .py; it was recorded
    # the same extension-bearing way. Mirrors Python's
    # test_v2_python_migration_filename_also_resolves.
    name = "000003_seed_data.rb"
    File.write(File.join(migrations_dir, name), <<~RUBY)
      class SeedData < Tina4::MigrationBase
        def up(db)
          # A replay would run this and raise on the UNIQUE column.
          db.execute("INSERT INTO seed_marker (tag) VALUES ('seeded')")
        end
      end
    RUBY

    db.execute("CREATE TABLE seed_marker (tag TEXT UNIQUE)")
    db.execute("INSERT INTO seed_marker (tag) VALUES ('seeded')")

    record_v2_style(name, "seed data")

    results = Tina4::Migration.new(db, migrations_dir: migrations_dir).migrate

    expect(results).to eq([]),
                       "an extension-bearing recorded .rb migration must not replay, got #{results.inspect}"
    row = db.fetch_one("SELECT COUNT(*) AS c FROM seed_marker")
    expect(row[:c] || row["c"]).to eq(1)
  end

  it "still runs a genuinely-unapplied migration (negative case)" do
    # The recorded-with-extension migration is skipped; a brand-new file that
    # was never recorded still applies. Mirrors Python's
    # test_new_migrations_after_upgrade_run_normally.
    applied = "0000002_data_migration_for_show_room.sql"
    File.write(File.join(migrations_dir, applied), "SELECT 1;")
    record_v2_style(applied, "data migration for show room")

    pending = "000003_create_orders.sql"
    File.write(File.join(migrations_dir, pending), "CREATE TABLE orders (id INTEGER PRIMARY KEY);")

    results = Tina4::Migration.new(db, migrations_dir: migrations_dir).migrate

    ran = results.map { |r| r[:name] }
    expect(ran).to eq([pending]),
                   "only the genuinely-unapplied migration must run, got #{ran.inspect}"
    expect(results.first[:status]).to eq("success")
    expect(db.table_exists?("orders")).to be(true)
  end
end
