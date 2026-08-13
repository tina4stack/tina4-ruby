# frozen_string_literal: true
#
# ORM result caching contract -- feature 25 (CACHE-DEC-01).
#
# Shared conformance fixture:
#   tina4-documentation/plan/v3/fixtures/ormcache_contract.json
#
# Proves, against a REAL SQLite database with REAL rows and REAL ORM writes (NO
# mocks, NO doubles), that Model.cached:
#
#   * caches within the TTL (a DIRECT db write between two reads is NOT seen),
#     and ttl<=0 means NO-CACHE (every read hits the DB);
#   * is busted by a save/delete/force_delete/restore THROUGH THE ORM;
#   * is tagged by every table it touches, so a write to a JOINed table busts it
#     while a write to an UNRELATED table leaves it intact.
#
# "It cached" is proven POSITIVELY: the ONLY way the second within-TTL read can
# be stale is that it came from the cache. The direct write is a raw
# `db.execute("UPDATE ...")`, which never touches the model query cache.

require "spec_helper"
require "tmpdir"

class CacheAuthorModel < Tina4::ORM
  table_name "cacheauthor"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
end

class CacheBookModel < Tina4::ORM
  self.soft_delete = true
  table_name "cachebook"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title
  integer_field :author_id
  integer_field :is_deleted, default: 0
end

RSpec.describe "ORM result caching contract (feature 25)" do
  BOOK_SQL = "SELECT id, title FROM cachebook WHERE is_deleted = 0"
  ALL_BOOK_SQL = "SELECT id, title FROM cachebook"
  # A JOIN that touches BOTH tables and filters on the author's name, so a
  # rename of the author changes the RESULT SET (row count).
  JOIN_SQL = "SELECT b.id FROM cachebook b JOIN cacheauthor a ON a.id = b.author_id WHERE a.name = ?"

  let(:tmp_dir) { Dir.mktmpdir("tina4_ormcache") }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "ormcache.db")) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE cacheauthor (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    db.execute("CREATE TABLE cachebook (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, author_id INTEGER, is_deleted INTEGER DEFAULT 0)")
    db.commit
    # The model query cache is process-wide (shared on ORM) -- reset the tags
    # this spec uses so a prior example's entry can never be served against this
    # fresh DB file.
    CacheBookModel.clear_cache
    CacheAuthorModel.clear_cache
  end

  after(:each) do
    CacheBookModel.clear_cache
    CacheAuthorModel.clear_cache
    db.close
    FileUtils.remove_entry(tmp_dir)
  end

  def new_book(title, author_id)
    CacheBookModel.new(title: title, author_id: author_id).save
  end

  def raw_update(sql)
    db.execute(sql)
    db.commit
  end

  # ── caches within ttl; ttl=0 = no-cache ─────────────────────────────────

  it "a cached query is served from cache within ttl" do
    new_book("A", 0)

    first = CacheBookModel.cached(BOOK_SQL, ttl: 60)
    expect(first.map(&:title)).to eq(["A"])

    # Direct db write behind the cache's back (NOT an ORM write -> no bust).
    raw_update("UPDATE cachebook SET title = 'CHANGED' WHERE id = 1")

    second = CacheBookModel.cached(BOOK_SQL, ttl: 60)
    # Stale on purpose: the only way this is "A" is that it came from cache.
    expect(second.map(&:title)).to eq(["A"])
  end

  it "ttl zero does not cache" do
    new_book("A", 0)

    first = CacheBookModel.cached(BOOK_SQL, ttl: 0)
    expect(first.map(&:title)).to eq(["A"])

    raw_update("UPDATE cachebook SET title = 'CHANGED' WHERE id = 1")

    second = CacheBookModel.cached(BOOK_SQL, ttl: 0)
    # ttl<=0 stores nothing, so this read hit the DB and sees the change.
    expect(second.map(&:title)).to eq(["CHANGED"])
  end

  # ── busts on every ORM write ────────────────────────────────────────────

  it "a save through the orm busts the cached read" do
    new_book("A", 0)

    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).map(&:title)).to eq(["A"])

    book = CacheBookModel.select_one("SELECT * FROM cachebook WHERE id = 1")
    book.title = "B"
    book.save

    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).map(&:title)).to eq(["B"])
  end

  it "a delete through the orm busts the cached read" do
    new_book("A", 0)
    new_book("B", 0)

    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).length).to eq(2)

    CacheBookModel.select_one("SELECT * FROM cachebook WHERE id = 1").delete # soft

    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).length).to eq(1)
  end

  it "a force delete through the orm busts the cached read" do
    new_book("A", 0)
    new_book("B", 0)

    expect(CacheBookModel.cached(ALL_BOOK_SQL, ttl: 60).length).to eq(2)

    CacheBookModel.select_one("SELECT * FROM cachebook WHERE id = 1").force_delete

    expect(CacheBookModel.cached(ALL_BOOK_SQL, ttl: 60).length).to eq(1)
  end

  it "a restore through the orm busts the cached read" do
    new_book("A", 0)
    book = CacheBookModel.select_one("SELECT * FROM cachebook WHERE id = 1")
    book.delete # soft-delete -> is_deleted = 1

    # Cached view of ACTIVE rows is empty...
    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60)).to be_empty

    book.restore # ORM write -> must bust

    # ...and the restore is seen, not the stale empty result.
    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).map(&:title)).to eq(["A"])
  end

  # ── tagged by table (cross-table bust; unrelated left intact) ────────────

  it "a write to a joined table busts the cross table cached read" do
    CacheAuthorModel.new(name: "A1").save
    new_book("A", 1)

    expect(CacheBookModel.cached(JOIN_SQL, ["A1"], ttl: 60).length).to eq(1)

    author = CacheAuthorModel.select_one("SELECT * FROM cacheauthor WHERE id = 1")
    author.name = "A2"
    author.save # writes cacheauthor -> must bust the cross-table cached JOIN

    expect(CacheBookModel.cached(JOIN_SQL, ["A1"], ttl: 60).length).to eq(0)
  end

  it "a write to an unrelated table leaves the cached read intact" do
    CacheAuthorModel.new(name: "A1").save
    new_book("A", 1)

    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).map(&:title)).to eq(["A"])

    # Change the book row directly (no ORM bust), then write an UNRELATED table.
    raw_update("UPDATE cachebook SET title = 'RAW' WHERE id = 1")
    author = CacheAuthorModel.select_one("SELECT * FROM cacheauthor WHERE id = 1")
    author.name = "A2"
    author.save # writes cacheauthor only -> must NOT bust the cachebook query

    # The cachebook entry survived (tag-scoped bust, not a wholesale flush).
    expect(CacheBookModel.cached(BOOK_SQL, ttl: 60).map(&:title)).to eq(["A"])
  end
end
