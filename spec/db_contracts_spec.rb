# frozen_string_literal: true

# Database contract tests - the behaviours apps depend on, locked against drift.
#
# Named after the contracts a real upgrade relies on (and that a silent
# regression like a `execute` change - raise -> return false - would have
# broken):
#
#   * execute() RAISES on a SQL error (never silently returns false), so a
#     failing write propagates and a transaction rolls back.
#   * read-after-write within a request is consistent (the request-scoped cache
#     is off by default and never serves a pre-write value).
#   * get_next_id() is strictly monotonic + unique across repeated calls (no
#     duplicate keys from a cached MAX(id)).
#   * transactions bracket correctly: commit persists, rollback discards.
#
# These run against a real SQLite database. They are engine-agnostic in intent -
# the same contracts are mirrored in the Python/PHP/Node suites
# (tina4-python/tests/test_db_contracts.py). Rows use symbol keys (the Ruby
# driver symbolizes column names).

require "spec_helper"
require "tmpdir"

RSpec.describe "Tina4::Database contracts" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmpdir, "contracts.db")) }

  before do
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER)")
    db.commit rescue nil
  end

  after do
    db.close rescue nil
    FileUtils.rm_rf(tmpdir)
  end

  # -- execute() RAISES (never returns false) ---------------------------------

  describe "execute raises on error" do
    it "raises on a missing table - it does NOT return false" do
      expect { db.execute("INSERT INTO does_not_exist (x) VALUES (1)") }.to raise_error(StandardError)
    end

    it "captures the cause on get_error after the raise" do
      begin
        db.execute("THIS IS NOT VALID SQL")
      rescue StandardError
        # swallow - the real cause must still be readable below
      end
      expect(db.get_error).not_to be_nil
    end

    it "raises on a constraint violation (duplicate PK)" do
      db.execute("INSERT INTO items (id, name) VALUES (1, 'a')")
      db.commit rescue nil
      expect { db.execute("INSERT INTO items (id, name) VALUES (1, 'dup')") }.to raise_error(StandardError)
    end

    it "returns truthy (never false) on a successful write" do
      result = db.execute("INSERT INTO items (name, qty) VALUES ('a', 1)")
      db.commit rescue nil
      expect(result).not_to be false
      expect(result).not_to be_nil
    end
  end

  # -- read-after-write consistency --------------------------------------------

  describe "read after write" do
    it "makes an insert immediately visible" do
      db.execute("INSERT INTO items (name, qty) VALUES ('widget', 5)")
      db.commit rescue nil
      row = db.fetch_one("SELECT name, qty FROM items WHERE name = ?", ["widget"])
      expect(row[:qty]).to eq(5)
    end

    it "makes an update immediately visible" do
      db.execute("INSERT INTO items (id, name, qty) VALUES (1, 'a', 1)")
      db.execute("UPDATE items SET qty = 99 WHERE id = 1")
      db.commit rescue nil
      expect(db.fetch_one("SELECT qty FROM items WHERE id = 1")[:qty]).to eq(99)
    end

    it "MAX(id) reflects the latest write (no stale pre-write cache)" do
      (1..5).each do |i|
        db.execute("INSERT INTO items (id, name) VALUES (?, ?)", [i, "n#{i}"])
        mx = db.fetch_one("SELECT MAX(id) AS m FROM items")[:m]
        expect(mx).to eq(i)
      end
    end
  end

  # -- get_next_id monotonicity + uniqueness ------------------------------------

  describe "get_next_id generator" do
    it "is strictly increasing, unique, and contiguous" do
      ids = Array.new(50) { db.get_next_id("orders") }
      expect(ids).to eq(ids.sort)
      expect(ids.uniq.length).to eq(ids.length)
      ids.each_cons(2) { |a, b| expect(b - a).to eq(1) }
    end

    it "keeps independent sequences per table (both start fresh at 1)" do
      a = db.get_next_id("table_a")
      b = db.get_next_id("table_b")
      expect(a).to eq(1)
      expect(b).to eq(1)
    end
  end

  # -- transaction bracketing ----------------------------------------------------

  describe "transaction bracketing" do
    it "commit persists" do
      db.start_transaction
      db.execute("INSERT INTO items (name) VALUES ('kept')")
      db.commit
      expect(db.fetch_one("SELECT count(*) AS c FROM items WHERE name='kept'")[:c]).to eq(1)
    end

    it "rollback discards" do
      db.execute("INSERT INTO items (name) VALUES ('before')")
      db.commit rescue nil
      db.start_transaction
      db.execute("INSERT INTO items (name) VALUES ('rolled')")
      db.rollback
      expect(db.fetch_one("SELECT count(*) AS c FROM items WHERE name='rolled'")[:c]).to eq(0)
      expect(db.fetch_one("SELECT count(*) AS c FROM items WHERE name='before'")[:c]).to eq(1)
    end

    it "a failed write inside a transaction can be rolled back" do
      db.start_transaction
      db.execute("INSERT INTO items (id, name) VALUES (1, 'a')")
      begin
        db.execute("INSERT INTO items (id, name) VALUES (1, 'dup')") # raises
      rescue StandardError
        db.rollback
      end
      expect(db.fetch_one("SELECT count(*) AS c FROM items")[:c]).to eq(0)
    end
  end
end
