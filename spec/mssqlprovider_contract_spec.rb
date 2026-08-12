# frozen_string_literal: true

# MSSQL provider contract - feature 11 (mssqlprovider_contract.json), parity with
# tina4-python/tests/test_mssqlprovider_contract.py.
#
# MSSQL-DEC-01 + MSSQL-DEC-02 (OWNER-DECISIONS.md Batch 5, feature doc
# 011-mssql-provider.md). Every case drives the lab's REAL SQL Server :1433
# (sa -> tina4_test) through the public Tina4::Database facade -> MssqlDriver.
# No mocks. Durability is read back on a SECOND, FRESH connection.
#
# MSSQL-DEC-01 (safe parameter handling): the driver hand-interpolates params. It
# used to `else param.to_s` an unrecognised type - a BAREWORD in the SQL (a Symbol
# became `VALUES (foo)` -> "Invalid column name foo"), a breakage / injection
# vector. It now (a) emits ASCII-8BIT bytes as a `0x` varbinary literal that
# round-trips, and (b) RAISES ArgumentError on a genuinely unbindable type - never
# a bareword. The "unbindable parameter" test is the Ruby-only mutation witness.
#
# MSSQL-DEC-02 (one pagination strategy): OFFSET/FETCH, proven by the window.
#
# Mutation-proof: revert the `else` branch to `param.to_s` -> "an unbindable
# parameter raises instead of a bareword" goes RED (it produces a bareword and the
# DB raises a different error, not ArgumentError). Revert the binary branch ->
# "a binary parameter round trips" goes RED (a NUL byte corrupts / truncates it).

require "spec_helper"
require "socket"

