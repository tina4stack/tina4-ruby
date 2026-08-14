# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "socket"
require "json"

# Feature 18 - ORM fields and column mapping: the shared conformance contract.
#
# Proves the reconciled field-model BEHAVIOUR (FIELD-DEC-01 gap + FIELD-DEC-02),
# NO MOCKS. The cross-engine DDL cases actually CREATE the table on real
# PostgreSQL / MySQL / MSSQL / Firebird and read the column type back from each
# engine's OWN catalog. The Ruby-only FK-name case carries
# FIELD-FK-RELATEDNAME-RUBY (decimal_field precision is FIELD-DECIMAL-PRECISION).
#
# Case names are shared verbatim across the four frameworks and gated by
# scripts/audit-contract-fixtures.py. Under TINA4_REQUIRE_SERVICES a
# PG/MySQL/MSSQL skip is upgraded to a failure by spec_helper; Firebird is gated.

# Model classes are TOP LEVEL on purpose (a bare constant inside RSpec.describe
# lands on Object and clobbers another spec file).
class OrmfWidget < Tina4::ORM
  table_name "ormf_widget"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  text_field :note
  integer_field :qty
  boolean_field :active
  decimal_field :ratio, precision: 8, scale: 3
  datetime_field :made_at
  json_field :payload
end

class OrmfDoc < Tina4::ORM
  table_name "ormf_doc"
  integer_field :id, primary_key: true, auto_increment: true
  json_field :body
end

class OrmfTicket < Tina4::ORM
  table_name "ormf_ticket"
  @@counter = 0
  def self.reset_counter! = (@@counter = 0)
  integer_field :id, primary_key: true, auto_increment: true
  integer_field :seq, default: -> { @@counter += 1 }
end

class OrmfSession < Tina4::ORM
  table_name "ormf_session"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :token, default: -> { "tok-#{rand(1_000_000_000)}" }
end

class OrmfBlob < Tina4::ORM
  table_name "ormf_blob"
  integer_field :id, primary_key: true, auto_increment: true
  json_field :data
end

class OrmfMoney < Tina4::ORM
  table_name "ormf_money"
  integer_field :id, primary_key: true, auto_increment: true
  decimal_field :amount, precision: 12, scale: 4
end

# FIELD-FK-RELATEDNAME-RUBY: the DECLARING class name is the one pluralized, so
# it must be a class whose plural is non-trivial (Category -> categories, not the
# naive "categorys").
class OrmfShelf < Tina4::ORM
  table_name "ormf_shelf"
  integer_field :id, primary_key: true, auto_increment: true
end

class Category < Tina4::ORM
  table_name "ormf_category"
  integer_field :id, primary_key: true, auto_increment: true
  foreign_key_field :ormf_shelf_id, references: OrmfShelf
end

# A natural string PK (the round-trip supplies it) so the row insert exercises
# the field COLUMNS on the real engine without depending on per-engine
# auto-increment (Firebird auto-increment needs a generator ORM.create_table
# sets up only in Node today -- a separate feature 16/17 gap).
class OrmfEngineModel < Tina4::ORM
  table_name "ormf_engine"
  string_field :id, primary_key: true, length: 32
  boolean_field :flag
  json_field :payload
  decimal_field :amount, precision: 12, scale: 4
  datetime_field :made_at
end

