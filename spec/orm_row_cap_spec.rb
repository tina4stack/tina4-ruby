# frozen_string_literal: true
#
# Lock-in contract: EVERY ORM read path that takes a `limit:` caps at 100 by default.
#
# Pagination is a default principle in Tina4: an un-paginated read of a table
# that grew to a million rows is a memory and latency incident waiting for
# production. Before this contract the family disagreed with ITSELF about the
# number - Python and PHP capped all/find at 100 but select/where/with_trashed/
# cached/scope at 20, RUBY's all/select/where passed `limit: nil` (which makes
# fetch skip apply_limit entirely, so they returned EVERY row), and Node's
# all/select had no limit parameter at all. Four frameworks, four answers, same
# method names.
#
# One number, everywhere: 100.
#
# These tests are deliberately BEHAVIOURAL, never source-reading. They insert
# 150 rows and count what comes back, so the contract cannot be satisfied by a
# signature that says 100 while the body ignores it, and cannot rot into a grep
# of the default value.
#
# Two paths are EXCLUDED from the cap, on purpose, each with its own test below
# so the exclusion is a decision on the record rather than an oversight:
#
#   * QueryBuilder#get - uncapped since v3.13.39 (ruby#4). A silent default
#     LIMIT 100 there was a data-loss-on-read footgun: `.where(...).get` dropped
#     the 101st row with no signal at all, because get has no `limit:` parameter
#     to make the cap visible. Re-adding it would re-introduce that exact bug.
#   * fetch_all - its name IS the request for every row.
#
# The distinction that reconciles the two groups: a path whose signature
# ADVERTISES `limit:` caps at 100 (visible, documented, overridable in the
# call); a path with NO limit parameter must never cap, because there the cap
# can only ever be silent.
#
# Also pins a REAL BUG found while writing this: `scope` defined a singleton
# method taking `limit:`/`offset:` and then called `where(filter_sql, params)`
# WITHOUT passing either, so `User.active(limit: 5)` silently ignored the
# argument it accepted.
#
# Mirrors tests/test_orm_row_cap.py (the Python master).

require "spec_helper"

class CapWidget < Tina4::ORM
  table_name "cap_widgets"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
  integer_field :is_deleted
end

class CapWidgetSoft < Tina4::ORM
  table_name "cap_widgets"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
  integer_field :is_deleted
end

RSpec.describe "ORM default row cap is 100" do
  ROWS = 150
  CAP  = 100

  let(:tmp_dir) { Dir.mktmpdir("tina4_row_cap") }
  let(:db_path) { File.join(tmp_dir, "row_cap.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute(
      "CREATE TABLE cap_widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, " \
      "label TEXT, is_deleted INTEGER DEFAULT 0)"
    )
    ROWS.times { |i| db.execute("INSERT INTO cap_widgets (label, is_deleted) VALUES (?, 0)", ["w#{i}"]) }
    db.commit
    # Sanity: the fixture really does exceed the cap, else every assertion
    # below would pass for the wrong reason.
    expect(db.fetch_one("SELECT COUNT(*) AS c FROM cap_widgets")[:c]).to eq(ROWS)
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe "the default cap on every path that advertises limit:" do
    it "all returns 100" do
      # Was `limit: nil`, which made fetch skip apply_limit -> ALL 150 rows.
      expect(CapWidget.all.length).to eq(CAP)
    end

    it "where returns 100" do
      expect(CapWidget.where("1=1").length).to eq(CAP)
    end

    it "select returns 100" do
      expect(CapWidget.select("SELECT * FROM cap_widgets").length).to eq(CAP)
    end

    it "with_trashed returns 100" do
      # Was 20.
      expect(CapWidgetSoft.with_trashed.length).to eq(CAP)
    end

    it "a scope-generated method returns 100" do
      CapWidget.scope(:every, "1=1")
      expect(CapWidget.every.length).to eq(CAP)
    end

    it "db.fetch returns 100 records" do
      # .records, NOT .count - `count` is the TOTAL matching rows (what
      # pagination needs) and stays 150 regardless of truncation.
      expect(db.fetch("SELECT * FROM cap_widgets").records.length).to eq(CAP)
    end
  end

  describe "the negative half: the cap is a DEFAULT, not a ceiling" do
    # Without these, a hardcoded LIMIT 100 would satisfy every test above.

    it "honours a smaller explicit limit" do
      expect(CapWidget.all(limit: 7).length).to eq(7)
      expect(CapWidget.where("1=1", [], limit: 7).length).to eq(7)
      expect(CapWidget.select("SELECT * FROM cap_widgets", [], limit: 7).length).to eq(7)
      expect(CapWidgetSoft.with_trashed("1=1", [], limit: 7).length).to eq(7)
    end

    it "reaches past the cap with a larger explicit limit" do
      expect(CapWidget.all(limit: ROWS).length).to eq(ROWS)
      expect(CapWidget.where("1=1", [], limit: ROWS).length).to eq(ROWS)
      expect(db.fetch("SELECT * FROM cap_widgets", [], limit: ROWS).records.length).to eq(ROWS)
    end

    it "a scope-generated method HONOURS its limit: argument" do
      # THE BUG: scope defined `do |limit: 20, offset: 0|` and then called
      # `where(filter_sql, params)` without either, so the argument it
      # advertised was accepted and silently discarded.
      CapWidget.scope(:every_capped, "1=1")
      expect(CapWidget.every_capped(limit: 5).length).to eq(5)
    end

    it "a scope-generated method HONOURS its offset: argument" do
      CapWidget.scope(:every_offset, "1=1")
      first_page = CapWidget.every_offset(limit: 5)
      second_page = CapWidget.every_offset(limit: 5, offset: 5)
      expect(second_page.length).to eq(5)
      expect(second_page.map(&:id)).not_to eq(first_page.map(&:id))
    end
  end

  describe "the deliberate exclusions" do
    # A path with NO limit parameter must stay UNCAPPED: a cap the signature
    # cannot express is a silent cap, which is the footgun.

    it "QueryBuilder#get returns every row" do
      # v3.13.39 removed a silent LIMIT 100 here. If this goes red, it is back.
      expect(Tina4::QueryBuilder.from_table("cap_widgets", db: db).get.records.length).to eq(ROWS)
    end

    it "QueryBuilder#get honours an explicit limit" do
      expect(Tina4::QueryBuilder.from_table("cap_widgets", db: db).limit(9).get.records.length).to eq(9)
    end
  end
end
