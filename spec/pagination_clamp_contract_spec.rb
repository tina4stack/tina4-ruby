# frozen_string_literal: true

# PAGE-DEC-01 pagination clamp + cap - feature 24 (pagination_contract.json).
#
# The audit's PAGE-NEGATIVE-OFFSET finding: `page < 1` was NOT clamped in
# Python/Ruby/Node's AutoCrud list handler, so `offset = (page - 1) * per_page`
# handed the driver a NEGATIVE offset - a hard ERROR on PostgreSQL ("OFFSET
# must not be negative") and a silent 0-offset on SQLite (still wrong: the
# envelope reported page:0). PAGE-NO-MAX-LIMIT: an oversized ?limit=/?per_page=
# was honoured verbatim - a client could request the whole table in one query.
#
# PAGE-DEC-01 (OWNER-DECISIONS.md Batch 4): clamp page >= 1 (so offset is never
# negative) and cap the per-page size at Tina4::AutoCrud::MAX_PER_PAGE (100 -
# the same row cap the ORM/DB family shares, and Node's own DEFAULT_ROW_CAP).
#
# Real SQLite (always) + real PostgreSQL :55432 tina4/tina4 (when reachable,
# TINA4_TEST_PG_* to relocate; a real skip, never `describe ..., if:`, so
# TINA4_REQUIRE_SERVICES catches a postgres that should be up but is not)
# through the REAL AutoCrud list handler via the in-process TestClient. No
# mocks. The page=0 case is the one that matters on PostgreSQL: before the fix
# it is a genuine driver ERROR, not just a wrong number.
#
# Mutation-proof (manual): revert the `page = [page, 1].max` clamp in
# lib/tina4/auto_crud.rb and "page zero clamps to page one" goes RED on
# postgres with "OFFSET must not be negative" surfaced through the response;
# restore the clamp and it is GREEN again.

require "spec_helper"
require "socket"

# Declared at TOP LEVEL, never inside RSpec.describe: a class/constant assigned
# in a describe block lands on Object (global) and clobbers other spec files.
# Unique name + unique table so it can never collide with CrudItem et al.
class PageClampWidget < Tina4::ORM
  table_name "page_clamp_widget"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
end

RSpec.describe "Pagination clamp + cap (feature 24, PAGE-DEC-01)" do
  # Unique-suffixed constants: a bare constant inside an RSpec.describe leaks
  # onto Object, so name them so they cannot collide with another spec's.
  PGCLAMP_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  PGCLAMP_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  PGCLAMP_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  PGCLAMP_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  PGCLAMP_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  def self.pgclamp_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  PGCLAMP_REACHABLE = pgclamp_reachable?(PGCLAMP_HOST, PGCLAMP_PORT)

  let(:client) { Tina4::TestClient.new }

  def pgclamp_url
    "postgres://#{PGCLAMP_HOST}:#{PGCLAMP_PORT}/#{PGCLAMP_DB}"
  end

  def sqlite_db(tmp_dir)
    Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "pageclamp.db"))
  end

  def pg_db
    Tina4::Database.new(pgclamp_url, username: PGCLAMP_USER, password: PGCLAMP_PASS)
  end

  def seed(db, engine)
    db.execute("DROP TABLE IF EXISTS page_clamp_widget")
    ddl = if engine == :postgres
      "CREATE TABLE page_clamp_widget (id SERIAL PRIMARY KEY, name TEXT NOT NULL)"
    else
      "CREATE TABLE page_clamp_widget (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)"
    end
    db.execute(ddl)
    5.times { |i| db.execute("INSERT INTO page_clamp_widget (name) VALUES (?)", ["w#{i}"]) }
  end

  def register(db)
    Tina4.bind_database(db)
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
    Tina4::AutoCrud.generate_routes_for(PageClampWidget)
  end

  # Slug the release audit greps for: page_zero_clamps_to_page_one
  shared_examples "page zero clamps to page one" do
    it "page zero clamps to page one" do
      %w[0 -3].each do |bad_page|
        response = client.get("/api/page_clamp_widget?page=#{bad_page}&per_page=10")
        expect(response.status).to eq(200), "page=#{bad_page} must not error (got #{response.status}): #{response.body}"

        body = response.json
        expect(body["page"]).to eq(1), "page=#{bad_page} -> envelope page #{body['page']}, want 1"
        expect(body["offset"]).to eq(0), "page=#{bad_page} -> envelope offset #{body['offset']}, want 0"
        expect(body["records"].length).to eq(5)
      end
    end
  end

  # Slug the release audit greps for: oversized_per_page_is_capped
  shared_examples "oversized per page is capped" do
    it "oversized per page is capped" do
      response = client.get("/api/page_clamp_widget?per_page=1000000")
      expect(response.status).to eq(200)
      body = response.json
      expect(body["per_page"]).to eq(100)
      expect(body["limit"]).to eq(100)

      # The alternate ?limit= spelling (no ?page=) takes the same cap.
      response2 = client.get("/api/page_clamp_widget?limit=999999")
      body2 = response2.json
      expect(body2["limit"]).to eq(100)
      expect(body2["per_page"]).to eq(100)
    end
  end

  context "sqlite" do
    around do |example|
      Dir.mktmpdir("tina4_pageclamp") do |tmp_dir|
        @db = sqlite_db(tmp_dir)
        seed(@db, :sqlite)
        register(@db)
        example.run
        @db.close
      end
    end

    include_examples "page zero clamps to page one"
    include_examples "oversized per page is capped"
  end

  context "postgres" do
    before do
      skip "no reachable postgres at #{PGCLAMP_HOST}:#{PGCLAMP_PORT} (set TINA4_TEST_PG_*)" unless PGCLAMP_REACHABLE
      @db = pg_db
      seed(@db, :postgres)
      register(@db)
    end

    after do
      @db.execute("DROP TABLE IF EXISTS page_clamp_widget")
      @db.close
    rescue StandardError
      nil
    end

    include_examples "page zero clamps to page one"
    include_examples "oversized per page is capped"
  end
end
