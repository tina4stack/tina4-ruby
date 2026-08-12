# frozen_string_literal: true

# MySQL provider contract - feature 10 (mysqlprovider_contract.json), parity with
# tina4-python/tests/test_mysqlprovider_contract.py.
#
# MYSQL-DEC-01 + MYSQL-DEC-02 (OWNER-DECISIONS.md Batch 5, feature doc
# 010-mysql-provider.md). Every case drives the lab's REAL MySQL :3306
# (tina4/tina4 -> tina4_test) through the public Tina4::Database facade ->
# MysqlDriver. No mocks. Durability is read back on a SECOND, FRESH connection.
#
# This driver does NOT emulate MySQL RETURNING (only the Python adapter does); a
# non-`id`-PK insert surfaces the correct generated id through mysql2's
# column-independent last_id (invariant 1). MYSQL-DEC-02 here: the DESCRIBE
# introspection is STRICT-quoted (MYSQL-DESCRIBE-UNPARAM) and the FIRST->LAST
# batch-id math is de-duplicated onto Tina4::SQLTranslator.batch_last_id.
#
# Mutation-proof: revert the strict DESCRIBE quoting -> "describe of an odd table
# name returns its columns" goes RED (a backtick/special-char name is a syntax
# error). Neutralise batch_last_id -> "a batch insert returns the last sequential
# generated id" goes RED (it reports the FIRST id 1 for a 3-row batch).

require "spec_helper"
require "socket"

