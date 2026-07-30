# frozen_string_literal: true
#
# Lock-in: Model.cached / Model.clear_cache -- parity with the Python master
# (tina4_python/orm/model.py:1077). Ruby was the only framework of the four
# WITHOUT a `cached` method; Python, PHP and Node all had one.
#
# NO MOCKS. Every example runs against a real SQLite file. A cache HIT is proven
# behaviourally rather than by spying: insert a row BEHIND the cache and call
# again with identical arguments. A hit returns the stale pre-insert answer; a
# miss would go to the database and see the new row. That distinguishes hit from
# miss using nothing but real reads and real writes.

require "spec_helper"

class CachedThing < Tina4::ORM
  table_name "cached_things"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
end

# A SECOND model on its own table, to prove the cache is tag-scoped per model
# rather than one shared bucket that any clear_cache flushes wholesale.
class OtherCachedThing < Tina4::ORM
  table_name "other_cached_things"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
end

RSpec.describe "ORM.cached" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_cached") }
  let(:db_path) { File.join(tmp_dir, "cached.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE cached_things (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)")
    db.execute("CREATE TABLE other_cached_things (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)")
    db.commit
    # The cache is process-wide by design (it mirrors Python's module-level
    # _query_cache), so it MUST be cleared between examples or one example's
    # entries silently answer the next one's queries.
    Tina4::ORM.query_cache.clear
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  def seed(count, table: "cached_things")
    count.times { |i| db.execute("INSERT INTO #{table} (label) VALUES (?)", ["row#{i}"]) }
    db.commit
  end

  describe "correctness" do
    it "returns the same rows an uncached select returns" do
      seed(3)
      plain = CachedThing.select("SELECT * FROM cached_things ORDER BY id")
      cached = CachedThing.cached("SELECT * FROM cached_things ORDER BY id")
      expect(cached.length).to eq(3)
      expect(cached.map(&:label)).to eq(plain.map(&:label))
    end

    it "hydrates real model instances, not raw rows" do
      seed(1)
      expect(CachedThing.cached("SELECT * FROM cached_things").first).to be_a(CachedThing)
    end
  end

  describe "it actually caches" do
    it "serves the second identical call from cache, not the database" do
      seed(2)
      first = CachedThing.cached("SELECT * FROM cached_things")
      expect(first.length).to eq(2)

      seed(3) # 5 rows in the table now, behind the cache
      again = CachedThing.cached("SELECT * FROM cached_things")
      expect(again.length).to eq(2) # stale on purpose -- this IS the cache hit
      expect(db.fetch_one("SELECT COUNT(*) AS c FROM cached_things")[:c]).to eq(5)
    end

    it "caches an EMPTY result as a hit, not a miss" do
      # The implementation nil-checks rather than truthiness-checks the lookup.
      # If an empty array were treated as a miss, the query would re-run every
      # call -- worst for exactly the queries caching should help most.
      empty = CachedThing.cached("SELECT * FROM cached_things WHERE label = ?", ["ghost"])
      expect(empty).to eq([])

      db.execute("INSERT INTO cached_things (label) VALUES (?)", ["ghost"])
      db.commit
      expect(CachedThing.cached("SELECT * FROM cached_things WHERE label = ?", ["ghost"])).to eq([])
    end

    it "keys on limit, so a different limit is a different entry" do
      seed(5)
      expect(CachedThing.cached("SELECT * FROM cached_things", limit: 2).length).to eq(2)
      # If limit were left out of the key this would wrongly return the cached 2.
      expect(CachedThing.cached("SELECT * FROM cached_things", limit: 5).length).to eq(5)
    end

    it "keys on params, so different params are different entries" do
      seed(2)
      db.execute("INSERT INTO cached_things (label) VALUES (?)", ["special"])
      db.commit
      by_row0 = CachedThing.cached("SELECT * FROM cached_things WHERE label = ?", ["row0"])
      by_special = CachedThing.cached("SELECT * FROM cached_things WHERE label = ?", ["special"])
      expect(by_row0.first.label).to eq("row0")
      expect(by_special.first.label).to eq("special")
    end
  end

  describe "clear_cache" do
    it "invalidates this model's entries so the next read hits the database" do
      seed(2)
      expect(CachedThing.cached("SELECT * FROM cached_things").length).to eq(2)
      seed(3)

      CachedThing.clear_cache
      expect(CachedThing.cached("SELECT * FROM cached_things").length).to eq(5)
    end

    it "is TAG-SCOPED: clearing one model leaves another model's cache intact" do
      # THE TRIPWIRE for the tags: [name] contract. A cache that ignored tags and
      # flushed everything would pass every other example in this file.
      seed(2)
      seed(2, table: "other_cached_things")
      CachedThing.cached("SELECT * FROM cached_things")
      OtherCachedThing.cached("SELECT * FROM other_cached_things")

      seed(3)
      seed(3, table: "other_cached_things")

      CachedThing.clear_cache
      expect(CachedThing.cached("SELECT * FROM cached_things").length).to eq(5)
      expect(OtherCachedThing.cached("SELECT * FROM other_cached_things").length).to eq(2)
    end
  end

  describe "the store is process-wide, as in the Python master" do
    it "is the SAME cache object for every model" do
      # Python holds _query_cache at module level. A per-class ivar would give
      # each subclass its own store, and cross-model tag isolation above would
      # then pass for the wrong reason.
      expect(CachedThing.query_cache).to be(OtherCachedThing.query_cache)
      expect(CachedThing.query_cache).to be(Tina4::ORM.query_cache)
    end
  end
end
