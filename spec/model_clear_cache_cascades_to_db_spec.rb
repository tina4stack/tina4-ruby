# frozen_string_literal: true
#
# Regression: Model.clear_cache must invalidate BOTH cache layers.
#
# 3.13.105 (parity port of PY-06-22). Before the fix, ORM.clear_cache cleared
# only the ORM-layer tag cache (@query_cache) and left the DB-layer cache
# alone — so a caller using it as a manual escape hatch (an out-of-band write,
# a race with another process, a deliberate refresh) still read stale rows
# from db.fetch on the next query.
#
# The invariant: after Model.clear_cache, db.cache_stats[:size] on this
# model's bound connection is 0. Named positive AND negative cases;
# mutation-proven by reverting the cascade call — both fail.
#
# NOT a mock: real SQLite Database instances, real query-cache round-trip.
#
# A bare constant declared inside an RSpec.describe block lands on Object
# (GLOBAL); everything this spec needs lives at the top level with a
# distinctive name or is prefixed inside a helper module.

require "spec_helper"
require "tmpdir"

# Two ORM subclasses, uniquely named for this file so the global spec suite
# never sees a Widget/Product/Thing collision.
class ClearCacheCascadeWidget622 < Tina4::ORM
  table_name "widgets_622"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

module ClearCacheCascadeContract
  ENV_KEYS = %w[
    TINA4_AUTO_CACHING TINA4_AUTO_CACHING_TTL
    TINA4_DB_CACHE TINA4_DB_CACHE_TTL
    TINA4_DB_CACHE_BACKEND TINA4_DB_CACHE_URL
  ].freeze

  module_function

  def around(example)
    saved = ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    # Both cache layers opted in — the only combination in which the bug is
    # reachable.
    ENV["TINA4_AUTO_CACHING"] = "true"
    ENV["TINA4_DB_CACHE"] = "true"
    ENV["TINA4_DB_CACHE_BACKEND"] = "memory"
    ENV.delete("TINA4_DB_CACHE_URL")
    begin
      example.run
    ensure
      ENV_KEYS.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
    end
  end

  def build_db(path)
    db = Tina4::Database.new("sqlite:///" + path)
    db.execute("CREATE TABLE IF NOT EXISTS widgets_622 " \
               "(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    db.execute("DELETE FROM widgets_622")
    db.execute("INSERT INTO widgets_622 (name) VALUES ('one'), ('two')")
    db
  end
end

RSpec.describe "Model.clear_cache cascades to the DB layer" do
  around(:each) { |example| ClearCacheCascadeContract.around(example) }

  around(:each) do |example|
    Dir.mktmpdir("tina4-clearcache") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  before(:each) do
    # Reset the ORM tag cache between examples: it is a process-wide store
    # (mirrors Python's module-level _query_cache), so leftovers from another
    # example would silently answer this one's queries.
    Tina4::ORM.query_cache.clear
    ClearCacheCascadeWidget622.instance_variable_set(:@db, nil)
  end

  it "positive: clear_cache cascades to db.cache_clear" do
    db = ClearCacheCascadeContract.build_db(File.join(@tmp, "cascade.db"))
    ClearCacheCascadeWidget622.db = db

    ClearCacheCascadeWidget622.cached("SELECT * FROM widgets_622", ttl: 60)
    expect(db.cache_stats[:size]).to be > 0,
                                     "prime failed: the db-layer cache did not populate on the cached() read"

    ClearCacheCascadeWidget622.clear_cache

    expect(db.cache_stats[:size]).to eq(0),
                                     "clear_cache did not cascade to db.cache_clear; the db-layer cache " \
                                     "still holds stale rows, so a caller using clear_cache as a manual " \
                                     "escape hatch after an out-of-band write reads pre-write rows"
  end

  it "negative: clear_cache leaves an UNRELATED db's cache alone" do
    # A model bound to db_a calling clear_cache MUST NOT touch db_b — the
    # cascade is scoped to this model's own connection (matching how writes
    # already behave).
    db_a = ClearCacheCascadeContract.build_db(File.join(@tmp, "a.db"))
    db_b = ClearCacheCascadeContract.build_db(File.join(@tmp, "b.db"))
    ClearCacheCascadeWidget622.db = db_a
    db_a.fetch("SELECT * FROM widgets_622")
    db_b.fetch("SELECT * FROM widgets_622")
    expect(db_a.cache_stats[:size]).to be > 0, "prime: db_a should have a cached read"
    expect(db_b.cache_stats[:size]).to be > 0, "prime: db_b should have a cached read"

    ClearCacheCascadeWidget622.clear_cache

    expect(db_a.cache_stats[:size]).to eq(0),
                                       "db_a is the Widget's bound connection and must have been cleared"
    expect(db_b.cache_stats[:size]).to be > 0,
                                       "db_b (unrelated connection) must NOT be cleared by " \
                                       "ClearCacheCascadeWidget622.clear_cache"
  end
end
