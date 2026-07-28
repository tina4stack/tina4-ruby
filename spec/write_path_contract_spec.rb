# frozen_string_literal: true

# Write-path contract: a write with no filter is an error, not a full-table operation.
#
# Audit feature 4 (plan/v3/features/004-sqlite-adapter.md), P1.
#
# The bug these lock in: db.update(table, data) with no explicit filter builds
# "UPDATE table SET ..." with NO WHERE clause, so it overwrites EVERY row and
# reports success. Verified in Ruby, Python and PHP; Node silently changes
# nothing instead. Nothing logs, nothing raises.
#
# Real SQLite files in a tmp dir. No mocks.

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "write-path contract" do
  around(:each) do |example|
    Dir.mktmpdir("tina4-writepath") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:db) do
    database = Tina4::Database.new("sqlite:///#{File.join(@dir, 'contract.db')}")
    database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
    database.insert("t", { "id" => 1, "name" => "one" })
    database.insert("t", { "id" => 2, "name" => "two" })
    database
  end

  def rows(database)
    database.fetch("SELECT * FROM t ORDER BY id").records.map { |r| r.to_h.transform_keys(&:to_s) }
  end

  # --- pair 1: keyed update ------------------------------------------------

  it "updates only the row named by the primary key in the data" do
    db.update("t", { "id" => 1, "name" => "CHANGED" })
    expect(rows(db)).to eq([
                             { "id" => 1, "name" => "CHANGED" },
                             { "id" => 2, "name" => "two" }
                           ])
  end

  it "negative: an update without a filter or primary key raises" do
    before = rows(db)
    expect { db.update("t", { "name" => "NOPK" }) }
      .to raise_error(ArgumentError, /filter/)
    expect(rows(db)).to eq(before), "a filterless update modified rows - this is the data-loss bug"
  end

  # --- pair 2: no silent no-op -------------------------------------------

  it "reports the rows it changed" do
    result = db.update("t", { "name" => "X" }, "id = ?", [1])
    expect(result.affected_rows).to eq(1)
  end

  it "negative: never reports zero affected when a matching row exists" do
    result = db.update("t", { "id" => 2, "name" => "TWO" })
    expect(result.affected_rows).not_to eq(0)
  end

  # --- pair 3: delete filter forms --------------------------------------

  it "accepts a hash filter on delete" do
    db.delete("t", { "id" => 2 })
    expect(rows(db)).to eq([{ "id" => 1, "name" => "one" }])
  end

  it "accepts a string filter with params on delete" do
    db.delete("t", "id = ?", [2])
    expect(rows(db)).to eq([{ "id" => 1, "name" => "one" }])
  end

  # --- pair 4: no accidental truncate -----------------------------------

  it "truncate removes every row" do
    db.truncate("t")
    expect(rows(db)).to eq([])
  end

  it "negative: a delete without a filter raises" do
    before = rows(db)
    expect { db.delete("t") }.to raise_error(ArgumentError, /filter/)
    expect(rows(db)).to eq(before), "a filterless delete removed rows"
  end

  # --- pair 5: write result contract ------------------------------------

  it "insert reports a last_id" do
    result = db.insert("t", { "name" => "three" })
    expect(result.last_id).not_to be_nil
  end

  it "negative: update and delete do not report a last_id" do
    expect(db.update("t", { "id" => 1, "name" => "CHANGED" }).last_id).to be_nil
    expect(db.delete("t", { "id" => 2 }).last_id).to be_nil
  end

  # --- primary-key introspection ----------------------------------------

  it "introspects the primary key rather than assuming id" do
    expect(db.primary_key("t")).to eq("id")
  end
end
