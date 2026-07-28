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
    expect(db.primary_key("t")).to eq(["id"])
  end

  # --- composite primary keys --------------------------------------------
  # A PK resolver returning only the FIRST key column reintroduces the whole
  # data-loss bug for composite-key tables: WHERE order_id = 1 matches every
  # row in that order.

  context "with a composite primary key" do
    let(:composite) do
      database = Tina4::Database.new("sqlite:///#{File.join(@dir, 'composite.db')}")
      database.execute(<<~SQL)
        CREATE TABLE order_items (
          order_id INTEGER, product_id INTEGER, qty INTEGER,
          PRIMARY KEY (order_id, product_id))
      SQL
      database.insert("order_items", { "order_id" => 1, "product_id" => 5, "qty" => 1 })
      database.insert("order_items", { "order_id" => 1, "product_id" => 6, "qty" => 2 })
      database.insert("order_items", { "order_id" => 2, "product_id" => 5, "qty" => 3 })
      database
    end

    def items(database)
      database
        .fetch("SELECT * FROM order_items ORDER BY order_id, product_id")
        .records.map { |r| r.to_h.transform_keys(&:to_s) }
    end

    it "returns every key column" do
      expect(composite.primary_key("order_items")).to eq(%w[order_id product_id])
    end

    it "negative: never returns only the first key column" do
      expect(composite.primary_key("order_items").length).to eq(2)
    end

    it "a composite-keyed update touches exactly one row" do
      composite.update("order_items", { "order_id" => 1, "product_id" => 5, "qty" => 99 })
      expect(items(composite)).to eq([
                                       { "order_id" => 1, "product_id" => 5, "qty" => 99 },
                                       { "order_id" => 1, "product_id" => 6, "qty" => 2 },
                                       { "order_id" => 2, "product_id" => 5, "qty" => 3 }
                                     ])
    end

    it "negative: a partial composite key raises rather than matching many" do
      before = items(composite)
      expect { composite.update("order_items", { "order_id" => 1, "qty" => 42 }) }
        .to raise_error(ArgumentError, /primary key/)
      expect(items(composite)).to eq(before),
                                  "a partial composite key modified rows - it matched on the first column"
    end

    it "delete accepts a full composite key" do
      composite.delete("order_items", { "order_id" => 1, "product_id" => 5 })
      expect(items(composite)).to eq([
                                       { "order_id" => 1, "product_id" => 6, "qty" => 2 },
                                       { "order_id" => 2, "product_id" => 5, "qty" => 3 }
                                     ])
    end
  end
end
