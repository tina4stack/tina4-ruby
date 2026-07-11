# frozen_string_literal: true

# #165 — an INSERT must OMIT a column the caller never assigned so a
# `NOT NULL DEFAULT <x>` column gets its DB default, while still writing NULL
# for a field the caller explicitly set to nil.
#
# Before the fix, Ruby's ORM #save serialised columns via
# to_db_hash(exclude_nil: true), which OMITTED every nil column — whether the
# caller left it unset or explicitly assigned nil. So the NOT NULL DEFAULT case
# happened to work, but an explicit nil on a NOT NULL column was ALSO omitted
# (silently taking the DB default) instead of being written as NULL and
# rejected — diverging from the Python master. And an all-unset INSERT fell
# through to `INSERT INTO t () VALUES ()`, invalid on SQLite.
#
# The distinction locked in here (positive AND negative), matching the Python
# master (tests/test_orm_null_for_unset.py):
#   * a column left UNSET  -> omitted -> DB default applies  (INSERT succeeds)
#   * a column set to nil  -> written -> explicit NULL       (fails a NOT NULL col)
#   * a non-nil ORM default -> still written                 (no regression)
#   * every column unset    -> INSERT ... DEFAULT VALUES
#
# NO MOCKS: a real SQLite Database on disk, real DDL with real DEFAULT
# constraints, real save()/reload round-trips.

require "spec_helper"

# DDL owns the DEFAULT constraints the ORM must respect. label/quantity are
# NOT NULL DEFAULT; note is nullable (to show explicit-nil -> NULL is accepted
# where the column allows it).
WIDGET165_DDL = <<~SQL
  CREATE TABLE widget165 (
      id       INTEGER PRIMARY KEY AUTOINCREMENT,
      label    TEXT    NOT NULL DEFAULT '',
      quantity INTEGER NOT NULL DEFAULT 0,
      note     TEXT
  )
SQL

class Widget165 < Tina4::ORM
  table_name "widget165"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
  integer_field :quantity
  string_field :note
end

# Same table, but label carries a non-nil ORM-level default — proving a
# resolved default is still written (the omission only targets unset-AND-nil).
class Widget165Defaulted < Tina4::ORM
  table_name "widget165"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label, default: "from-orm"
  integer_field :quantity
  string_field :note
end

RSpec.describe "ORM omit unset columns on INSERT (#165)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_165") }
  let(:db_path) { File.join(tmp_dir, "test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute(WIDGET165_DDL)
    db.commit
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  def count_rows
    db.fetch_one("SELECT COUNT(*) AS c FROM widget165")[:c].to_i
  end

  # ── Positive: unset columns fall through to the DB default ──────────────

  it "inserts with the DB defaults when EVERY column is unset" do
    # A model with nothing assigned inserts successfully via the
    # empty-insert -> DEFAULT VALUES path, and every column shows its DB default.
    w = Widget165.new
    expect(w.save).to eq(w), "save failed: #{w.get_error.inspect}"

    row = db.fetch_one("SELECT * FROM widget165 WHERE id = ?", [w.id])
    expect(row[:label]).to eq(""), "NOT NULL DEFAULT '' should apply to an unset column"
    expect(row[:quantity]).to eq(0), "NOT NULL DEFAULT 0 should apply to an unset column"
    expect(row[:note]).to be_nil
  end

  it "uses the DB default for a partially-unset NOT NULL column" do
    # Setting only `label` leaves `quantity` unset — it must get the DB
    # default 0, not an explicit NULL that violates NOT NULL.
    w = Widget165.new(label: "hello")
    expect(w.save).to eq(w), "save failed: #{w.get_error.inspect}"

    row = db.fetch_one("SELECT * FROM widget165 WHERE id = ?", [w.id])
    expect(row[:label]).to eq("hello")
    expect(row[:quantity]).to eq(0), "unset NOT NULL DEFAULT column must use its DB default"
  end

  # ── Positive: an assigned value is written verbatim ─────────────────────

  it "writes an assigned value verbatim" do
    w = Widget165.new(label: "widget", quantity: 7)
    expect(w.save).to eq(w), "save failed: #{w.get_error.inspect}"

    row = db.fetch_one("SELECT * FROM widget165 WHERE id = ?", [w.id])
    expect(row[:label]).to eq("widget")
    expect(row[:quantity]).to eq(7)
  end

  # ── Positive: explicit nil on a NULLABLE column writes NULL ─────────────

  it "writes NULL for an explicit nil on a nullable column" do
    # `note` is nullable — assigning nil explicitly must persist NULL (the value
    # IS written, it is not omitted).
    w = Widget165.new(label: "x", note: nil)
    expect(w.save).to eq(w), "save failed: #{w.get_error.inspect}"

    row = db.fetch_one("SELECT * FROM widget165 WHERE id = ?", [w.id])
    expect(row[:note]).to be_nil
  end

  # ── Negative: explicit nil IS written (as NULL), so it fails a NOT NULL
  #    column — proving the value is not silently swapped for the default ──

  it "fails when an explicit nil is set on a NOT NULL column (constructor)" do
    # Setting `quantity = nil` explicitly (constructor) writes NULL, which a
    # NOT NULL column rejects — save() fails loud and no row lands. Counterpart
    # to the unset case: unset omits (default applies), explicit nil writes NULL.
    w = Widget165.new(label: "x", quantity: nil)
    expect(w.save).to eq(false), "explicit nil into a NOT NULL column must fail"
    expect(w.get_error).not_to be_nil
    expect(count_rows).to eq(0), "no row should have landed"
  end

  it "fails when an explicit nil is set on a NOT NULL column (attribute write)" do
    # The assignment tracking also covers post-construction attribute sets:
    # `w.quantity = nil` marks quantity assigned, so it is written as NULL and
    # rejected by the NOT NULL column (not omitted).
    w = Widget165.new(label: "x")
    w.quantity = nil # explicit — must be tracked as assigned
    expect(w.save).to eq(false), "explicit nil via attribute must fail on NOT NULL"
    expect(count_rows).to eq(0)
  end

  # ── Regression guard: an ORM-level default (non-nil) is still written ───

  it "still writes a non-nil ORM-level default" do
    # A field with an ORM default that resolves to a non-nil value must still be
    # inserted (the omission only targets unset-AND-nil columns), so static/
    # callable ORM defaults do not regress.
    w = Widget165Defaulted.new # label unset by caller, but ORM default is non-nil
    expect(w.save).to eq(w), "save failed: #{w.get_error.inspect}"

    row = db.fetch_one("SELECT * FROM widget165 WHERE id = ?", [w.id])
    expect(row[:label]).to eq("from-orm"), "non-nil ORM default must be written, not omitted"
    expect(row[:quantity]).to eq(0), "unset NOT NULL DEFAULT column still uses its DB default"
  end
end
