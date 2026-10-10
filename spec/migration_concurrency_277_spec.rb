# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Regression for tina4-ruby#277: startup auto-migration is serialized across
# processes, so a data migration applies exactly once under concurrency.
#
# No mocks. This spawns several REAL OS processes (not threads — the bug is
# cross-process) that open the SAME SQLite database and run the migration runner
# at the same moment. A data migration sleeps before it inserts, to widen the
# window in which two unsynchronized runs would both decide the migration is
# pending and both insert. The assertion is the observable outcome: the row
# exists exactly once and the tracker holds one row for the migration.
#
# Without the run-wide lock in Migration#migrate every overlapping process
# inserts its own copy; with it, the winner migrates while the rest block, then
# re-read the applied set and find nothing pending.
#
# SQLite is the engine exercised here because every test host has it. The
# PostgreSQL/MySQL/MSSQL advisory-lock paths and the Firebird file-lock path are
# covered by the lab's real-service concurrency run.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "sqlite3"

RSpec.describe "Migration concurrency (#277)" do
  WORKERS_277 = 8
  LIB_PATH_277 = File.expand_path("../lib", __dir__)

  it "applies each migration exactly once under concurrent starts" do
    Dir.mktmpdir("tina4-277-") do |dir|
      migrations = File.join(dir, "migrations")
      FileUtils.mkdir_p(migrations)

      File.write(File.join(migrations, "000001_create_widgets.sql"),
                 "CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);\n")

      # A data migration that takes a moment before it writes — a real backfill.
      # The sleep guarantees overlap, so an unsynchronized run inserts WORKERS
      # copies of 'first'.
      File.write(File.join(migrations, "000002_seed_first.rb"), <<~RUBY)
        class SeedFirst277 < Tina4::MigrationBase
          def up(db = nil)
            sleep 0.6
            db.execute("INSERT INTO widgets (name) VALUES ('first')")
          end

          def down(db = nil)
            db.execute("DELETE FROM widgets WHERE name = 'first'")
          end
        end
      RUBY

      db_file = File.join(dir, "app.db")
      worker = File.join(dir, "worker.rb")
      File.write(worker, <<~RUBY)
        require "tina4"
        db = Tina4::Database.new("sqlite:///" + #{db_file.inspect})
        begin
          Tina4::Migration.new(db, migrations_dir: #{migrations.inspect}).migrate
        rescue => e
          warn "worker error: \#{e.message}"
          exit 1
        ensure
          db.close rescue nil
        end
      RUBY

      # Launch all workers as close to simultaneously as possible.
      pids = Array.new(WORKERS_277) do
        Process.spawn(
          RbConfig.ruby, "-I", LIB_PATH_277, "-rbundler/setup", worker,
          out: File::NULL, err: File::NULL
        )
      end
      pids.each { |pid| Process.wait(pid) }

      db = SQLite3::Database.new(db_file)
      begin
        first_rows = db.get_first_value("SELECT count(*) FROM widgets WHERE name = 'first'")
        tracker_rows = db.get_first_value(
          "SELECT count(*) FROM tina4_migration WHERE migration_name = '000002_seed_first.rb'"
        )
      ensure
        db.close
      end

      expect(first_rows).to eq(1),
        "the data migration must apply exactly once under #{WORKERS_277} concurrent starts, got #{first_rows}"
      expect(tracker_rows).to eq(1),
        "the tracker must hold exactly one row for the migration, got #{tracker_rows}"
    ensure
      # The lock sidecar lives in the system temp dir (outside the mktmpdir that
      # mktmpdir removes), so reap it ourselves rather than leaving an orphan.
      FileUtils.rm_f(
        File.join(Dir.tmpdir, "tina4-migration-#{Digest::SHA256.hexdigest(File.realpath(migrations))}.lock")
      )
    end
  end

  # The SQLite/Firebird file-lock sidecar is a runtime artifact, so it must live
  # in the SYSTEM TEMP dir and NOT inside the tracked migrations/ folder (a lock
  # file there gets committed by accident and blocks a plain rmdir). Parity with
  # the amended PHP fileLockPath() and ADR-0095. Mutation: revert the location to
  # a migrations-dir sidecar and both assertions below fail.
  it "puts the file-lock sidecar in the system temp dir, never in the migrations folder" do
    Dir.mktmpdir("tina4-277-loc-") do |dir|
      migrations = File.join(dir, "migrations")
      FileUtils.mkdir_p(migrations)
      File.write(File.join(migrations, "000001_create_widgets.sql"),
                 "CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);\n")

      db = Tina4::Database.new("sqlite:///#{File.join(dir, 'app.db')}")
      begin
        Tina4::Migration.new(db, migrations_dir: migrations).migrate
      ensure
        db.close
      end

      leftover = Dir.glob(File.join(migrations, "{*,.*}.lock"))
      expect(leftover).to be_empty,
        "no lock file may be left inside the migrations folder, found: #{leftover.inspect}"

      expected = File.join(
        Dir.tmpdir,
        "tina4-migration-#{Digest::SHA256.hexdigest(File.realpath(migrations))}.lock"
      )
      expect(File.exist?(expected)).to be(true),
        "the file lock must live in the system temp dir at #{expected}"
    ensure
      FileUtils.rm_f(
        File.join(Dir.tmpdir, "tina4-migration-#{Digest::SHA256.hexdigest(File.realpath(migrations))}.lock")
      )
    end
  end
end
