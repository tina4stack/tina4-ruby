# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Regression tests for the pool round-robin transaction bug.
#
# Before the driver-pin fix, every Database method call rotated to a
# different pooled connection. Result: start_transaction began on driver A,
# the executes autocommitted on drivers B and C, and the final commit/
# rollback landed on driver D — meaningless. Rollbacks were silently
# no-op'd and writes leaked through.
#
# These tests fail (3 rows leaking despite rollback) before the
# Thread.current[@tx_pin_key] pin in Database#current_driver and pass after
# it. Mirrors tina4-python TestPoolTransactionAtomicity.
RSpec.describe Tina4::Database, "pool transaction atomicity" do
  let(:tmpdir) { Dir.mktmpdir }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe "with pool > 0" do
    let(:db_path) { File.join(tmpdir, "pool.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path, pool: 4) }

    before do
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
      db.commit rescue nil
    end

    after do
      db.close rescue nil
    end

    it "rolls back every insert under pool>0" do
      db.start_transaction
      db.execute("INSERT INTO t (id, val) VALUES (1, 'a')")
      db.execute("INSERT INTO t (id, val) VALUES (2, 'b')")
      db.execute("INSERT INTO t (id, val) VALUES (3, 'c')")
      db.rollback

      row = db.fetch_one("SELECT count(*) AS n FROM t")
      n = (row["n"] || row[:n]).to_i
      expect(n).to eq(0),
        "rollback() leaked #{n} of 3 rows under pool=4 — driver pin not honoured"
    end

    it "commits every insert as one atomic batch under pool>0" do
      db.start_transaction
      db.execute("INSERT INTO t (id, val) VALUES (10, 'x')")
      db.execute("INSERT INTO t (id, val) VALUES (20, 'y')")
      db.execute("INSERT INTO t (id, val) VALUES (30, 'z')")
      db.commit

      row = db.fetch_one("SELECT count(*) AS n FROM t")
      n = (row["n"] || row[:n]).to_i
      expect(n).to eq(3), "commit() persisted only #{n} of 3 rows under pool=4"
    end

    it "releases the driver pin after commit (round-robin resumes)" do
      db.start_transaction
      pinned_during = db.current_driver
      expect(db.current_driver.equal?(pinned_during)).to be true
      db.commit

      seen = []
      8.times { seen << db.current_driver.object_id }
      expect(seen.uniq.length).to be > 1,
        "after commit() the pin was not released — current_driver never rotated"
    end

    it "releases the driver pin after rollback (round-robin resumes)" do
      db.start_transaction
      db.rollback

      seen = []
      8.times { seen << db.current_driver.object_id }
      expect(seen.uniq.length).to be > 1,
        "after rollback() the pin was not released — current_driver never rotated"
    end

    it "pins to the same driver for every call inside a transaction" do
      db.start_transaction
      drivers = 5.times.map { db.current_driver.object_id }
      db.rollback

      expect(drivers.uniq.length).to eq(1),
        "current_driver rotated #{drivers.uniq.length} times inside a transaction — pin broken"
    end
  end

  describe "with pool = 0 (no regression)" do
    it "single-connection mode still rolls back correctly" do
      path = File.join(tmpdir, "nopool.db")
      d = Tina4::Database.new("sqlite:///" + path, pool: 0)
      d.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
      d.commit rescue nil

      d.start_transaction
      d.execute("INSERT INTO t (id, val) VALUES (1, 'r')")
      d.rollback

      row = d.fetch_one("SELECT count(*) AS n FROM t")
      n = (row["n"] || row[:n]).to_i
      d.close
      expect(n).to eq(0), "pool=0 broke after the pin fix: #{n} rows leaked"
    end

    it "single-connection mode still commits correctly" do
      path = File.join(tmpdir, "nopool_commit.db")
      d = Tina4::Database.new("sqlite:///" + path, pool: 0)
      d.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
      d.commit rescue nil

      d.start_transaction
      d.execute("INSERT INTO t (id, val) VALUES (1, 'a')")
      d.execute("INSERT INTO t (id, val) VALUES (2, 'b')")
      d.commit

      row = d.fetch_one("SELECT count(*) AS n FROM t")
      n = (row["n"] || row[:n]).to_i
      d.close
      expect(n).to eq(2)
    end
  end
end
