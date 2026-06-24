# frozen_string_literal: true
#
# Regression spec for the batch-insert fix (cross-framework parity with the
# Python master).
#
# db.insert(table, [hash, hash, hash]) — an ARRAY of rows — is the advertised
# batch-insert form (CLAUDE.md: "db.insert(table, data)"; book + docs show
# db.insert("users", [{...}, {...}])). It MUST:
#
#   1. insert ALL the rows (verified by reading them back), and
#   2. report affected_rows == the number of rows, run inside ONE transaction on
#      ONE connection so the count / last_id are deterministic (never scattered
#      across pooled connections), and
#   3. surface a sensible last_id where the engine exposes one (SERIAL /
#      AUTOINCREMENT) and nil where it does not.
#
# Before the fix the batch returned the raw Array from execute_many — no
# affected_rows, no last_id — so `result.affected_rows == 3` was unavailable.
# The single-row insert path is unchanged.
#
# SQLite runs always (temp file). PostgreSQL, MySQL and MSSQL run against the
# live containers and skip with a '<engine> ... not reachable' / '<driver> ...
# not installed' reason when the service or its optional driver gem (mysql2 /
# tiny_tds, in the OPTIONAL :databases bundle group) is absent. Each skip reason
# carries a service keyword + an unavailable hint, so the TINA4_REQUIRE_SERVICES
# gate in spec_helper flips a provisioned-but-skipped run into a hard failure
# (#262 provisions MySQL 8 + MSSQL 2022 in CI).

require "spec_helper"
require "socket"
require "tmpdir"
require "fileutils"

PG_HOST_BI = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PG_PORT_BI = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
PG_USER_BI = ENV.fetch("TINA4_TEST_PG_USER", "tina4")
PG_PASS_BI = ENV.fetch("TINA4_TEST_PG_PASS", "tina4")
PG_DB_BI   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def batch_pg_reachable?
  TCPSocket.new(PG_HOST_BI, PG_PORT_BI).tap(&:close)
  true
rescue StandardError
  false
end

def batch_pg_gem?
  require "pg"
  true
rescue LoadError
  false
end

# ── MySQL / MSSQL live config (canonical TINA4_TEST_* convention, #262). ──────
# Defined file-local (the _BI suffix) so `rspec spec/batch_insert_spec.rb` runs
# standalone — it must not depend on constants/helpers another spec file defines.
# Mirrors the reachability + driver-gem gating in database_mysql_mssql_live_spec.
MYSQL_BI_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "localhost")
MYSQL_BI_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
MYSQL_BI_USER = ENV.fetch("TINA4_TEST_MYSQL_USER", "tina4")
MYSQL_BI_PASS = ENV.fetch("TINA4_TEST_MYSQL_PASS", "tina4")
MYSQL_BI_DB   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

MSSQL_BI_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
MSSQL_BI_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
MSSQL_BI_USER = ENV.fetch("TINA4_TEST_MSSQL_USER", "sa")
MSSQL_BI_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASS", "TinaSQL123!Secure")
MSSQL_BI_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

def batch_mysql_reachable?
  TCPSocket.new(MYSQL_BI_HOST, MYSQL_BI_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def batch_mysql2_gem?
  require "mysql2"
  true
rescue LoadError
  false
end

def batch_mssql_reachable?
  TCPSocket.new(MSSQL_BI_HOST, MSSQL_BI_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def batch_tiny_tds_gem?
  require "tiny_tds"
  true
rescue LoadError
  false
end

# Shared batch-insert contract — exercised against each reachable engine.
RSpec.shared_examples "a batch insert" do
  let(:rows) do
    [
      { name: "Alice", price: 1.0 },
      { name: "Bob",   price: 2.0 },
      { name: "Carol", price: 3.0 }
    ]
  end

  it "inserts ALL three rows (read back) and reports affected_rows == 3" do
    result = db.insert(table, rows)

    # 2. affected_rows == row count
    expect(result.affected_rows).to eq(3)

    # 1. every row is actually in the table
    read = db.fetch("SELECT name FROM #{table} ORDER BY name", [], limit: 100)
    names = read.map { |r| r[:name] || r["name"] }
    expect(names).to eq(%w[Alice Bob Carol])
  end

  it "surfaces a sensible last_id for an auto-increment PK" do
    result = db.insert(table, rows)
    next unless exposes_last_id

    # The last row inserted owns the highest id; last_id must be a positive
    # integer equal to that row's id (deterministic — one connection).
    expect(result.last_id).to be_a(Integer)
    expect(result.last_id).to be > 0
    max_id = db.fetch_one("SELECT MAX(id) AS m FROM #{table}")[:m].to_i
    expect(result.last_id).to eq(max_id)
  end

  it "does not crash or alter single-row insert (still a single row, has last_id)" do
    result = db.insert(table, { name: "Solo", price: 9.0 })
    # Single-row path returns the engine's usual shape (Hash with :last_id for
    # SQLite/MySQL/MSSQL, DatabaseResult-ish for PG) — never an array batch.
    count = db.fetch_one("SELECT COUNT(*) AS c FROM #{table} WHERE name = ?", ["Solo"])[:c].to_i
    expect(count).to eq(1)
    expect(result).not_to be_nil
  end

  it "empty array is a no-op reporting affected_rows == 0" do
    result = db.insert(table, [])
    expect(result.affected_rows).to eq(0)
    count = db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c].to_i
    expect(count).to eq(0)
  end
end

RSpec.describe "Batch insert — SQLite (always runs)" do
  let(:table) { "batch_products" }
  let(:exposes_last_id) { true }

  before(:each) do
    @dir = Dir.mktmpdir("tina4_batch")
    @db = Tina4::Database.new("sqlite:///#{File.join(@dir, 'batch.db')}")
    @db.execute(
      "CREATE TABLE #{table} (id INTEGER PRIMARY KEY AUTOINCREMENT, " \
      "name TEXT, price REAL)"
    )
  end

  after(:each) do
    @db&.close
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  let(:db) { @db }

  include_examples "a batch insert"
end

RSpec.describe "Batch insert — PostgreSQL (live)" do
  let(:table) { "batch_products_pg" }
  let(:exposes_last_id) { true }

  before(:all) do
    @skip_reason = if !batch_pg_gem?
                     "pg gem not installed (skip)"
                   elsif !batch_pg_reachable?
                     "PostgreSQL not reachable at #{PG_HOST_BI}:#{PG_PORT_BI} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PG_HOST_BI}:#{PG_PORT_BI}/#{PG_DB_BI}",
      username: PG_USER_BI, password: PG_PASS_BI
    )
    @db.execute("DROP TABLE IF EXISTS #{table}")
    @db.execute("CREATE TABLE #{table} (id SERIAL PRIMARY KEY, name TEXT, price DOUBLE PRECISION)")
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS #{table}")
    ensure
      @db.close rescue nil
    end
  end

  let(:db) { @db }

  include_examples "a batch insert"

  it "runs the batch in ONE transaction (rolls back as a unit on a bad row)" do
    skip(@skip_reason) if @skip_reason
    # A NOT NULL violation on the third row must roll the whole batch back —
    # no partial inserts — because the batch is one transaction on one
    # connection.
    @db.execute("ALTER TABLE #{table} ALTER COLUMN name SET NOT NULL")
    expect do
      @db.insert(table, [
        { name: "ok1", price: 1.0 },
        { name: "ok2", price: 2.0 },
        { name: nil,   price: 3.0 } # violates NOT NULL
      ])
    end.to raise_error(StandardError)

    count = @db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c].to_i
    expect(count).to eq(0)
  end
