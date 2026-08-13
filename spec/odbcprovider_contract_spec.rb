# frozen_string_literal: true

# ODBC provider contract -- feature 13 (ODBC-DEC-01 provision a REAL ODBC source
# + run the shared write-path fixture through it; ODBC-DEC-02 the latent fixes).
#
# Pins the ODBC write-path behaviours against a REAL ODBC source, no mocks. The
# SAME cases are proven in all four frameworks; the shared fixture is
# tina4-documentation/plan/v3/fixtures/odbcprovider_contract.json.
#
# ODBC is the generic escape hatch; its query/CRUD path had NEVER run against a
# real ODBC source, so every finding was latent. The lab provisions unixODBC +
# the PostgreSQL ODBC driver (psqlodbc), and this spec drives the write path.
#
#   * ODBC-CONNECT: ODBC::Database.new(string) routes to SQLConnect (a DSN NAME),
#     so a DRIVER={...}/DSN=... connection string raised "Invalid string or buffer
#     length" - the adapter could never connect with a connection string. Fixed to
#     #drvconnect (SQLDriverConnect).
#   * ODBC-PK-STUB: columns() reported primary_key=false for every column, so a
#     PK-keyed update(table, data) with no explicit filter could not introspect the
#     key. Fixed to read the ODBC catalog (SQLPrimaryKeys via #primary_keys).
#   * ODBC-FAILLOUD (cross-language lock): a fetch on a bad query RAISES.
#   * ODBC-NODE-QUIRKS (cross-language lock): a string-WHERE update targets the
#     right rows.
#
# TINA4_TEST_ODBC_DSN is the connection-string body (after odbc:///); unset ->
# skip. TINA4_TEST_ODBC_AUTH_DSN (a password-protected source, no UID/PWD) +
# TINA4_TEST_ODBC_USERNAME/_PASSWORD drive the credentials case.

require "spec_helper"