RSpec.describe "MSSQL provider contract (feature 11)" do
  # Unique-suffixed constants: a bare constant inside an RSpec.describe leaks onto
  # Object, so name them so they cannot collide with another spec's.
  MSP_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
  MSP_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  MSP_USER = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
  MSP_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
  MSP_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

  MSP_NONID  = "mssqlprov_nonid"   # a table whose PK is deliberately NOT `id`
  MSP_PARAMS = "mssqlprov_params"
  MSP_PAGE   = "mssqlprov_page"
  # A payload with a NUL byte and high bytes - what a text bind / quoted string
  # corrupts and only a real varbinary bind round-trips.
  MSP_BIN = [0, 1, 255, 2, 16, 200, 0, 127].pack("C*")

  def self.tcp_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  MSP_REACHABLE = tcp_reachable?(MSP_HOST, MSP_PORT)

  def mssql_url
    "mssql://#{MSP_HOST}:#{MSP_PORT}/#{MSP_DB}"
  end

  def connect
    Tina4::Database.new(mssql_url, username: MSP_USER, password: MSP_PASS)
  end

  def drop(table)
    @db.execute("IF OBJECT_ID('#{table}', 'U') IS NOT NULL DROP TABLE #{table}")
  end

  # A fresh IDENTITY table with a NON-`id` PK so its identity restarts at 1.
  def fresh_nonid
    drop(MSP_NONID)
    @db.execute(
      "CREATE TABLE #{MSP_NONID} (person_key INT IDENTITY(1,1) PRIMARY KEY, " \
      "code VARCHAR(40) NOT NULL, qty INT)"
    )
  end

  def fresh_params
    drop(MSP_PARAMS)
    # Explicit NULL: FreeTDS / tiny_tds runs ANSI_NULL_DFLT_OFF, so an unspecified
    # column is NOT NULL there - mark the optional columns nullable so a
    # single-column insert does not trip the other column's NOT NULL default.
    @db.execute("CREATE TABLE #{MSP_PARAMS} (k INT PRIMARY KEY, txt VARCHAR(100) NULL, blob VARBINARY(100) NULL)")
  end

  def fresh_page
    drop(MSP_PAGE)
    @db.execute("CREATE TABLE #{MSP_PAGE} (id INT PRIMARY KEY, val VARCHAR(20))")
    %w[a b c d e].each_with_index do |v, i|
      @db.execute("INSERT INTO #{MSP_PAGE} (id, val) VALUES (?, ?)", [i + 1, v])
    end
  end

  # Every row on a SECOND connection - the durability witness.
  def fresh_rows(table, order_col)
    other = connect
    begin
      other.fetch("SELECT * FROM #{table} ORDER BY #{order_col}", [], limit: 1000).records
    ensure
      other.close rescue nil
    end
  end

  before do
    skip "no reachable MSSQL at #{MSP_HOST}:#{MSP_PORT} (set TINA4_TEST_MSSQL_*)" unless MSP_REACHABLE
    @db = connect
  end

  after do
    next unless @db

    [MSP_NONID, MSP_PARAMS, MSP_PAGE].each { |t| drop(t) rescue nil }
    @db.close rescue nil
  end

  # -- mssql-nonid-pk-generated-id ---------------------------------------------

  it "a non id primary key insert returns the generated last id" do
    fresh_nonid
    result = @db.insert(MSP_NONID, { "code" => "a", "qty" => 10 })
    expect(result.last_id).to eq(1)
    rows = fresh_rows(MSP_NONID, "person_key")
    expect(rows.length).to eq(1)
    expect(rows[0][:person_key]).to eq(1)
    expect(rows[0][:code]).to eq("a")
  end

  it "a second non id primary key insert returns the next generated id" do
    fresh_nonid
    first = @db.insert(MSP_NONID, { "code" => "a", "qty" => 10 })
    second = @db.insert(MSP_NONID, { "code" => "b", "qty" => 20 })
    expect(first.last_id).to eq(1)
    expect(second.last_id).to eq(2)
    expect(second.last_id).not_to eq(first.last_id)
  end

  it "a non id primary key insert reports affected rows of one" do
    fresh_nonid
    result = @db.insert(MSP_NONID, { "code" => "a", "qty" => 10 })
    expect(result.affected_rows).to eq(1)
  end

  # -- mssql-safe-params -------------------------------------------------------

  it "a binary parameter round trips intact" do
    fresh_params
    @db.execute("INSERT INTO #{MSP_PARAMS} (k, blob) VALUES (?, ?)", [1, MSP_BIN])
    other = connect
    begin
      row = other.fetch_one("SELECT blob FROM #{MSP_PARAMS} WHERE k = ?", [1])
    ensure
      other.close rescue nil
    end
    expect(row).not_to be_nil
    expect(row[:blob].to_s.b).to eq(MSP_BIN.b)
  end

  it "a text parameter round trips intact" do
    fresh_params
    text = "it's a \"quoted\" O'Brien value"
    # Ordinary UTF-8 text stays on the quoted-literal path (never mis-routed to a
    # 0x literal), with correct quote-doubling.
    @db.execute("INSERT INTO #{MSP_PARAMS} (k, txt) VALUES (?, ?)", [2, text])
    other = connect
    begin
      row = other.fetch_one("SELECT txt FROM #{MSP_PARAMS} WHERE k = ?", [2])
    ensure
      other.close rescue nil
    end
    expect(row).not_to be_nil
    expect(row[:txt]).to eq(text)
  end

  # -- mssql-offset-fetch-pagination -------------------------------------------

  it "a paginated query returns the first page window" do
    fresh_page
    result = @db.fetch("SELECT id, val FROM #{MSP_PAGE} ORDER BY id", [], limit: 2, offset: 0)
    expect(result.records.map { |r| r[:id].to_i }).to eq([1, 2])
  end

  it "a paginated query returns a later page window with offset" do
    fresh_page
    result = @db.fetch("SELECT id, val FROM #{MSP_PAGE} ORDER BY id", [], limit: 2, offset: 2)
    # OFFSET/FETCH; a TOP-only strategy that ignores the offset returns [1, 2].
    expect(result.records.map { |r| r[:id].to_i }).to eq([3, 4])
    expect(result.records.map { |r| r[:val] }).to eq(%w[c d])
  end

  # -- MSSQL-INTERP-RUBY mutation witness (Ruby-only: the bareword defect is
  #    local to Ruby's hand-rolled interpolator; see the fixture _comment) ------

  it "an unbindable parameter raises instead of a bareword" do
    fresh_params
    # A Symbol is not nil/bool/Time/String/Numeric - the old `else param.to_s`
    # spliced it as a bareword. It must now RAISE, never reach the DB.
    expect do
      @db.execute("INSERT INTO #{MSP_PARAMS} (k, txt) VALUES (?, ?)", [9, :some_symbol])
    end.to raise_error(ArgumentError, /cannot safely bind/)
    # And nothing was inserted (no bareword statement ran).
    count = @db.fetch("SELECT COUNT(*) AS c FROM #{MSP_PARAMS} WHERE k = ?", [9]).records[0][:c].to_i
    expect(count).to eq(0)
  end
end
