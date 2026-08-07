# frozen_string_literal: true

require "spec_helper"

# Model for the AutoCrud REST pagination-envelope contract (ADR-0043).
#
# Declared at TOP LEVEL, never inside RSpec.describe: a class/constant assigned
# in a describe block lands on Object (global) and clobbers other spec files.
# Unique name + unique table so it can never collide with CrudItem et al.
class PaginateRestItem < Tina4::ORM
  table_name "paginate_rest_items"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  string_field :category, nullable: false
end

# The AutoCrud REST list endpoint (GET /api/{table}) must return EXACTLY the
# seven canonical snake_case keys ADR-0043 fixed to_paginate() to — it may not
# build its own divergent envelope. Real SQLite, real ORM, real RackApp via the
# in-process TestClient. No mocks.
RSpec.describe "AutoCrud REST list pagination envelope (ADR-0043)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_paginate_rest") }
  let(:db_path) { File.join(tmp_dir, "paginate.db") }
  let(:db)      { Tina4::Database.new("sqlite:///" + db_path) }
  let(:client)  { Tina4::TestClient.new }

  before(:each) do
    Tina4.bind_database(db)
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
    db.execute(
      "CREATE TABLE IF NOT EXISTS paginate_rest_items " \
      "(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, category TEXT NOT NULL)"
    )
    # A real 250-row table. ids 1..120 are category "A" (120 rows), ids 121..250
    # are category "B" (130 rows). Insert in one transaction so 250 rows do not
    # fsync 250 times.
    db.transaction do |conn|
      250.times do |i|
        conn.execute(
          "INSERT INTO paginate_rest_items (name, category) VALUES (?, ?)",
          ["Item #{i + 1}", i < 120 ? "A" : "B"]
        )
      end
    end
    Tina4::AutoCrud.generate_routes_for(PaginateRestItem)
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  # Slug the release audit greps for:
  # paginate-rest-list-envelope-is-the-seven-keys
  it "paginate rest list envelope is the seven keys on a real 250-row table (page 2 of 3)" do
    # per_page=100 over 250 rows => 3 pages. Fetch page 2 (ids 101..200). sort=id
    # makes the row order deterministic across engines.
    response = client.get("/api/paginate_rest_items?per_page=100&page=2&sort=id")
    expect(response.status).to eq(200)

    body = response.json

    # (1) EXACTLY the seven canonical snake_case keys — no data/count/columns/
    # totalPages/perPage/has_next/has_prev. Sorted compare asserts the SET, not
    # the key order.
    expect(body.keys.sort).to eq(%w[limit offset page per_page records total total_pages])

    # (2) total is the TRUE total for the filter (a COUNT(*) probe), NEVER the 100
    # rows this page returned. This is the ADR-0043 half that reaches the read
    # path, so it gets its own hard assertion.
    expect(body["total"]).to eq(250)

    # (3) page/per_page/total_pages/limit/offset all derived from the query that ran.
    expect(body["page"]).to eq(2)                 # floor(100 / 100) + 1
    expect(body["per_page"]).to eq(100)           # the limit
    expect(body["total_pages"]).to eq(3)          # ceil(250 / 100)
    expect(body["limit"]).to eq(100)
    expect(body["offset"]).to eq(100)             # (page - 1) * per_page

    # (4) records are THIS page's rows, verbatim — all 100 of them, ids 101..200,
    # never re-sliced to zero and never the whole table.
    expect(body["records"].length).to eq(100)
    expect(body["records"].first["id"]).to eq(101)
    expect(body["records"].last["id"]).to eq(200)
  end

  # The FILTERED branch is the same envelope, and its `total` is a real COUNT
  # over the filter — not rows-returned, and not capped at the ORM's default
  # limit:100 (the two bugs the old handler had: total = records.length after a
  # capped where(), then an in-memory re-slice).
  it "filtered list envelope is the seven keys with a true count over the filter (not capped at 100)" do
    # 120 rows match category=A. per_page=50 => 3 pages of the filtered set.
    # Fetch page 2 (matching ids 51..100).
    response = client.get("/api/paginate_rest_items?filter[category]=A&per_page=50&page=2&sort=id")
    expect(response.status).to eq(200)

    body = response.json

    expect(body.keys.sort).to eq(%w[limit offset page per_page records total total_pages])
    # 120, proving the true COUNT over the filter — the old code reported 100
    # (where() capped at limit:100) or 50 (rows returned on this page).
    expect(body["total"]).to eq(120)
    expect(body["page"]).to eq(2)
    expect(body["per_page"]).to eq(50)
    expect(body["total_pages"]).to eq(3)          # ceil(120 / 50)
    expect(body["limit"]).to eq(50)
    expect(body["offset"]).to eq(50)
    expect(body["records"].length).to eq(50)
    expect(body["records"].first["id"]).to eq(51)
    expect(body["records"].last["id"]).to eq(100)
    expect(body["records"].all? { |r| r["category"] == "A" }).to be true
  end
end