RSpec.describe "MySQL provider contract (feature 10)" do
  # Unique-suffixed constants: a bare constant inside an RSpec.describe leaks onto
  # Object, so name them so they cannot collide with another spec's.
  MYP_HOST  = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MYP_PORT  = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MYP_USER  = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
  MYP_PASS  = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  MYP_DB    = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

  MYP_NONID = "mysqlprov_nonid"       # a table whose PK is deliberately NOT `id`
  MYP_BATCH = "mysqlprov_batch"
  MYP_SENTINEL = "mysqlprov_sentinel"
  MYP_ODD   = "mysqlprov`odd"         # an embedded backtick -> needs strict quoting

  def self.tcp_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  MYP_REACHABLE = tcp_reachable?(MYP_HOST, MYP_PORT)

  def mysql_url
    "mysql://#{MYP_HOST}:#{MYP_PORT}/#{MYP_DB}"
  end

  def connect
    Tina4::Database.new(mysql_url, username: MYP_USER, password: MYP_PASS)
  end

  # Strict backtick-quote for building DDL / reads against an odd name in the test.
  def q(name)
    "`#{name.to_s.gsub('`', '``')}`"
  end

  # A fresh AUTO_INCREMENT table with a NON-`id` PK so its sequence restarts at 1.
  def fresh_nonid
    @db.execute("DROP TABLE IF EXISTS #{MYP_NONID}")
    @db.execute(
      "CREATE TABLE #{MYP_NONID} (person_key INT NOT NULL AUTO_INCREMENT PRIMARY KEY, " \
      "code VARCHAR(40) NOT NULL UNIQUE, qty INTEGER)"
    )
  end

  # Every row on a SECOND connection - the durability witness.
  def fresh_rows(table, order_col)
    other = connect
    begin
      other.fetch("SELECT * FROM #{q(table)} ORDER BY #{q(order_col)}", [], limit: 1000).records
    ensure
      other.close rescue nil
    end
  end

  before do
    skip "no reachable MySQL at #{MYP_HOST}:#{MYP_PORT} (set TINA4_TEST_MYSQL_*)" unless MYP_REACHABLE
    @db = connect
  end

  after do
    next unless @db
    [q(MYP_NONID), q(MYP_BATCH), q(MYP_SENTINEL), q(MYP_ODD)].each do |t|
      @db.execute("DROP TABLE IF EXISTS #{t}") rescue nil
    end
    @db.close rescue nil
  end

  # ── mysql-nonid-pk-generated-id ─────────────────────────────────────────────

  it "a non id primary key insert returns the generated last id" do
    fresh_nonid
    result = @db.insert(MYP_NONID, { "code" => "a", "qty" => 10 })
    expect(result.last_id).to eq(1)
    rows = fresh_rows(MYP_NONID, "person_key")
    expect(rows.length).to eq(1)
    expect(rows[0][:person_key]).to eq(1)
    expect(rows[0][:code]).to eq("a")
  end

  it "a second non id primary key insert returns the next generated id" do
    fresh_nonid
    first = @db.insert(MYP_NONID, { "code" => "a", "qty" => 10 })
    second = @db.insert(MYP_NONID, { "code" => "b", "qty" => 20 })
    expect(first.last_id).to eq(1)
    expect(second.last_id).to eq(2)
    expect(second.last_id).not_to eq(first.last_id)
  end

  it "a non id primary key insert reports affected rows of one" do
    fresh_nonid
    result = @db.insert(MYP_NONID, { "code" => "a", "qty" => 10 })
    expect(result.affected_rows).to eq(1)
  end

  # ── mysql-write-affected-count ──────────────────────────────────────────────

  it "update reports the exact number of rows changed" do
    fresh_nonid
    @db.insert(MYP_NONID, { "code" => "a", "qty" => 10 })
    @db.insert(MYP_NONID, { "code" => "b", "qty" => 20 })
    @db.insert(MYP_NONID, { "code" => "c", "qty" => 40 })
    result = @db.update(MYP_NONID, { "qty" => 99 }, "qty < ?", [30])
    expect(result.affected_rows).to eq(2)
  end

  it "delete reports the exact number of rows removed" do
    fresh_nonid
    @db.insert(MYP_NONID, { "code" => "a", "qty" => 10 })
    @db.insert(MYP_NONID, { "code" => "b", "qty" => 20 })
    result = @db.delete(MYP_NONID, { "code" => "a" })
    expect(result.affected_rows).to eq(1)
    expect(fresh_rows(MYP_NONID, "person_key").map { |r| r[:code] }).to eq(["b"])
  end

  it "an update reports a null last id" do
    fresh_nonid
    @db.insert(MYP_NONID, { "code" => "a", "qty" => 10 })
    result = @db.update(MYP_NONID, { "qty" => 99 }, "code = ?", ["a"])
    expect(result.last_id).to be_nil
  end

  # ── mysql-describe-safe ─────────────────────────────────────────────────────

  it "describe of an odd table name returns its columns" do
    @db.execute("DROP TABLE IF EXISTS #{q(MYP_ODD)}")
    @db.execute("CREATE TABLE #{q(MYP_ODD)} (person_key INT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(20))")
    # A raw/naively-quoted DESCRIBE breaks on the embedded backtick; strict
    # quoting introspects the odd name correctly.
    cols = @db.columns(MYP_ODD)
    expect(cols.map { |c| c[:name] }).to eq(%w[person_key val])
    pk = cols.select { |c| c[:primary_key] }.map { |c| c[:name] }
    expect(pk).to eq(["person_key"])
  end

  it "describe of a crafted table name does not inject" do
    @db.execute("DROP TABLE IF EXISTS #{MYP_SENTINEL}")
    @db.execute("CREATE TABLE #{MYP_SENTINEL} (id INT PRIMARY KEY)")
    crafted = "x`; DROP TABLE #{MYP_SENTINEL}; --"
    # The crafted name becomes ONE escaped identifier -> a clean "unknown table"
    # (no runnable SQL). The result is irrelevant; the sentinel must survive.
    begin
      @db.columns(crafted)
    rescue StandardError
      # strict-quoting a non-existent table raises - nothing was injected.
    end
    expect(@db.table_exists?(MYP_SENTINEL)).to be(true)
  end

  # ── mysql-batch-sequential-ids ──────────────────────────────────────────────

  it "a batch insert returns the last sequential generated id" do
    @db.execute("DROP TABLE IF EXISTS #{MYP_BATCH}")
    @db.execute("CREATE TABLE #{MYP_BATCH} (seq_key INT NOT NULL AUTO_INCREMENT PRIMARY KEY, code VARCHAR(40) NOT NULL, qty INTEGER)")
    result = @db.insert(MYP_BATCH, [
                          { "code" => "b1", "qty" => 1 },
                          { "code" => "b2", "qty" => 2 },
                          { "code" => "b3", "qty" => 3 }
                        ])
    # MySQL reports the FIRST id of a collapsed multi-row INSERT (1); the shared
    # batch_last_id helper normalises it to the LAST (3).
    expect(result.last_id).to eq(3)
  end

  it "a batch insert assigns consecutive ids to every row" do
    @db.execute("DROP TABLE IF EXISTS #{MYP_BATCH}")
    @db.execute("CREATE TABLE #{MYP_BATCH} (seq_key INT NOT NULL AUTO_INCREMENT PRIMARY KEY, code VARCHAR(40) NOT NULL, qty INTEGER)")
    @db.insert(MYP_BATCH, [
                 { "code" => "b1", "qty" => 1 },
                 { "code" => "b2", "qty" => 2 },
                 { "code" => "b3", "qty" => 3 }
               ])
    rows = fresh_rows(MYP_BATCH, "seq_key")
    expect(rows.map { |r| r[:seq_key].to_i }).to eq([1, 2, 3])
    expect(rows.map { |r| r[:code] }).to eq(%w[b1 b2 b3])
  end
end
