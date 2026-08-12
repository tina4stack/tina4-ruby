# frozen_string_literal: true

# Firebird provider contract -- feature 12 (FB-DEC-01/02/03).
#
# Pins the Firebird write-path + resilience behaviours against a REAL Firebird 5,
# no mocks. The SAME cases are proven in all four frameworks; the shared fixture
# is tina4-documentation/plan/v3/fixtures/firebirdprovider_contract.json.
#
#   * FB-DEC-02: db.insert() returns the GENERATOR-assigned last-id (non-`id` PK
#     too); update/delete report the REAL affected count.
#   * FB-DEC-03: a binary blob round-trips byte-for-byte.
#   * FB-DEC-01: a forced server-side disconnect transparently reconnects; a
#     logical SQL error does NOT (this is the real reconnect test that replaced
#     the mocked firebird_reconnect_spec).
#
# Firebird has no generic last_insert_id, so each table is created with a
# GEN_<TABLE>_ID generator + a BEFORE INSERT trigger -- the real Firebird idiom
# the driver derives the last-id from. TINA4_TEST_FIREBIRD_URL unset -> skip.

require "spec_helper"

RSpec.describe "Firebird provider contract" do
  # A binary payload a naive text decode or an unread blob handle corrupts:
  # a NUL byte, high bytes 0xFD..0xFF, an embedded NUL, and ASCII.
  BLOB = [0, 1, 2, 253, 254, 255, 65, 66, 0, 67].pack("C*").freeze

  before(:all) { @url = ENV["TINA4_TEST_FIREBIRD_URL"] }

  around(:each) do |example|
    if @url.nil? || @url.empty?
      skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)"
    else
      example.run
    end
  end

  def fresh_db
    db = Tina4::Database.new(@url, username: "SYSDBA", password: "masterkey")
    (@open_dbs ||= []) << db
    db
  end

  after(:each) do
    (@open_dbs || []).each { |db| db.close rescue nil }
  end

  # A table whose PK is assigned by a GEN_<TABLE>_ID generator via a BEFORE
  # INSERT trigger -- the real Firebird auto-key idiom.
  def make_table(db, name, pk: "id", extra: nil)
    ["DROP TRIGGER #{name}_bi", "DROP TABLE #{name}", "DROP GENERATOR gen_#{name}_id"].each do |sql|
      db.execute(sql) rescue nil
    end
    cols = "#{pk} INTEGER NOT NULL PRIMARY KEY, name VARCHAR(50)"
    cols += ", #{extra}" if extra
    db.execute("CREATE TABLE #{name} (#{cols})")
    db.execute("CREATE GENERATOR gen_#{name}_id")
    db.execute(
      "CREATE TRIGGER #{name}_bi FOR #{name} ACTIVE BEFORE INSERT POSITION 0 " \
      "AS BEGIN IF (NEW.#{pk} IS NULL) THEN NEW.#{pk} = GEN_ID(gen_#{name}_id, 1); END"
    )
  end

  # ---- FB-DEC-02: generator last-id -------------------------------------

  it "an insert returns the generator last id" do
    db = fresh_db
    make_table(db, "rbc_gen")
    result = db.insert("rbc_gen", { "name" => "alpha" })
    expect(result.last_id).to eq(1)
  end

  it "a second insert returns the next generated id" do
    db = fresh_db
    make_table(db, "rbc_gen2")
    first = db.insert("rbc_gen2", { "name" => "a" })
    second = db.insert("rbc_gen2", { "name" => "b" })
    expect(first.last_id).to eq(1)
    expect(second.last_id).to eq(2)
    # Durable + correctly keyed, read on a SECOND fresh connection.
    row = fresh_db.fetch_one("SELECT name FROM rbc_gen2 WHERE id = ?", [2])
    expect(row[:name]).to eq("b")
  end

  it "an insert reports affected rows of one" do
    db = fresh_db
    make_table(db, "rbc_ins1")
    expect(db.insert("rbc_ins1", { "name" => "x" }).affected_rows).to eq(1)
  end

  # ---- FB-DEC-02: real affected count -----------------------------------

  it "a multi row update reports the real affected count" do
    db = fresh_db
    make_table(db, "rbc_upd")
    %w[a b c d].each { |n| db.insert("rbc_upd", { "name" => n }) }
    expect(db.update("rbc_upd", { "name" => "Z" }, "id <= ?", [3]).affected_rows).to eq(3)
  end

  it "an update matching no rows reports zero affected" do
    db = fresh_db
    make_table(db, "rbc_upd0")
    db.insert("rbc_upd0", { "name" => "a" })
    expect(db.update("rbc_upd0", { "name" => "Z" }, "name = ?", ["nope"]).affected_rows).to eq(0)
  end

  it "a delete reports the real affected count" do
    db = fresh_db
    make_table(db, "rbc_del")
    %w[a b c].each { |n| db.insert("rbc_del", { "name" => n }) }
    expect(db.delete("rbc_del", "id <= ?", [2]).affected_rows).to eq(2)
  end

  # ---- FB-DEC-03: blob round-trip ---------------------------------------

  it "a binary blob round trips byte for byte" do
    db = fresh_db
    make_table(db, "rbc_blob", extra: "payload BLOB SUB_TYPE 0")
    db.insert("rbc_blob", { "name" => "b", "payload" => BLOB })
    # Read back on a SECOND fresh connection.
    row = fresh_db.fetch_one("SELECT payload FROM rbc_blob WHERE name = ?", ["b"])
    got = row[:payload]
    got = got.read if got.respond_to?(:read)
    expect(got.b).to eq(BLOB.b)
  end

  # ---- FB-DEC-01: real reconnect ----------------------------------------

  it "a forced disconnect reconnects and the next query succeeds" do
    db = fresh_db
    make_table(db, "rbc_recon")
    db.insert("rbc_recon", { "name" => "before" })
    # The adapter's OWN attachment id, then kill it server-side from a SECOND
    # connection -- a genuine forced disconnect, no mock.
    conn_id = db.fetch_one("SELECT CURRENT_CONNECTION AS c FROM rdb$database")[:c]
    killer = fresh_db
    killer.execute("DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID = ?", [conn_id])
    killer.close
    # The next query on the dead attachment must transparently reconnect + succeed.
    row = db.fetch_one("SELECT COUNT(*) AS n FROM rbc_recon")
    expect(row[:n]).to eq(1)
  end

  it "a logical sql error does not trigger a reconnect" do
    # The dead-connection matcher must classify a real SQL error as NOT dead, so
    # a syntax/logical error surfaces to the caller instead of a reconnect loop.
    expect(Tina4::Drivers::FirebirdDriver.dead_connection?("Dynamic SQL Error: syntax error at line 1")).to be false
    expect(Tina4::Drivers::FirebirdDriver.dead_connection?("Table RBC_NOPE does not exist")).to be false
    # And a genuinely bad query RAISES through the adapter (does not silently retry).
    db = fresh_db
    expect { db.fetch_one("SELECT * FROM rbc_table_that_does_not_exist_xyz") }.to raise_error(StandardError)
    # The connection is still usable -- no spurious reconnect churn broke it.
    expect(db.fetch_one("SELECT 1 AS x FROM rdb$database")[:x]).to eq(1)
  end

  # ---- FB-DEC-02: non-`id` primary key ----------------------------------

  it "a non id primary key insert returns the generated last id" do
    db = fresh_db
    make_table(db, "rbc_thing", pk: "thing_key")
    # The generator read is column-name-independent, so the last-id is correct
    # even though the PK is not named `id`.
    expect(db.insert("rbc_thing", { "name" => "hi" }).last_id).to eq(1)
  end
end
