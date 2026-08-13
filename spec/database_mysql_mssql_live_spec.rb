# frozen_string_literal: true
#
# Live MySQL + MSSQL cross-engine tests (issue #262).
#
# Mirrors tina4-python/tests/test_database_drivers.py (TestMySQLLive /
# TestMSSQLLive): each engine creates a temp table with a boolean column,
# inserts rows with a RAW Ruby true/false, fetches back, and asserts the
# boolean round-trips, then drops the table. Two regression examples lock in
# the two driver fixes shipped in the working tree:
#
#   1. MysqlDriver#connect rewrites host "localhost" -> "127.0.0.1" when a port
#      is present so mysql2/libmysqlclient takes the TCP path instead of the
#      /tmp/mysql.sock UNIX socket (parity with PHP MySQLAdapter::rewriteHostForTcp).
#      The regression example connects via a "localhost:PORT" URL — without the
#      fix libmysqlclient would try the socket and raise
#      "Can't connect ... through socket '/tmp/mysql.sock'".
#
#   2. MssqlDriver#interpolate_params coerces a raw Ruby true->"1", false->"0",
#      and Time/DateTime->quoted ISO-8601, so a boolean no longer renders as the
#      bareword `true` ("Invalid column name 'true'"). The regression example
#      binds a raw boolean and asserts it does NOT raise that error.
#
# Both describe blocks skip cleanly when the service isn't reachable OR the
# optional driver gem (mysql2 / tiny_tds, in the OPTIONAL :databases bundle
# group) can't be loaded. The skip reason contains "MySQL not reachable" /
# "MSSQL not reachable" so it matches the spec_helper gate's unavailable-hint
# pattern: under TINA4_REQUIRE_SERVICES (CI provisions both since #262) that
# skip becomes a hard suite failure.

require "spec_helper"
require "socket"

# ── MySQL connection config (canonical TINA4_TEST_MYSQL_* convention) ─────────
MYSQL_LIVE_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
MYSQL_LIVE_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
MYSQL_LIVE_USER = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
MYSQL_LIVE_PASS = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
MYSQL_LIVE_DB   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

# ── MSSQL connection config (canonical TINA4_TEST_MSSQL_* convention) ─────────
MSSQL_LIVE_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
MSSQL_LIVE_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
MSSQL_LIVE_USER = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
MSSQL_LIVE_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
MSSQL_LIVE_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

