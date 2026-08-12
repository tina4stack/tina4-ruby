# frozen_string_literal: true
#
# ORM base class contract -- feature 17 (ORM17-DEC-01).
#
# Shared conformance fixture:
#   tina4-documentation/plan/v3/fixtures/ormbase_contract.json
#
# The SAFETY NET for the ORM17-DEC-01 vestigial-state cleanup. Ruby carries NO
# vestigial ORM base state: it has no `_exists` (it uses `@persisted`, which IS
# read in #save), no `tableFilter`, and its delete/force_delete/restore locals
# (`pk`/`pk_value`) are all read by the missing-PK raise guard. So Ruby removes
# NOTHING -- it carries this round-trip characterisation suite for PARITY, with
# the same case names as Python/PHP/Node, so the four frameworks are held to one
# behaviour.
#
# NO mocks, NO doubles: a REAL SQLite file, real rows, real ORM writes. The
# round-trip (save -> load -> query -> re-save/update -> count -> delete) proves
# the ORM base lifecycle. Positive: a save loads back with identical values,
# count is the live total, where finds by a non-key column, a re-save UPDATEs in
# place. Negative: the re-save does not duplicate, and a deleted model is ABSENT
# from find and count.

require "spec_helper"
require "tmpdir"

class BaseWidgetModel < Tina4::ORM
  table_name "basewidget"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
  integer_field :qty
end

RSpec.describe "ORM base class contract (feature 17)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_ormbase") }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "ormbase.db")) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE basewidget (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER)")
    db.commit
  end

  after(:each) do
    db.close
    FileUtils.remove_entry(tmp_dir)
  end

  def new_widget(name, qty)
    BaseWidgetModel.new(name: name, qty: qty).save
  end

  # ── Invariant: write/read round-trip; no duplicate on re-save ─────────────

  it "a saved model loads back with identical values" do
    widget = BaseWidgetModel.new(name: "alpha", qty: 7)
    expect(widget.save).not_to be(false)       # #save returns self, never false here
    expect(widget.id).not_to be_nil            # auto-increment PK adopted

    loaded = BaseWidgetModel.find(widget.id)
    expect(loaded).not_to be_nil
    expect(loaded.name).to eq("alpha")
    expect(loaded.qty).to eq(7)
  end

  it "count returns the live row total" do
    new_widget("w0", 0)
    new_widget("w1", 1)
    new_widget("w2", 2)
    expect(BaseWidgetModel.count).to eq(3)
  end

  it "where returns a row matched by a non key column" do
    new_widget("alpha", 1)
    new_widget("beta", 2)

    rows = BaseWidgetModel.where("name = ?", ["beta"])
    expect(rows.length).to eq(1)
    expect(rows.first.name).to eq("beta")
    expect(rows.first.qty).to eq(2)
  end

  it "a re-saved model updates in place not a duplicate" do
    new_widget("alpha", 1)
    expect(BaseWidgetModel.count).to eq(1)

    loaded = BaseWidgetModel.find(1)
    loaded.qty = 99
    expect(loaded.save).not_to be(false)

    expect(BaseWidgetModel.count).to eq(1)         # UPDATE in place, NOT a 2nd INSERT
    expect(BaseWidgetModel.find(1).qty).to eq(99)  # the change persisted
  end

  # ── Invariant: delete removes the row (negative absence) ──────────────────

  it "a deleted model is absent from find and count" do
    new_widget("alpha", 1)
    expect(BaseWidgetModel.count).to eq(1)

    loaded = BaseWidgetModel.find(1)
    expect(loaded.delete).to be(true)

    expect(BaseWidgetModel.find(1)).to be_nil
    expect(BaseWidgetModel.count).to eq(0)
  end
end