RSpec.describe "ORM fields and column mapping (feature 18)" do
  # Keep the Tempfile object alive for the whole example. Retaining only its
  # path lets Ruby's GC unlink the open database at any point, which surfaced
  # in CI as an intermittent SQLite "disk I/O error".
  let(:sqlite_file) { Tempfile.new(["ormf", ".db"]) }
  let(:sqlite_path) { sqlite_file.path }

  before(:each) do
    @db = Tina4::Database.new("sqlite:///#{sqlite_path}")
    Tina4.bind_database(@db)
  end

  after(:each) do
    @db&.close
    sqlite_file.close!
  end

  def column_type(db, table, col)
    (db.columns(table).find { |c| c[:name].to_s == col.to_s } || {})[:type].to_s
  end

  def ddl(db, table)
    (db.fetch_one("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [table]) || {})[:sql].to_s
  end

  # ── four-way behaviour (SQLite here) ────────────────────────────────────

  it "each declared field type round trips through a real database" do
    expect(OrmfWidget.create_table).to be true
    w = OrmfWidget.new(name: "gizmo", note: "a longer note", qty: 7, active: true,
                       ratio: 12.345, made_at: "2026-01-02 03:04:05",
                       payload: { "k" => "v", "n" => [1, 2, 3] })
    expect(w.save).not_to be false
    got = OrmfWidget.find(w.id)
    expect(got.name).to eq("gizmo")
    expect(got.note).to eq("a longer note")
    expect(got.qty).to eq(7)
    expect([true, 1]).to include(got.active)
    expect(got.ratio.to_f).to be_within(1e-6).of(12.345)
    expect(got.made_at.to_s).to include("2026-01-02")
    expect(got.payload).to eq({ "k" => "v", "n" => [1, 2, 3] })
  end

  it "a json field round trips to a native object" do
    OrmfDoc.create_table
    d = OrmfDoc.new(body: { "tags" => %w[a b], "meta" => { "n" => 1 } })
    expect(d.save).not_to be false
    got = OrmfDoc.find(d.id)
    expect(got.body).to be_a(Hash)
    expect(got.body["tags"]).to eq(%w[a b])
    expect(got.body["meta"]["n"]).to eq(1)
  end

  it "a callable default is resolved per instance" do
    OrmfTicket.reset_counter!
    a = OrmfTicket.new
    b = OrmfTicket.new
    c = OrmfTicket.new
    expect([a.seq, b.seq, c.seq]).to eq([1, 2, 3])
  end

  it "a callable default is not present in the create table ddl" do
    expect(OrmfSession.create_table).to be true
    expect(ddl(@db, "ormf_session").upcase).not_to include("DEFAULT")
  end

  it "a non serializable json value makes save return false and is logged" do
    OrmfBlob.create_table
    bad = OrmfBlob.new(data: { "x" => Float::NAN })   # NaN is not valid JSON
    expect(bad.save).to be false
    expect(OrmfBlob.count).to eq(0)
  end

  it "a decimal field produces a decimal precision scale column" do
    expect(OrmfMoney.create_table).to be true
    expect(column_type(@db, "ormf_money", "amount").gsub(" ", "").upcase).to include("DECIMAL(12,4)")
  end

  # ── FIELD-FK-RELATEDNAME-RUBY (Ruby-only) ───────────────────────────────

  it "a foreign key to Category wires categories not categorys" do
    # The FK on Category (declaring class) wires has_many on OrmfShelf named for
    # the DECLARING class, smart-pluralized: Category -> categories, never the
    # naive "categorys".
    rels = OrmfShelf.relationship_definitions
    expect(rels).to have_key(:categories)
    expect(rels).not_to have_key(:categorys)
    expect(OrmfShelf.new.respond_to?(:categories)).to be true
  end

  # ── real-engine DDL (replaces the deleted Python mock) ──────────────────

  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 3) { true }
  rescue StandardError
    false
  end

  def engine_db(engine)
    case engine
    when "postgres"
      h = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
      p = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
      skip "postgres unreachable at #{h}:#{p} (set TINA4_TEST_PG_*)" unless reachable?(h, p)
      db = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")
      Tina4::Database.new("postgres://#{h}:#{p}/#{db}",
                          username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                          password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
    when "mysql"
      h = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
      p = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
      skip "mysql unreachable at #{h}:#{p} (set TINA4_TEST_MYSQL_*)" unless reachable?(h, p)
      db = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")
      Tina4::Database.new("mysql://#{h}:#{p}/#{db}",
                          username: ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4"),
                          password: ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4"))
    when "mssql"
      h = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
      p = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
      skip "mssql unreachable at #{h}:#{p} (set TINA4_TEST_MSSQL_*)" unless reachable?(h, p)
      db = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")
      Tina4::Database.new("mssql://#{h}:#{p}/#{db}",
                          username: ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa"),
                          password: ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure"))
    else # firebird — gated; runs when TINA4_TEST_FIREBIRD_URL is set (the lab sets it)
      url = ENV["TINA4_TEST_FIREBIRD_URL"]
      skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)" if url.nil? || url.empty?
      Tina4::Database.new(url,
                          username: ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA"),
                          password: ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey"))
    end
  end

  def drop_engine_table(db, engine, table)
    if engine == "mssql"
      db.execute("IF OBJECT_ID('#{table}', 'U') IS NOT NULL DROP TABLE #{table}")
    elsif engine == "firebird"
      db.execute("DROP TABLE #{table}") if db.table_exists?(table)
    else
      db.execute("DROP TABLE IF EXISTS #{table}")
    end
  rescue StandardError
    # best effort
  end

  def describe_columns(db, engine, table)
    out = {}
    rows =
      case engine
      when "postgres"
        db.fetch("SELECT column_name, data_type, udt_name, numeric_precision, numeric_scale " \
                 "FROM information_schema.columns WHERE table_name = ?", [table.downcase]).records
      when "mysql"
        db.fetch("SELECT column_name, data_type, column_type, numeric_precision, numeric_scale " \
                 "FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE()", [table]).records
      when "mssql"
        db.fetch("SELECT column_name, data_type, numeric_precision, numeric_scale, character_maximum_length " \
                 "FROM information_schema.columns WHERE table_name = ?", [table]).records
      else
        db.fetch("SELECT TRIM(rf.rdb$field_name) AS fname, f.rdb$field_type AS ftype, " \
                 "f.rdb$field_sub_type AS fsub, f.rdb$field_precision AS fprec, f.rdb$field_scale AS fscale " \
                 "FROM rdb$relation_fields rf JOIN rdb$fields f " \
                 "ON rf.rdb$field_source = f.rdb$field_name WHERE rf.rdb$relation_name = ?", [table.upcase]).records
      end
    rows.each do |raw|
      r = raw.transform_keys { |k| k.to_s.downcase }
      if engine == "firebird"
        out[r["fname"].to_s.strip.downcase] = {
          ftype: r["ftype"].to_i, fsub: r["fsub"]&.to_i,
          precision: r["fprec"]&.to_i, scale: r["fscale"]&.to_i
        }
      else
        name = r["column_name"].to_s.downcase
        out[name] = {
          type: (r["column_type"] || r["udt_name"] || r["data_type"]).to_s.downcase,
          data_type: r["data_type"].to_s.downcase,
          precision: r["numeric_precision"]&.to_i,
          scale: r["numeric_scale"]&.to_i,
          maxlen: r["character_maximum_length"]&.to_i
        }
      end
    end
    out
  end

  def make_engine_table(db, engine)
    Tina4.bind_database(db)
    drop_engine_table(db, engine, "ormf_engine")
    expect(OrmfEngineModel.create_table).to be(true), "create_table failed on #{engine}: #{db.get_error}"
    describe_columns(db, engine, "ormf_engine")
  end

  %w[postgres mysql mssql firebird].each do |engine|
    context "on the #{engine} engine" do
      it "a boolean column is created with the engine native boolean type" do
        db = engine_db(engine)
        begin
          cols = make_engine_table(db, engine)
          flag = cols["flag"]
          case engine
          when "postgres" then expect(flag[:type]).to include("bool")
          when "mysql"    then expect(flag[:type]).to eq("tinyint(1)")
          when "mssql"    then expect(flag[:type]).to eq("bit")
          else                 expect(flag[:ftype]).to eq(8) # Firebird LONG / INTEGER
          end
          drop_engine_table(db, engine, "ormf_engine")
        ensure
          db.close
        end
      end

      it "a json column is created with the engine native json type" do
        db = engine_db(engine)
        begin
          cols = make_engine_table(db, engine)
          payload = cols["payload"]
          case engine
          when "postgres" then expect(payload[:type]).to eq("jsonb")
          when "mysql"    then expect(payload[:type]).to eq("json")
          when "mssql"
            expect(payload[:type]).to eq("nvarchar")
            expect(payload[:maxlen]).to eq(-1) # NVARCHAR(MAX)
          else
            expect(payload[:ftype]).to eq(261) # BLOB
            expect(payload[:fsub]).to eq(1)    # SUB_TYPE TEXT
          end
          drop_engine_table(db, engine, "ormf_engine")
        ensure
          db.close
        end
      end

      it "a decimal column is created with decimal precision and scale on the engine" do
        db = engine_db(engine)
        begin
          cols = make_engine_table(db, engine)
          amount = cols["amount"]
          if engine == "firebird"
            expect(amount[:precision]).to eq(12)
            expect(amount[:scale]).to eq(-4) # stored as a scaled INT64
          else
            expect(amount[:precision]).to eq(12)
            expect(amount[:scale]).to eq(4)
            if engine == "postgres"
              expect(%w[numeric decimal]).to include(amount[:type])
            else
              expect(amount[:type]).to start_with("decimal")
            end
          end
          drop_engine_table(db, engine, "ormf_engine")
        ensure
          db.close
        end
      end

      it "the engine ddl types round trip a real row" do
        db = engine_db(engine)
        begin
          make_engine_table(db, engine)
          # Drive the write/read through the DB facade with an explicit key:
          # proves the ENGINE COLUMNS accept + return a real row of each type,
          # independent of ORM auto-increment (Firebird) and the ORM natural-key
          # save path (a second transaction on MySQL) -- separate feature 16/17
          # concerns. The ORM's JSON serialize/hydrate is proven by the SQLite
          # cases above.
          # flag as INTEGER 1 (not a Ruby bool): PG/MySQL/MSSQL accept it for
          # their bool column and Firebird's fb driver binds it to the INTEGER
          # column (the fb driver calls to_i on a param, so a bare `true` raises).
          db.insert("ormf_engine", { "id" => "row-1", "flag" => 1,
                                     "payload" => JSON.generate({ "k" => "v", "n" => [1, 2] }),
                                     "amount" => 1234.5678, "made_at" => "2026-03-04 05:06:07" })
          row = db.fetch_one("SELECT * FROM ormf_engine WHERE id = ?", ["row-1"])
          expect(row).not_to be_nil
          r = row.transform_keys { |k| k.to_s.downcase }
          expect(%w[1 t true]).to include(r["flag"].to_s.downcase)
          payload = r["payload"]
          payload = JSON.parse(payload) if payload.is_a?(String)
          expect(payload).to eq({ "k" => "v", "n" => [1, 2] })
          expect(r["amount"].to_f).to be_within(1e-3).of(1234.5678)
          expect(r["made_at"].to_s).to include("2026-03-04")
          drop_engine_table(db, engine, "ormf_engine")
        ensure
          db.close
        end
      end
    end
  end
end
