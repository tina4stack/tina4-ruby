# frozen_string_literal: true
#
# Regression spec for the engine-aware create_table fix (v3.13.16).
#
# Before the fix, ORM.create_table emitted SQLite-only DDL on every engine:
# a raw AUTOINCREMENT keyword, DATETIME for datetime columns, and INTEGER for
# booleans (because Database had no get_database_type, so the BooleanField
# engine check never fired). On PostgreSQL the CREATE blew up
# ("syntax error at or near AUTOINCREMENT"), db.execute() swallowed the error,
# and create_table still returned true with NO table created — a silent pass.
#
# This spec boots a real PostgreSQL and asserts the documented code-first
# schema path actually works: create_table returns true, the table exists,
# the auto-increment PK is a SERIAL, the boolean column is a native BOOLEAN,
# the datetime column is a TIMESTAMP, an insert + select round-trips, a
# `WHERE active = TRUE` predicate works (no boolean->int rewrite on PG), and
# DatabaseResult#[] (index + slice) works on the result.
#
# The spec skips automatically when the pg gem is missing or the database is
# unreachable, so CI without PostgreSQL just no-ops (same gate as the other
# PG specs).

require "spec_helper"
require "socket"

PGCT_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PGCT_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "5432").to_i
PGCT_USER = ENV.fetch("TINA4_TEST_PG_USER", "tina4")
PGCT_PASS = ENV.fetch("TINA4_TEST_PG_PASS", "tina4")
PGCT_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pgct_reachable?
  TCPSocket.new(PGCT_HOST, PGCT_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def pgct_gem_available?
  require "pg"
  true
rescue LoadError
  false
end

class PgCreateTableWidget < Tina4::ORM
  table_name "pg_create_table_widgets"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  boolean_field :active, default: true
  datetime_field :created_at
end

RSpec.describe "PostgreSQL engine-aware create_table (v3.13.16)" do
  before(:all) do
    @skip_reason = if !pgct_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pgct_reachable?
                     "PostgreSQL not reachable at #{PGCT_HOST}:#{PGCT_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PGCT_HOST}:#{PGCT_PORT}/#{PGCT_DB}",
      username: PGCT_USER, password: PGCT_PASS
    )
    @db.execute("DROP TABLE IF EXISTS pg_create_table_widgets")
    PgCreateTableWidget.db = @db
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS pg_create_table_widgets")
    ensure
      @db.close rescue nil
    end
  end

  it "exposes get_database_type as the resolved engine name" do
    expect(@db.get_database_type).to eq("postgres")
  end

  it "create_table returns true AND actually creates the table" do
    expect(PgCreateTableWidget.create_table).to be(true)
    expect(@db.table_exists?("pg_create_table_widgets")).to be(true)
    expect(@db.get_error).to be_nil
  end

  it "emits SERIAL for the auto-increment PK, native BOOLEAN, and TIMESTAMP" do
    PgCreateTableWidget.create_table
    cols = @db.columns("pg_create_table_widgets").each_with_object({}) do |c, h|
      h[c[:name]] = c
    end

    # auto-increment PK became a SERIAL -> integer column backed by a sequence
    expect(cols["id"][:type]).to eq("integer")
    expect(cols["id"][:default].to_s).to include("nextval")

    # boolean column is a native BOOLEAN with a TRUE default (not INTEGER / 1)
    expect(cols["active"][:type]).to eq("boolean")
    expect(cols["active"][:default].to_s.downcase).to include("true")

    # datetime column became TIMESTAMP (PG has no DATETIME type)
    expect(cols["created_at"][:type]).to eq("timestamp without time zone")
  end

  it "round-trips an insert with a boolean and a datetime, and result[0] works" do
    PgCreateTableWidget.create_table
    now = Time.now
    @db.execute(
      "INSERT INTO pg_create_table_widgets (name, active, created_at) VALUES (?, ?, ?)",
      ["gadget", true, now]
    )

    result = @db.fetch("SELECT * FROM pg_create_table_widgets ORDER BY id")
    expect(result.count).to eq(1)

    # DatabaseResult#[] — documented index access (book ch5 §4)
    row = result[0]
    expect(row).not_to be_nil
    expect(row[:name]).to eq("gadget")

    # the row round-trips through the native BOOLEAN / TIMESTAMP columns
    expect(row[:active]).not_to be_nil
    expect(row[:created_at]).not_to be_nil

    # slice access also works (delegates to the records array)
    expect(result[0..0].length).to eq(1)
  end

  it "decodes PostgreSQL columns to native Ruby types (not strings)" do
    # The pg gem hands back every column as a String by default; the driver
    # now installs PG::BasicTypeMapForResults so reads match SQLite / Python /
    # Node native shapes — id is an Integer, active is true/false (not "t"),
    # the timestamp is a Time.
    PgCreateTableWidget.create_table
    @db.execute(
      "INSERT INTO pg_create_table_widgets (name, active, created_at) VALUES (?, ?, ?)",
      ["typed", true, Time.now]
    )
    row = @db.fetch("SELECT * FROM pg_create_table_widgets ORDER BY id")[0]
    expect(row[:id]).to be_a(Integer)
    expect(row[:active]).to be(true)
    expect(row[:created_at]).to be_a(Time)
  end

  it "honours a native-boolean predicate without a boolean->int rewrite" do
    PgCreateTableWidget.create_table
    @db.execute(
      "INSERT INTO pg_create_table_widgets (name, active, created_at) VALUES (?, ?, ?)",
      ["on", true, Time.now]
    )
    @db.execute(
      "INSERT INTO pg_create_table_widgets (name, active, created_at) VALUES (?, ?, ?)",
      ["off", false, Time.now]
    )

    # WHERE active = TRUE must NOT be rewritten to `= 1` on PG (that raises
    # "operator does not exist: boolean = integer").
    rows = @db.fetch("SELECT name FROM pg_create_table_widgets WHERE active = TRUE")
    expect(@db.get_error).to be_nil
    expect(rows.count).to eq(1)
    expect(rows[0][:name]).to eq("on")
  end
end