RSpec.describe "ODBC provider contract" do
  before(:all) { @dsn = ENV["TINA4_TEST_ODBC_DSN"] }

  around(:each) do |example|
    if @dsn.nil? || @dsn.empty?
      skip "TINA4_TEST_ODBC_DSN not set (needs a live ODBC source)"
    else
      example.run
    end
  end

  # Read a value by column name regardless of whether the driver keys the row by
  # Symbol or String.
  def val(row, key)
    row[key.to_sym] || row[key.to_s]
  end

  def db
    Tina4::Database.new("odbc:///#{@dsn}")
  end

  # A plain table with an explicit INTEGER primary key. ODBC has no reliable
  # last-insert-id, so the write-path fixture supplies the key explicitly - which
  # is exactly what exercises the PK-catalog introspection.
  def make_table(conn, name, pk = "id")
    conn.execute("DROP TABLE IF EXISTS #{name}")
    conn.execute("CREATE TABLE #{name} (#{pk} INTEGER PRIMARY KEY, name VARCHAR(50))")
  end

  # ---- ODBC-DEC-01: SELECT round-trips real rows ----------------------

  it "a select returns rows" do
    conn = db
    make_table(conn, "odbc_rb_select")
    conn.insert("odbc_rb_select", { "id" => 1, "name" => "alpha" })
    conn.insert("odbc_rb_select", { "id" => 2, "name" => "beta" })
    conn.insert("odbc_rb_select", { "id" => 3, "name" => "gamma" })
    result = conn.fetch("SELECT id, name FROM odbc_rb_select ORDER BY id")
    expect(result.count).to eq(3)
    expect(result.map { |r| val(r, "name") }).to eq(%w[alpha beta gamma])
    conn.close
  end

  it "an insert round trips on a fresh connection" do
    conn = db
    make_table(conn, "odbc_rb_ins")
    conn.insert("odbc_rb_ins", { "id" => 1, "name" => "x" })
    reader = db
    row = reader.fetch_one("SELECT name FROM odbc_rb_ins WHERE id = ?", [1])
    expect(row).not_to be_nil
    expect(val(row, "name")).to eq("x")
    reader.close
    conn.close
  end

  # ---- ODBC-PK-STUB: a PK-keyed update introspects the real PK --------

  it "a pk keyed update with no filter works" do
    conn = db
    make_table(conn, "odbc_rb_pk")
    conn.insert("odbc_rb_pk", { "id" => 1, "name" => "one" })
    conn.insert("odbc_rb_pk", { "id" => 2, "name" => "two" })
    conn.update("odbc_rb_pk", { "id" => 1, "name" => "ONE" })
    rows = {}
    conn.fetch("SELECT id, name FROM odbc_rb_pk").each { |r| rows[val(r, "id").to_i] = val(r, "name") }
    expect(rows[1]).to eq("ONE")
    expect(rows[2]).to eq("two")
    conn.close
  end

  it "a non id primary key update works" do
    conn = db
    make_table(conn, "odbc_rb_pk2", "thing_key")
    conn.insert("odbc_rb_pk2", { "thing_key" => 7, "name" => "seven" })
    conn.update("odbc_rb_pk2", { "thing_key" => 7, "name" => "SEVEN" })
    row = conn.fetch_one("SELECT name FROM odbc_rb_pk2 WHERE thing_key = ?", [7])
    expect(val(row, "name")).to eq("SEVEN")
    conn.close
  end

  # ---- feature 4: a filterless write is guarded -----------------------

  it "a filterless update is guarded" do
    conn = db
    make_table(conn, "odbc_rb_guard")
    conn.insert("odbc_rb_guard", { "id" => 1, "name" => "keep" })
    expect { conn.update("odbc_rb_guard", { "name" => "WIPED" }) }.to raise_error(ArgumentError)
    row = conn.fetch_one("SELECT name FROM odbc_rb_guard WHERE id = ?", [1])
    expect(val(row, "name")).to eq("keep")
    conn.close
  end

  it "a filterless delete is guarded" do
    conn = db
    make_table(conn, "odbc_rb_guard_del")
    conn.insert("odbc_rb_guard_del", { "id" => 1, "name" => "keep" })
    expect { conn.delete("odbc_rb_guard_del") }.to raise_error(ArgumentError)
    expect(conn.fetch("SELECT id FROM odbc_rb_guard_del").count).to eq(1)
    conn.close
  end

  # ---- ODBC-FAILLOUD: a fetch on a bad query RAISES -------------------

  it "a fetch on a bad query fails loud" do
    conn = db
    expect { conn.fetch("SELECT * FROM odbc_rb_table_that_does_not_exist_xyz") }.to raise_error(StandardError)
    expect { conn.fetch_one("SELECT * FROM odbc_rb_table_that_does_not_exist_xyz") }.to raise_error(StandardError)
    # A good query on the same connection still works.
    expect(val(conn.fetch_one("SELECT 1 AS one"), "one").to_i).to eq(1)
    conn.close
  end

  # ---- ODBC-NODE-QUIRKS (cross-language lock): string-WHERE update ----

  it "a string where update targets the right rows" do
    conn = db
    make_table(conn, "odbc_rb_strwhere")
    (1..4).each { |i| conn.insert("odbc_rb_strwhere", { "id" => i, "name" => "orig" }) }
    conn.update("odbc_rb_strwhere", { "name" => "Z" }, "id <= ?", [3])
    rows = {}
    conn.fetch("SELECT id, name FROM odbc_rb_strwhere").each { |r| rows[val(r, "id").to_i] = val(r, "name") }
    expect(rows[1]).to eq("Z")
    expect(rows[2]).to eq("Z")
    expect(rows[3]).to eq("Z")
    expect(rows[4]).to eq("orig")
    conn.close
  end

  # ---- credentials are honoured ---------------------------------------

  it "credentials passed as params are honoured" do
    auth = ENV["TINA4_TEST_ODBC_AUTH_DSN"]
    user = ENV["TINA4_TEST_ODBC_USERNAME"]
    pass = ENV["TINA4_TEST_ODBC_PASSWORD"]
    skip "TINA4_TEST_ODBC_AUTH_DSN / _USERNAME / _PASSWORD not set" if auth.nil? || auth.empty? || user.nil? || user.empty? || pass.nil? || pass.empty?
    conn = Tina4::Database.new("odbc:///#{auth}", username: user, password: pass)
    expect(val(conn.fetch_one("SELECT 1 AS one"), "one").to_i).to eq(1)
    conn.close
  end

  it "a wrong password fails loud" do
    auth = ENV["TINA4_TEST_ODBC_AUTH_DSN"]
    user = ENV["TINA4_TEST_ODBC_USERNAME"]
    skip "TINA4_TEST_ODBC_AUTH_DSN / _USERNAME not set" if auth.nil? || auth.empty? || user.nil? || user.empty?
    expect do
      conn = Tina4::Database.new("odbc:///#{auth}", username: user, password: "definitely-the-wrong-password")
      conn.fetch_one("SELECT 1 AS one")
    end.to raise_error(StandardError)
  end
end
