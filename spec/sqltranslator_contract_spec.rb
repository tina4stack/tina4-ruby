# frozen_string_literal: true

# SQL translator literal-safe + BIGINT-autoincrement contract - feature 7
# (sqltranslator_contract.json), parity with
# tina4-python/tests/test_sqltranslator_contract.py.
#
# Locks out a DATA-CORRUPTION defect against REAL databases (NO MOCKS): the
# dialect rewrites (|| -> CONCAT, ILIKE -> LOWER LIKE, TRUE/FALSE -> 1/0) used to
# MANGLE STRING LITERALS - a value of 'a||b', a label 'TRUE', or a LIKE pattern
# that mentions ILIKE was rewritten as if it were SQL, and concat split the WHOLE
# statement on || (`SELECT a || b FROM t` -> `CONCAT(SELECT a, b FROM t)`). The
# rewrites are now literal-safe (mask -> rewrite -> restore) and concat only
# rewrites the operand chain. concat + ilike are now WIRED into the MySQL driver
# (MysqlDriver#translate_dialect on execute_query/execute) so a portable || or
# ILIKE query RUNS on real MySQL (SQLTRANS-DEC-02).
#
# SQLTRANS-DEC-03: a BIGINT ... AUTOINCREMENT DDL now yields a real 64-bit
# auto-increment column (PostgreSQL BIGSERIAL, MySQL BIGINT AUTO_INCREMENT).
#
# Real services on the .99 lab: MySQL :3306 (tina4/tina4 -> tina4_test),
# PostgreSQL :55432 (tina4/tina4 -> tina4_rb). Real skips (never a
# `describe ..., if:` that DROPS examples) so TINA4_REQUIRE_SERVICES catches a
# service that went missing. Constants carry a file-unique _SC suffix so they
# never clobber another spec's globals.
#
# Mutation-proof: revert the literal-safe rewrite and the literal cases go RED;
# revert the PostgreSQL BIGINT branch and the bigint case goes RED.

require "spec_helper"
require "socket"
require "securerandom"

