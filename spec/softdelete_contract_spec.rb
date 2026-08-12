# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "socket"

# Feature 20 - Soft delete: the shared conformance contract.
#
# Proves the soft-delete BEHAVIOUR against a REAL database, NO MOCKS. Every case
# runs on real SQLite AND real PostgreSQL (:55432, tina4/tina4 by default) so the
# row presence/absence is asserted by querying the real table, not a double: a
# soft-deleted row is COUNT=1 in the raw table but ABSENT from the finders; a
# force-deleted row is COUNT=0.
#
# Case names are shared verbatim across the four frameworks and gated by
# scripts/audit-contract-fixtures.py. Under TINA4_REQUIRE_SERVICES a postgres
# skip is upgraded to a failure by spec_helper, so PG is exercised for real.
#
# SOFTDEL-DEC-01 / SOFTDEL-DEC-02: delete() FLAGS not removes; finders exclude
# it; with_trashed() includes it; restore() un-deletes; force_delete() ALWAYS
# hard-removes; create_table() INJECTS the flag column for a soft_delete model
# that never declared it, honouring the CONFIGURABLE soft_delete_field.

# Model classes are TOP LEVEL on purpose (a bare constant inside RSpec.describe
# lands on Object and clobbers another spec file).
class SdItem < Tina4::ORM
  table_name "sd_item"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  integer_field :is_deleted, default: 0   # DECLARED (behaviour is independent of injection)
end

class SdAuto < Tina4::ORM
  table_name "sd_auto"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  # NO is_deleted declared -- create_table must INJECT it (SOFTDEL-CREATETABLE-COLUMN)
end

class SdArchived < Tina4::ORM
  table_name "sd_archived"
  self.soft_delete = true
  self.soft_delete_field = :archived     # CONFIGURABLE column name (Ruby-only)
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
end

SOFTDEL_ENGINES = %w[sqlite postgres].freeze