def mysql_live_reachable?
  TCPSocket.new(MYSQL_LIVE_HOST, MYSQL_LIVE_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def mysql2_gem_available?
  require "mysql2"
  true
rescue LoadError
  false
end

def mssql_live_reachable?
  TCPSocket.new(MSSQL_LIVE_HOST, MSSQL_LIVE_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def tiny_tds_gem_available?
  require "tiny_tds"
  true
rescue LoadError
  false
end

RSpec.describe "Live MySQL round-trips (#262)" do
  before(:all) do
    @skip_reason =
      if !mysql2_gem_available?
        "mysql2 gem not installed (MySQL driver unavailable) — install the :databases bundle group"
      elsif !mysql_live_reachable?
        "MySQL not reachable at #{MYSQL_LIVE_HOST}:#{MYSQL_LIVE_PORT}"
      end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "mysql://#{MYSQL_LIVE_HOST}:#{MYSQL_LIVE_PORT}/#{MYSQL_LIVE_DB}",
      username: MYSQL_LIVE_USER, password: MYSQL_LIVE_PASS
    )
    @db.execute("DROP TABLE IF EXISTS _tina4_live_test")
    @db.execute(
      "CREATE TABLE _tina4_live_test " \
      "(id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100), active TINYINT)"
    )
  end

  after(:each) do
    next unless @db

    begin
      @db.execute("DROP TABLE IF EXISTS _tina4_live_test")
    ensure
      begin
        @db.close
      rescue StandardError
        nil
      end
    end
  end

  it "reports the resolved engine name as mysql" do
    expect(@db.get_database_type).to eq("mysql")
  end

  it "inserts and fetches a real row" do
    result = @db.insert("_tina4_live_test", { name: "MySQLTest" })
    expect(result.success?).to be true
    expect(result.last_id).not_to be_nil
    row = @db.fetch_one("SELECT * FROM _tina4_live_test WHERE name = ?", ["MySQLTest"])
    expect(row).not_to be_nil
    expect(row[:name]).to eq("MySQLTest")
  end

  it "db.get_last_id returns the AUTO_INCREMENT id of the last insert (regression #262)" do
    # BUG #262: after db.insert the result hash had last_id:1 (correct), but
    # db.get_last_id returned 0 — the Database facade re-read the mysql2 driver's
    # last_id AFTER the autocommit COMMIT (a separate query on the same
    # connection) had clobbered it to 0. The driver now snapshots @connection.last_id
    # AT WRITE TIME on every INSERT (mirroring Python's mysql.py which captures
    # cursor.lastrowid in execute()), so get_last_id keeps the inserted id.
    result = @db.insert("_tina4_live_test", { name: "row1" })
    expect(result.last_id).to eq(1)
    expect(@db.get_last_id).to eq(1)

    result2 = @db.insert("_tina4_live_test", { name: "row2" })
    expect(result2.last_id).to eq(2)
    expect(@db.get_last_id).to eq(2)

    # A direct execute INSERT then get_last_id must also surface the new id.
    @db.execute("INSERT INTO _tina4_live_test (name) VALUES (?)", ["row3"])
    expect(@db.get_last_id).to eq(3)

    # A follow-up read (or any non-insert statement) must NOT clobber it back to 0.
    @db.fetch("SELECT * FROM _tina4_live_test ORDER BY id")
    expect(@db.get_last_id).to eq(3)
  end

  it "round-trips a RAW Ruby boolean as a TINYINT 1/0" do
    # Locks in the cross-framework bind contract (#262): a raw Ruby bool binds
    # as 1/0 against a TINYINT column, never crashing or stringifying. Mirrors
    # the Python (mysql-connector) and Node (mysql2) boolean-coercion behaviour.
    @db.execute("INSERT INTO _tina4_live_test (name, active) VALUES (?, ?)", ["on", true])
    @db.execute("INSERT INTO _tina4_live_test (name, active) VALUES (?, ?)", ["off", false])
    rows = @db.fetch("SELECT active FROM _tina4_live_test ORDER BY id").records
    expect(rows.map { |r| r[:active] }).to eq([1, 0])
  end

  it "connects over TCP for a localhost:PORT URL (regression: /tmp/mysql.sock trap)" do
    # MysqlDriver#connect rewrites host "localhost" -> "127.0.0.1" when a port
    # is present, forcing the TCP path. Without that rewrite libmysqlclient
    # would try the UNIX socket and raise
    # "Can't connect ... through socket '/tmp/mysql.sock'" against a TCP-only
    # MySQL. A successful connection + trivial query over the localhost:PORT URL
    # proves the rewrite is in effect.
    tcp_db = Tina4::Database.new(
      "mysql://#{MYSQL_LIVE_HOST}:#{MYSQL_LIVE_PORT}/#{MYSQL_LIVE_DB}",
      username: MYSQL_LIVE_USER, password: MYSQL_LIVE_PASS
    )
    begin
      row = tcp_db.fetch_one("SELECT 1 AS one")
      expect(row[:one]).to eq(1)
    ensure
      tcp_db.close
    end
  end
end

RSpec.describe "Live MSSQL round-trips (#262)" do
  before(:all) do
    @skip_reason =
      if !tiny_tds_gem_available?
        "tiny_tds gem not installed (MSSQL driver unavailable) — install the :databases bundle group"
      elsif !mssql_live_reachable?
        "MSSQL not reachable at #{MSSQL_LIVE_HOST}:#{MSSQL_LIVE_PORT}"
      end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "mssql://#{MSSQL_LIVE_HOST}:#{MSSQL_LIVE_PORT}/#{MSSQL_LIVE_DB}",
      username: MSSQL_LIVE_USER, password: MSSQL_LIVE_PASS
    )
    @db.execute("IF OBJECT_ID('_tina4_live_test', 'U') IS NOT NULL DROP TABLE _tina4_live_test")
    # active is declared NULL explicitly: this SQL Server treats a bare BIT as
    # NOT NULL, so a name-only insert would otherwise reject the implicit NULL.
    @db.execute(
      "CREATE TABLE _tina4_live_test " \
      "(id INT IDENTITY(1,1) PRIMARY KEY, name VARCHAR(100), active BIT NULL)"
    )
  end

  after(:each) do
    next unless @db

    begin
      @db.execute("IF OBJECT_ID('_tina4_live_test', 'U') IS NOT NULL DROP TABLE _tina4_live_test")
    ensure
      begin
        @db.close
      rescue StandardError
        nil
      end
    end
  end

  it "reports the resolved engine name as mssql" do
    expect(@db.get_database_type).to eq("mssql")
  end

  it "inserts and fetches a real row" do
    result = @db.insert("_tina4_live_test", { name: "MSSQLTest" })
    expect(result.success?).to be true
    # MSSQL's OFFSET/FETCH paging (how fetch applies a limit) requires an
    # ORDER BY, so read the row back through an ordered fetch rather than
    # fetch_one (which appends limit 1 with no ORDER BY).
    rows = @db.fetch(
      "SELECT name FROM _tina4_live_test WHERE name = ? ORDER BY id", ["MSSQLTest"]
    ).records
    expect(rows.length).to eq(1)
    expect(rows.first[:name]).to eq("MSSQLTest")
  end

  it "db.insert(...).last_id AND db.get_last_id return the new IDENTITY (regression #262)" do
    # BUG #262: db.insert returned last_id:nil AND db.get_last_id:nil because the
    # driver ran "SELECT SCOPE_IDENTITY()" as a SEPARATE tiny_tds batch — and
    # SCOPE_IDENTITY() is batch-scoped, so in a later batch it is always NULL. The
    # driver now runs the INSERT and SELECT SCOPE_IDENTITY() in ONE batch and
    # caches the id at write time (mirroring Python's mssql.py, which reads
    # SCOPE_IDENTITY() on the same cursor immediately after the INSERT).
    result = @db.insert("_tina4_live_test", { name: "row1" })
    expect(result.last_id).to eq(1)
    expect(@db.get_last_id).to eq(1)

    result2 = @db.insert("_tina4_live_test", { name: "row2" })
    expect(result2.last_id).to eq(2)
    expect(@db.get_last_id).to eq(2)

    # A direct execute INSERT then get_last_id must also surface the new id.
    @db.execute("INSERT INTO _tina4_live_test (name) VALUES (?)", ["row3"])
    expect(@db.get_last_id).to eq(3)

    # A follow-up ordered fetch must NOT clobber the cached id (and the count-probe
    # path in fetch must return the right row count for an ORDER BY query).
    rows = @db.fetch("SELECT id, name FROM _tina4_live_test ORDER BY id")
    expect(rows.count).to eq(3)
    expect(@db.get_last_id).to eq(3)
  end

  it "round-trips a RAW Ruby boolean against a BIT column" do
    # Locks in the bind contract (#262): a raw Ruby bool binds to a BIT column
    # without rendering as the bareword `true`. tiny_tds reads a BIT back as a
    # native Ruby true/false, so we normalise via (value ? true : false) and
    # assert [true, false] — parity with the Python master's
    # [bool(r["active"]) ...] == [True, False].
    @db.execute("INSERT INTO _tina4_live_test (name, active) VALUES (?, ?)", ["on", true])
    @db.execute("INSERT INTO _tina4_live_test (name, active) VALUES (?, ?)", ["off", false])
    rows = @db.fetch("SELECT active FROM _tina4_live_test ORDER BY id").records
    expect(rows.map { |r| r[:active] ? true : false }).to eq([true, false])
  end

  it "binds a raw boolean param WITHOUT 'Invalid column name true' (regression)" do
    # MssqlDriver#interpolate_params coerces a raw Ruby true->"1" / false->"0"
    # at the bind boundary. Without that coercion the bareword `true` would be
    # interpolated into the SQL and SQL Server would raise
    # "Invalid column name 'true'". A clean insert proves the coercion fires.
    expect do
      @db.execute("INSERT INTO _tina4_live_test (name, active) VALUES (?, ?)", ["raw", true])
    end.not_to raise_error
    rows = @db.fetch(
      "SELECT active FROM _tina4_live_test WHERE name = ? ORDER BY id", ["raw"]
    ).records
    expect(rows.first[:active] ? true : false).to be true
  end
end