RSpec.describe "SQL translator literal-safe + BIGINT contract (feature 7)" do
  MYSQL_HOST_SC = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MYSQL_PORT_SC = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MYSQL_USER_SC = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
  MYSQL_PASS_SC = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  MYSQL_DB_SC   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

  PG_HOST_SC = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  PG_PORT_SC = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  PG_USER_SC = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  PG_PASS_SC = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  PG_DB_SC   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  def self.tcp_reachable?(host, port)
    TCPSocket.new(host, port).tap(&:close)
    true
  rescue StandardError
    false
  end

  def mysql_db
    unless self.class.tcp_reachable?(MYSQL_HOST_SC, MYSQL_PORT_SC)
      skip "MySQL not reachable at #{MYSQL_HOST_SC}:#{MYSQL_PORT_SC} for the SQL-translator contract"
    end
    Tina4::Database.new("mysql://#{MYSQL_HOST_SC}:#{MYSQL_PORT_SC}/#{MYSQL_DB_SC}",
                        username: MYSQL_USER_SC, password: MYSQL_PASS_SC)
  end

  def pg_db
    unless self.class.tcp_reachable?(PG_HOST_SC, PG_PORT_SC)
      skip "PostgreSQL not reachable at #{PG_HOST_SC}:#{PG_PORT_SC} for the SQL-translator contract"
    end
    Tina4::Database.new("postgres://#{PG_HOST_SC}:#{PG_PORT_SC}/#{PG_DB_SC}",
                        username: PG_USER_SC, password: PG_PASS_SC)
  end

  def table(prefix)
    "tina4_sqltrans_#{prefix}_#{SecureRandom.hex(5)}"
  end

  # ── Invariant 1: literal-safe concat / bool / ilike, RUN on a real engine ──

  it "concat pipes translate outside literals and run" do
    db = mysql_db
    t = table("concat")
    db.execute("CREATE TABLE #{t} (id INTEGER PRIMARY KEY AUTO_INCREMENT, first_name VARCHAR(50), last_name VARCHAR(50))")
    begin
      db.execute("INSERT INTO #{t} (first_name, last_name) VALUES ('Jane', 'Doe')")
      rows = db.fetch("SELECT (first_name || ' ' || last_name) AS fullname FROM #{t}").records
      expect(rows.length).to eq(1)
      expect(rows.first[:fullname]).to eq("Jane Doe")
    ensure
      db.execute("DROP TABLE #{t}")
    end
  end

  it "pipes inside a string literal are preserved" do
    db = mysql_db
    t = table("litpipe")
    db.execute("CREATE TABLE #{t} (id INTEGER PRIMARY KEY AUTO_INCREMENT, data VARCHAR(50))")
    begin
      db.execute("INSERT INTO #{t} (data) VALUES ('a||b')")
      db.execute("INSERT INTO #{t} (data) VALUES ('plain')")
      rows = db.fetch("SELECT id, data FROM #{t} WHERE data = 'a||b'").records
      expect(rows.length).to eq(1)
      expect(rows.first[:data]).to eq("a||b")
    ensure
      db.execute("DROP TABLE #{t}")
    end
  end

  it "ilike pattern with multiple words survives and runs" do
    db = mysql_db
    t = table("ilike")
    db.execute("CREATE TABLE #{t} (id INTEGER PRIMARY KEY AUTO_INCREMENT, bio VARCHAR(100))")
    begin
      db.execute("INSERT INTO #{t} (bio) VALUES ('Loves TWO WORDS and coffee')")
      db.execute("INSERT INTO #{t} (bio) VALUES ('nothing here')")
      rows = db.fetch("SELECT id, bio FROM #{t} WHERE bio ILIKE '%two words%'").records
      expect(rows.length).to eq(1)
      expect(rows.first[:bio]).to include("TWO WORDS")
    ensure
      db.execute("DROP TABLE #{t}")
    end
  end

  it "boolean token inside a string literal is preserved" do
    db = mysql_db
    t = table("boollit")
    db.execute("CREATE TABLE #{t} (id INTEGER PRIMARY KEY AUTO_INCREMENT, flag INTEGER, label VARCHAR(20))")
    begin
      db.execute("INSERT INTO #{t} (flag, label) VALUES (1, 'TRUE')")
      db.execute("INSERT INTO #{t} (flag, label) VALUES (0, 'other')")
      canonical = "SELECT id, label FROM #{t} WHERE flag = TRUE AND label = 'TRUE'"
      translated = Tina4::SQLTranslator.boolean_to_int(canonical)
      expect(translated).to include("flag = 1")
      expect(translated).to include("label = 'TRUE'")
      rows = db.fetch(translated).records
      expect(rows.length).to eq(1)
      expect(rows.first[:label]).to eq("TRUE")
    ensure
      db.execute("DROP TABLE #{t}")
    end
  end

  # ── Invariant 2: BIGINT autoincrement creates a real 64-bit column ──

  def bigint_case(db, engine)
    t = table("bigint")
    ddl = "CREATE TABLE #{t} (id BIGINT PRIMARY KEY AUTOINCREMENT, name VARCHAR(50))"
    db.execute(Tina4::SQLTranslator.auto_increment_syntax(ddl, engine))
    begin
      # Insert with NO id -> must auto-generate (a plain BIGINT PK with the
      # keyword stripped would fail the NOT NULL key here).
      db.execute("INSERT INTO #{t} (name) VALUES ('alpha')")
      row = db.fetch("SELECT id FROM #{t} WHERE name = 'alpha'").records.first
      expect(row).not_to be_nil
      expect(row[:id].to_i).to be >= 1
      # The column is really 64-bit. Result-key casing differs by driver, so read
      # the single value rather than a fixed key.
      type_row = db.fetch("SELECT data_type AS dtype FROM information_schema.columns WHERE table_name = '#{t}' AND column_name = 'id'").records.first
      expect(type_row).not_to be_nil
      expect(type_row.values.first.to_s.downcase).to eq("bigint")
    ensure
      db.execute("DROP TABLE #{t}")
    end
  end

  it "bigint autoincrement creates a real bigint column (postgres)" do
    bigint_case(pg_db, "postgresql")
  end

  it "bigint autoincrement creates a real bigint column (mysql)" do
    bigint_case(mysql_db, "mysql")
  end
end
