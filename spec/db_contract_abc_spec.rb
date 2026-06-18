# frozen_string_literal: true

# DB-contract fixes A + B + C (v3.13.37) — fail-loud / correctness contract.
#
# These complete the contract that Database#execute already sets (it raises on a
# SQL error). Three themes, all engine-agnostic so they run on SQLite locally
# and in CI with no database server. Mirrors
# tina4-python/tests/test_db_contract_abc.py.
#
#   A — fetch / fetch_one / fetch_all FAIL LOUD on a SQL error (parity with
#       execute): a bad query RAISES (never silently returns empty/nil), and the
#       cause is captured on db.get_error / @last_error. A failed read is never
#       stored in the query cache.
#
#   B — get_next_id is ATOMIC: N concurrent callers for the same table get all
#       DISTINCT ids (no duplicate primary keys). Exercised with threads on
#       SQLite.
#
#   C — commit failure RE-RAISES (and populates @last_error), RETAINS the
#       transaction pin so a follow-up rollback lands on the SAME connection,
#       and clears the pin only on success / rollback. Nested start_transaction
#       is guarded (depth counter) so a double-begin doesn't silently leave a
#       connection mid-transaction.

require "spec_helper"
require "tmpdir"

RSpec.describe "Tina4::Database DB-contract A/B/C" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmpdir, "contract.db")) }

  # Read the per-thread transaction pin / depth without adding public API —
  # the same thread-locals Database#start_transaction/commit/rollback manage.
  def tx_pin(database)
    Thread.current[database.instance_variable_get(:@tx_pin_key)]
  end

  def tx_depth(database)
    Thread.current[database.instance_variable_get(:@tx_depth_key)]
  end

  before do
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    db.commit rescue nil
  end

  after do
    db.close rescue nil
    FileUtils.rm_rf(tmpdir)
  end

  # ── THEME A — fetch / fetch_one fail loud + capture last_error ────────────

  it "fetch raises on bad SQL and populates get_error" do
    expect { db.fetch("SELECT * FROM no_such_table") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
  end

  it "fetch_one raises on bad SQL and populates get_error" do
    # fetch_one used to raise but leave get_error nil (it bypassed the
    # error-capturing wrapper). It must FAIL LOUD too.
    expect { db.fetch_one("SELECT * FROM no_such_table") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
  end

  it "fetch_all raises on bad SQL (never returns [])" do
    expect { db.fetch_all("SELECT * FROM no_such_table") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
  end

  it "fetch_one on a typo'd column raises — not an empty/nil 'no row'" do
    expect { db.fetch_one("SELECT no_such_column FROM widget") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
  end

  it "a best-effort probe failure does not mask a successful main query" do
    db.execute("INSERT INTO widget (id, name) VALUES (1, 'a')")
    db.execute("INSERT INTO widget (id, name) VALUES (2, 'b')")
    db.commit rescue nil
    result = db.fetch("SELECT * FROM widget ORDER BY id")
    expect(result.count).to eq(2)
    names = result.records.map { |r| r[:name] || r["name"] }
    expect(names).to eq(%w[a b])
    expect(db.get_error).to be_nil
  end

  it "a successful read clears last_error after a prior failed read set it" do
    expect { db.fetch("SELECT * FROM no_such_table") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
    db.fetch("SELECT * FROM widget")
    expect(db.get_error).to be_nil
  end

  it "a failed read is NOT cached (no buried empty served from cache)" do
    ENV["TINA4_AUTO_CACHING"] = "true"
    database = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "cache.db"))
    begin
      # Query a table that doesn't exist yet — must raise, not cache an empty.
      expect { database.fetch("SELECT * FROM late_table") }.to raise_error(StandardError)
      # Now create it and insert a row.
      database.execute("CREATE TABLE late_table (id INTEGER PRIMARY KEY, name TEXT)")
      database.execute("INSERT INTO late_table (id, name) VALUES (1, 'real')")
      database.commit rescue nil
      # The identical query must now return the real row — proving the failed
      # read was NOT cached as empty.
      result = database.fetch("SELECT * FROM late_table")
      expect(result.count).to eq(1)
      expect(result.records[0][:name] || result.records[0]["name"]).to eq("real")
    ensure
      database.close rescue nil
      ENV.delete("TINA4_AUTO_CACHING")
    end
  end

  # ── THEME B — atomic get_next_id (no duplicate ids under concurrency) ─────

  it "get_next_id increments sequentially and seeds from MAX(pk)" do
    db.execute("INSERT INTO widget (id, name) VALUES (5, 'seed')")
    db.commit rescue nil
    ids = 4.times.map { db.get_next_id("widget") }
    expect(ids).to eq([6, 7, 8, 9])
  end

  it "REQUIRED: N concurrent get_next_id calls return ALL DISTINCT ids" do
    database = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "concurrent.db"))
    database.execute("CREATE TABLE thing (id INTEGER PRIMARY KEY, name TEXT)")
    database.commit rescue nil

    n = 100
    results = []
    errors = []
    mutex = Mutex.new

    threads = n.times.map do
      Thread.new do
        begin
          value = database.get_next_id("thing")
          mutex.synchronize { results << value }
        rescue => e
          mutex.synchronize { errors << e.message }
        end
      end
    end
    threads.each(&:join)

    expect(errors).to eq([]), "get_next_id raised under concurrency: #{errors.first(3).inspect}"
    expect(results.length).to eq(n)
    # The core guarantee: every returned id is DISTINCT — no duplicate PKs.
    expect(results.uniq.length).to eq(n), "duplicate ids returned under concurrency!"
    # And because the table started empty, the ids are exactly 1..n.
    expect(results.sort).to eq((1..n).to_a)
    database.close rescue nil
  end

  # ── THEME C — commit failure handling + transaction pin guard ─────────────

  it "REQUIRED: a failed commit raises, retains the pin, then rollback cleans up" do
    drv = db.current_driver
    original_commit = drv.method(:commit)
    calls = { n: 0 }

    # Monkeypatch the driver's commit to fail exactly once.
    drv.define_singleton_method(:commit) do
      calls[:n] += 1
      raise RuntimeError, "simulated commit failure" if calls[:n] == 1

      original_commit.call
    end

    begin
      db.start_transaction
      db.execute("INSERT INTO widget (id, name) VALUES (1, 'x')")
      pin_before = tx_pin(db)
      expect(pin_before).not_to be_nil

      expect { db.commit }.to raise_error(RuntimeError, /simulated commit failure/)

      # last_error captured for get_error.
      expect(db.get_error).not_to be_nil
      expect(db.get_error).to include("simulated commit failure")

      # Pin RETAINED on failure so rollback reaches the same connection.
      expect(tx_pin(db)).to equal(pin_before)

      # The follow-up rollback cleans up and releases the pin.
      db.rollback
      expect(tx_pin(db)).to be_nil
    ensure
      drv.singleton_class.send(:remove_method, :commit) rescue nil
    end
  end

  it "the pin is released on a successful commit" do
    db.start_transaction
    expect(tx_pin(db)).not_to be_nil
    db.execute("INSERT INTO widget (id, name) VALUES (1, 'ok')")
    db.commit
    expect(tx_pin(db)).to be_nil
    expect(db.fetch("SELECT * FROM widget").count).to eq(1)
  end

  it "rollback always clears the pin (terminal cleanup)" do
    db.start_transaction
    db.execute("INSERT INTO widget (id, name) VALUES (1, 'x')")
    db.rollback
    expect(tx_pin(db)).to be_nil
    # The insert was rolled back.
    expect(db.fetch("SELECT * FROM widget").count).to eq(0)
  end

  it "a nested start_transaction is guarded (depth counter, single real txn)" do
    db.start_transaction
    expect(tx_depth(db)).to eq(1)
    pin = tx_pin(db)

    db.start_transaction # nested — guarded, no re-begin / no rotation
    expect(tx_depth(db)).to eq(2)
    expect(tx_pin(db)).to equal(pin)

    db.execute("INSERT INTO widget (id, name) VALUES (1, 'nested')")

    db.commit # inner — just unwinds the depth, does NOT release the pin
    expect(tx_depth(db)).to eq(1)
    expect(tx_pin(db)).to equal(pin)

    db.commit # outer — real commit, releases the pin
    expect(tx_depth(db)).to be_nil
    expect(tx_pin(db)).to be_nil

    # The write persisted through the single real transaction.
    expect(db.fetch("SELECT * FROM widget").count).to eq(1)
  end
end
