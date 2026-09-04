# frozen_string_literal: true
#
# ModelCollection -- ORM read queries carry the query total (ADR-0064).
#
# Real SQLite, real ORM writes, no mocks. Mirrors the Python reference
# tests/test_orm_model_collection.py case-for-case: where / select / find (filter
# form) / all / with_trashed return an Array-compatible collection that ALSO
# exposes get_total_records and the same seven-key to_paginate envelope as
# DatabaseResult. find(pk) / find_by_id / select_one stay single.
#
# MUTATION-PROVEN: temporarily sourcing the total from the page size instead of
# the DatabaseResult COUNT probe (hydrate_collection: total: instances.size) makes
# "keeps the total outside pagination" go red (20 != 250), then restore. So the
# probe wiring is a real gate, not a tautology.

require "spec_helper"

# Distinct top-level names + explicit table names so nothing collides with
# another spec's constants (spec_helper warns hard about global-constant leaks).
class MCProduct < Tina4::ORM
  table_name "mc_products"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :category
  numeric_field :price
end

class MCNote < Tina4::ORM
  table_name "mc_notes"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :body
end

RSpec.describe "ModelCollection (ADR-0064) -- the query total travels with the page" do
  # 250 books + 7 music, seeded ONCE via real ORM saves (all the cases below are
  # read-only). A temp-file DB, not :memory:, so the count probe and the main read
  # always share one on-disk database (the proven orm_row_cap_spec pattern).
  before(:all) do
    @tmp_dir = Dir.mktmpdir("tina4_model_collection")
    @db = Tina4::Database.new("sqlite:///" + File.join(@tmp_dir, "mc.db"))
    Tina4.bind_database(@db)
    MCProduct.create_table
    250.times { |i| MCProduct.new(name: "book#{i}", category: "books", price: i).save }
    7.times   { |i| MCProduct.new(name: "song#{i}", category: "music", price: i).save }
    # Sanity: the fixture really holds 257 rows, else the totals below pass for
    # the wrong reason.
    expect(@db.fetch_one("SELECT COUNT(*) AS c FROM mc_products")[:c]).to eq(257)
  end

  after(:all) do
    @db.close
    FileUtils.rm_rf(@tmp_dir)
  end

  # Specs run in random order and every spec binds its own DB, so re-bind ours
  # before each example to guarantee it is the active connection.
  before(:each) { Tina4.bind_database(@db) }

  # ── the core promise: page is capped, total is the whole filtered set ──────

  it "keeps the total outside pagination" do
    rows = MCProduct.where("category = ?", ["books"], limit: 20, offset: 40)
    expect(rows).to be_a(Tina4::ModelCollection)
    expect(rows).to be_a(Array)                 # non-breaking
    expect(rows.length).to eq(20)               # the page
    expect(rows.get_total_records).to eq(250)   # the whole matching set
  end

  it "all carries the table total" do
    rows = MCProduct.all(limit: 10)
    expect(rows.length).to eq(10)
    expect(rows.get_total_records).to eq(257)   # 250 books + 7 music
  end

  it "select carries the total" do
    rows = MCProduct.select("SELECT * FROM mc_products WHERE category = ?", ["music"], limit: 5)
    expect(rows.length).to eq(5)
    expect(rows.get_total_records).to eq(7)
  end

  it "find (filter form) carries the total" do
    rows = MCProduct.find({ "category" => "books" }, limit: 10)
    expect(rows).to be_a(Tina4::ModelCollection)
    expect(rows.length).to eq(10)
    expect(rows.get_total_records).to eq(250)
  end

  it "find (pk form) still returns a single model, not a collection" do
    one = MCProduct.find(1)
    expect(one).not_to be_nil
    expect(one).not_to be_a(Tina4::ModelCollection)  # PK lookup is a single model
    expect(one.id).to eq(1)
  end

  it "find_by_id and select_one stay single (never a collection)" do
    expect(MCProduct.find_by_id(2)).to be_a(MCProduct)
    expect(MCProduct.find_by_id(2)).not_to be_a(Tina4::ModelCollection)
    one = MCProduct.select_one("SELECT * FROM mc_products WHERE id = ?", [3])
    expect(one).to be_a(MCProduct)
    expect(one).not_to be_a(Tina4::ModelCollection)
  end

  # ── to_paginate -- the uniform seven-key envelope ──────────────────────────

  it "to_paginate returns the seven canonical keys, and total/total_pages match db.fetch" do
    rows = MCProduct.where("category = ?", ["books"], limit: 20, offset: 40)
    page = rows.to_paginate

    expect(page.keys).to match_array(
      %i[records total page per_page total_pages limit offset]
    )
    expect(page[:total]).to eq(250)
    expect(page[:per_page]).to eq(20)
    expect(page[:page]).to eq(3)              # offset 40 / 20 + 1
    expect(page[:total_pages]).to eq(13)      # ceil(250 / 20)
    expect(page[:offset]).to eq(40)
    expect(page[:records].length).to eq(20)

    # records are hashes of the same shape as db.fetch(...).to_paginate, and
    # total / total_pages are IDENTICAL to the same-query DatabaseResult envelope.
    raw = @db.fetch("SELECT * FROM mc_products WHERE category = ?", ["books"],
                    limit: 20, offset: 40).to_paginate
    expect(page[:total]).to eq(raw[:total])
    expect(page[:total_pages]).to eq(raw[:total_pages])
    expect(page[:records].first).to be_a(Hash)
    # Same field set (normalised to strings: to_h and the driver both key by
    # symbol here, but the guarantee is the field NAMES match, so the client JSON
    # is uniform).
    expect(page[:records].first.keys.map(&:to_s).sort)
      .to eq(raw[:records].first.keys.map(&:to_s).sort)
  end

  # ── edge cases ─────────────────────────────────────────────────────────────

  it "an empty page (offset past the end) still reports the total" do
    rows = MCProduct.where("category = ?", ["books"], limit: 20, offset: 1000)
    expect(rows.length).to eq(0)
    expect(rows.get_total_records).to eq(250)
    expect(rows.to_paginate[:total]).to eq(250)
  end

  it "zero matches -> total is zero" do
    rows = MCProduct.where("category = ?", ["nothing"])
    expect(rows.to_a).to eq([])
    expect(rows.get_total_records).to eq(0)
    expect(rows.to_paginate[:total]).to eq(0)
    expect(rows.to_paginate[:total_pages]).to eq(1)  # ceil(0/per_page) floored to 1
  end

  # ── Array compatibility (nothing existing breaks) ──────────────────────────

  it "IS an Array -- each / index / map / slice / count all unchanged" do
    rows = MCProduct.where("category = ?", ["books"], limit: 3)
    expect(rows.length).to eq(3)
    expect(rows[0].category).to eq("books")               # index -> model instance
    expect(rows.map(&:category)).to eq(["books"] * 3)     # iterate / map
    expect(rows[1..].length).to eq(2)                     # slice
    expect(rows).to all(be_a(MCProduct))

    seen = []
    rows.each { |p| seen << p.category }                  # each still yields models
    expect(seen).to eq(["books"] * 3)
    expect(rows.count).to eq(3)                           # Array#count NOT shadowed
    expect(rows.to_a).to be_a(Array)
  end

  it "serialises to a JSON array of model hashes (response.json parity)" do
    rows = MCProduct.where("category = ?", ["music"], limit: 2)
    parsed = JSON.parse(JSON.generate(rows.map(&:to_h)))
    expect(parsed).to be_a(Array)
    expect(parsed.length).to eq(2)
    expect(parsed.first).to include("id", "name", "category", "price")
  end
end

RSpec.describe "ModelCollection soft-delete totals (ADR-0064)" do
  # Fresh 5-row DB per example; one row soft-deleted. Cheap enough to seed each time.
  around(:each) do |example|
    dir = Dir.mktmpdir("tina4_model_collection_soft")
    db = Tina4::Database.new("sqlite:///" + File.join(dir, "mc_notes.db"))
    Tina4.bind_database(db)
    MCNote.create_table
    5.times { |i| MCNote.new(body: "n#{i}").save }
    example.run
    db.close
    FileUtils.rm_rf(dir)
  end

  it "excludes soft-deleted rows from the live total, includes them in with_trashed" do
    MCNote.find(1).delete                              # soft-delete one

    live = MCNote.where("1=1")
    expect(live.get_total_records).to eq(4)            # deleted row excluded

    trashed = MCNote.with_trashed("1=1")
    expect(trashed.get_total_records).to eq(5)         # deleted row included
  end
end
