# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Lock-in / contract tests for the autocommit durability fix (v3.13.39).
#
# Parity with Python/PHP/Node: autocommit is ON by default. A standalone write
# (execute/insert/update/delete made OUTSIDE an explicit transaction) is
# committed by the framework so it actually persists — visible on a fresh
# connection / a different pooled connection. An UNSET TINA4_AUTOCOMMIT is
# treated as TRUE; TINA4_AUTOCOMMIT=false is strict manual mode. An explicit
# start_transaction()/commit() block stays atomic — a per-statement commit is
# suppressed while the thread holds the transaction pin, so rollback still
# discards every write.
#
# These would catch a silent drift back to "only commit when TINA4_AUTOCOMMIT
# is explicitly truthy" (writes silently not persisting) or a regression that
# broke explicit-transaction atomicity.
RSpec.describe Tina4::Database, "autocommit durability" do
  let(:tmpdir) { Dir.mktmpdir }

  around do |example|
    saved = ENV.key?("TINA4_AUTOCOMMIT") ? ENV["TINA4_AUTOCOMMIT"] : :unset
    example.run
    if saved == :unset
      ENV.delete("TINA4_AUTOCOMMIT")
    else
      ENV["TINA4_AUTOCOMMIT"] = saved
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "default (TINA4_AUTOCOMMIT unset)" do
    it "treats an unset TINA4_AUTOCOMMIT as autocommit ON" do
      ENV.delete("TINA4_AUTOCOMMIT")
      db = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "default.db"))
      expect(db.instance_variable_get(:@autocommit)).to be true
      db.close
    end

    it "persists a standalone write so a brand-new connection sees it" do
      ENV.delete("TINA4_AUTOCOMMIT")
      path = File.join(tmpdir, "persist.db")

      writer = Tina4::Database.new("sqlite:///" + path)
      writer.execute("CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")
      writer.insert("widgets", { id: 1, name: "bolt" })
      writer.update("widgets", { name: "nut" }, { id: 1 })
      writer.close

      # A genuinely fresh Database instance / connection — proves the write was
      # committed, not just buffered on the writer's connection.
      reader = Tina4::Database.new("sqlite:///" + path)
      row = reader.fetch_one("SELECT name FROM widgets WHERE id = 1")
      reader.close
      expect(row["name"] || row[:name]).to eq("nut")
    end

    it "makes a pooled standalone write visible across round-robin connections" do
      ENV.delete("TINA4_AUTOCOMMIT")
      db = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "pool.db"), pool: 4)
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")
      db.insert("t", { id: 1, val: "a" })
      db.insert("t", { id: 2, val: "b" })

      counts = 8.times.map do
        row = db.fetch_one("SELECT count(*) AS n FROM t")
        (row["n"] || row[:n]).to_i
      end
      db.close
      expect(counts).to all(eq(2)),
        "standalone write not committed — not visible from a round-robin connection (#{counts.inspect})"
    end
  end

  describe "explicit transactions stay atomic" do
    it "rolls back every write in an explicit transaction even with autocommit ON" do
      ENV.delete("TINA4_AUTOCOMMIT")
      path = File.join(tmpdir, "txn_rollback.db")
      db = Tina4::Database.new("sqlite:///" + path)
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")

      db.start_transaction
      db.execute("INSERT INTO t (id, val) VALUES (1, 'a')")
      db.insert("t", { id: 2, val: "b" })
      db.rollback

      row = db.fetch_one("SELECT count(*) AS n FROM t")
      n = (row["n"] || row[:n]).to_i
      db.close
      expect(n).to eq(0),
        "autocommit leaked #{n} rows out of a rolled-back explicit transaction — atomicity broken"
    end

    it "commits an explicit transaction as one atomic batch" do
      ENV.delete("TINA4_AUTOCOMMIT")
      path = File.join(tmpdir, "txn_commit.db")
      db = Tina4::Database.new("sqlite:///" + path)
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")

      db.start_transaction
      db.insert("t", { id: 10, val: "x" })
      db.insert("t", { id: 20, val: "y" })
      db.commit

      row = db.fetch_one("SELECT count(*) AS n FROM t")
      n = (row["n"] || row[:n]).to_i
      db.close
      expect(n).to eq(2)
    end
  end

  describe "TINA4_AUTOCOMMIT=false (strict manual mode)" do
    it "reads the flag as OFF" do
      ENV["TINA4_AUTOCOMMIT"] = "false"
      db = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "strict.db"))
      expect(db.instance_variable_get(:@autocommit)).to be false
      db.close
    end

    it "does NOT issue a framework commit after a standalone write" do
      # The durability commit is gated on @autocommit. With it OFF the framework
      # must not commit on the caller's behalf — the write's persistence is left
      # entirely to the explicit commit()/the driver. (We can't assert "leaks"
      # on SQLite because the sqlite3 gem commits each non-BEGIN statement at the
      # driver level regardless; the engine-agnostic invariant is that the
      # FRAMEWORK does not call driver.commit for the standalone write.)
      ENV["TINA4_AUTOCOMMIT"] = "false"
      db = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "strict.db"))
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")

      drv = db.current_driver
      allow(db).to receive(:current_driver).and_return(drv)
      expect(drv).not_to receive(:commit)
      db.insert("t", { id: 1, val: "a" })
      db.close
    end

    it "DOES issue a framework commit after a standalone write when autocommit is ON" do
      ENV.delete("TINA4_AUTOCOMMIT")
      db = Tina4::Database.new("sqlite:///" + File.join(tmpdir, "on.db"))
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)")

      drv = db.current_driver
      allow(db).to receive(:current_driver).and_return(drv)
      expect(drv).to receive(:commit).at_least(:once).and_call_original
      db.insert("t", { id: 1, val: "a" })
      db.close
    end
  end
end

# Lock-in test for the ORM table-name pluralization default (v3.13.39).
#
# Canonical default is OFF (matching the Python master): the table name is the
# bare class name lowercased. Opt in with a truthy TINA4_ORM_PLURAL_TABLE_NAMES.
RSpec.describe "ORM table-name pluralization default" do
  around do |example|
    saved = ENV.key?("TINA4_ORM_PLURAL_TABLE_NAMES") ? ENV["TINA4_ORM_PLURAL_TABLE_NAMES"] : :unset
    example.run
    if saved == :unset
      ENV.delete("TINA4_ORM_PLURAL_TABLE_NAMES")
    else
      ENV["TINA4_ORM_PLURAL_TABLE_NAMES"] = saved
    end
  end

  # A fresh anonymous ORM subclass per example so @table_name memoization on a
  # named class can't leak between examples.
  def widget_model
    Class.new(Tina4::ORM) do
      def self.name
        "Widget"
      end
    end
  end

  it "does NOT pluralize by default (unset)" do
    ENV.delete("TINA4_ORM_PLURAL_TABLE_NAMES")
    expect(widget_model.table_name).to eq("widget")
  end

  it "does NOT pluralize when explicitly false" do
    ENV["TINA4_ORM_PLURAL_TABLE_NAMES"] = "false"
    expect(widget_model.table_name).to eq("widget")
  end

  it "pluralizes only when explicitly enabled" do
    ENV["TINA4_ORM_PLURAL_TABLE_NAMES"] = "true"
    expect(widget_model.table_name).to eq("widgets")
  end
end