end

RSpec.describe "Batch insert — MySQL (live)" do
  let(:table) { "batch_products_mysql" }
  let(:exposes_last_id) { true }

  before(:all) do
    @skip_reason = if !batch_mysql2_gem?
                     "mysql2 gem not installed (MySQL driver unavailable) — install the :databases bundle group"
                   elsif !batch_mysql_reachable?
                     "MySQL not reachable at #{MYSQL_BI_HOST}:#{MYSQL_BI_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "mysql://#{MYSQL_BI_HOST}:#{MYSQL_BI_PORT}/#{MYSQL_BI_DB}",
      username: MYSQL_BI_USER, password: MYSQL_BI_PASS
    )
    @db.execute("DROP TABLE IF EXISTS #{table}")
    # InnoDB (mysql:8 default) gives the batch a real transactional rollback.
    @db.execute(
      "CREATE TABLE #{table} (id INT AUTO_INCREMENT PRIMARY KEY, " \
      "name VARCHAR(100), price DOUBLE) ENGINE=InnoDB"
    )
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("DROP TABLE IF EXISTS #{table}")
    ensure
      @db.close rescue nil
    end
  end

  let(:db) { @db }

  include_examples "a batch insert"

  it "runs the batch in ONE transaction (rolls back as a unit on a bad row)" do
    skip(@skip_reason) if @skip_reason
    # MySQL spells NOT NULL as MODIFY (vs PostgreSQL's ALTER COLUMN ... SET).
    @db.execute("ALTER TABLE #{table} MODIFY name VARCHAR(100) NOT NULL")
    expect do
      @db.insert(table, [
        { name: "ok1", price: 1.0 },
        { name: "ok2", price: 2.0 },
        { name: nil,   price: 3.0 } # violates NOT NULL
      ])
    end.to raise_error(StandardError)

    count = @db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c].to_i
    expect(count).to eq(0)
  end
end

RSpec.describe "Batch insert — MSSQL (live)" do
  let(:table) { "batch_products_mssql" }
  let(:exposes_last_id) { true }

  before(:all) do
    @skip_reason = if !batch_tiny_tds_gem?
                     "tiny_tds gem not installed (MSSQL driver unavailable) — install the :databases bundle group"
                   elsif !batch_mssql_reachable?
                     "MSSQL not reachable at #{MSSQL_BI_HOST}:#{MSSQL_BI_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "mssql://#{MSSQL_BI_HOST}:#{MSSQL_BI_PORT}/#{MSSQL_BI_DB}",
      username: MSSQL_BI_USER, password: MSSQL_BI_PASS
    )
    @db.execute("IF OBJECT_ID('#{table}', 'U') IS NOT NULL DROP TABLE #{table}")
    @db.execute(
      "CREATE TABLE #{table} (id INT IDENTITY(1,1) PRIMARY KEY, " \
      "name VARCHAR(100), price FLOAT)"
    )
  end

  after(:each) do
    next unless @db
    begin
      @db.execute("IF OBJECT_ID('#{table}', 'U') IS NOT NULL DROP TABLE #{table}")
    ensure
      @db.close rescue nil
    end
  end

  let(:db) { @db }

  include_examples "a batch insert"

  it "runs the batch in ONE transaction (rolls back as a unit on a bad row)" do
    skip(@skip_reason) if @skip_reason
    # SQL Server spells NOT NULL as ALTER COLUMN <col> <type> NOT NULL.
    @db.execute("ALTER TABLE #{table} ALTER COLUMN name VARCHAR(100) NOT NULL")
    expect do
      @db.insert(table, [
        { name: "ok1", price: 1.0 },
        { name: "ok2", price: 2.0 },
        { name: nil,   price: 3.0 } # violates NOT NULL
      ])
    end.to raise_error(StandardError)

    count = @db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c].to_i
    expect(count).to eq(0)
  end
end