RSpec.describe "Soft delete (feature 20)" do
  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 3) { true }
  rescue StandardError
    false
  end

  def engine_db(engine)
    if engine == "postgres"
      h = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
      p = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
      skip "postgres unreachable at #{h}:#{p} (set TINA4_TEST_PG_*)" unless reachable?(h, p)
      db = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")
      Tina4::Database.new("postgres://#{h}:#{p}/#{db}",
                          username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                          password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
    else
      Tina4::Database.new("sqlite:///#{Tempfile.new(["sd", ".db"]).path}")
    end
  end

  def flag(db, table, id, col = "is_deleted")
    row = db.fetch_one("SELECT #{col} AS f FROM #{table} WHERE id = ?", [id])
    (row[:f] || row["f"]).to_i
  end

  def raw_count(db, table)
    row = db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")
    (row[:c] || row["c"]).to_i
  end

  def col_names(db, table)
    db.columns(table).map { |c| (c[:name] || c["name"]).to_s }
  end

  def drop(db, *tables)
    tables.each do |t|
      begin
        db.execute("DROP TABLE IF EXISTS #{t}")
      rescue StandardError
        nil
      end
    end
  end

  SOFTDEL_ENGINES.each do |engine|
    context "on #{engine}" do
      # ── delete() FLAGS, does not remove ──────────────────────────────────
      it "delete flags the row instead of removing it" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_item")
        expect(SdItem.create_table).to be true
        begin
          row = SdItem.new(title: "keep-me")
          row.save
          expect(row.delete).to be true
          expect(raw_count(db, "sd_item")).to eq(1)          # still in the raw table
          expect(flag(db, "sd_item", row.id)).to eq(1)       # flag set to 1
        ensure
          drop(db, "sd_item")
          db.close
        end
      end

      it "a soft deleted row is excluded from the default finder" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_item")
        expect(SdItem.create_table).to be true
        begin
          row = SdItem.new(title: "hide-me")
          row.save
          expect(SdItem.all.length).to eq(1)
          expect(SdItem.count).to eq(1)
          row.delete
          expect(raw_count(db, "sd_item")).to eq(1)          # present (negative control)
          expect(SdItem.all.length).to eq(0)                 # excluded from finders
          expect(SdItem.count).to eq(0)
          expect(SdItem.find_by_id(row.id)).to be_nil
          expect(SdItem.where("id = ?", [row.id]).length).to eq(0)
        ensure
          drop(db, "sd_item")
          db.close
        end
      end

      # ── with_trashed() includes; restore() un-deletes ────────────────────
      it "with trashed returns the soft deleted row" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_item")
        expect(SdItem.create_table).to be true
        begin
          row = SdItem.new(title: "trashed")
          row.save
          row.delete
          expect(SdItem.all.length).to eq(0)                 # excluded by default
          trashed = SdItem.with_trashed
          expect(trashed.length).to eq(1)                    # included with_trashed
          expect(trashed.first.id).to eq(row.id)
        ensure
          drop(db, "sd_item")
          db.close
        end
      end

      it "restore undeletes the row so it reappears in the finder" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_item")
        expect(SdItem.create_table).to be true
        begin
          row = SdItem.new(title: "comeback")
          row.save
          row.delete
          expect(SdItem.count).to eq(0)
          expect(row.restore).to be true
          expect(SdItem.count).to eq(1)                      # reappears
          expect(SdItem.find_by_id(row.id)).not_to be_nil
          expect(flag(db, "sd_item", row.id)).to eq(0)       # flag cleared
        ensure
          drop(db, "sd_item")
          db.close
        end
      end

      # ── force_delete() ALWAYS hard-removes (the PHP-class regression) ─────
      it "force delete hard removes the row even from with trashed" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_item")
        expect(SdItem.create_table).to be true
        begin
          row = SdItem.new(title: "gone")
          row.save
          expect(raw_count(db, "sd_item")).to eq(1)
          expect(row.force_delete).to be true
          expect(raw_count(db, "sd_item")).to eq(0)          # physically removed
          expect(SdItem.with_trashed.length).to eq(0)        # gone from with_trashed too
        ensure
          drop(db, "sd_item")
          db.close
        end
      end

      # ── create_table() INJECTS the column (SOFTDEL-CREATETABLE-COLUMN) ────
      it "create table injects a usable is deleted column for a soft delete model" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_auto")
        expect(SdAuto.create_table).to be true
        begin
          expect(col_names(db, "sd_auto")).to include("is_deleted")   # injected
          row = SdAuto.new(title: "auto")
          row.save
          expect(row.delete).to be true                       # soft-flag on injected col
          expect(raw_count(db, "sd_auto")).to eq(1)           # row still present
          expect(SdAuto.all.length).to eq(0)                  # excluded from finder
          expect(SdAuto.with_trashed.length).to eq(1)         # visible with_trashed
          expect(row.restore).to be true
          expect(SdAuto.all.length).to eq(1)                  # reappears
          expect(row.force_delete).to be true
          expect(raw_count(db, "sd_auto")).to eq(0)           # hard-removed
        ensure
          drop(db, "sd_auto")
          db.close
        end
      end

      # ── Ruby-only: the injected column honours the CONFIGURED field ──────
      it "create table injects the configured soft delete field name" do
        db = engine_db(engine)
        Tina4.bind_database(db)
        drop(db, "sd_archived")
        expect(SdArchived.create_table).to be true
        begin
          cols = col_names(db, "sd_archived")
          expect(cols).to include("archived")                 # the configured column ...
          expect(cols).not_to include("is_deleted")           # ... not the hard-coded default
          row = SdArchived.new(title: "cfg")
          row.save
          row.delete
          expect(flag(db, "sd_archived", row.id, "archived")).to eq(1)  # write hit the configured col
          expect(SdArchived.all.length).to eq(0)              # finder filters on the configured col
          expect(SdArchived.with_trashed.length).to eq(1)
          row.restore
          expect(SdArchived.all.length).to eq(1)
        ensure
          drop(db, "sd_archived")
          db.close
        end
      end
    end
  end
end
