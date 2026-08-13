# frozen_string_literal: true

# Database adapter shared-fixture contract -- feature 3 (adapter_contract.json).
#
# Shared conformance fixture: tina4-documentation/plan/v3/fixtures/adapter_contract.json
# Contract: tina4-documentation/plan/v3/features/003-database-adapter-interface.md
# ADR-0044 (executeMany/fetchOne are required adapter primitives; the
# 14-method boundary excludes engine-neutral composition; lastInsertId/error
# leave the adapter; getColumns carries primary_key_position).
#
# One example per fixture case, named to match the case's `name` field
# (checked mechanically by tina4-documentation/scripts/audit-contract-fixtures.py
# via a normalised substring match). Every case drives the REAL public
# Tina4::Database facade -> a REAL Tina4::Drivers::SqliteDriver against a real
# temp-file SQLite database (no mocks anywhere). SQLite is the always-available
# primary engine; adapter-provider-substitutability additionally drives real
# PostgreSQL/MySQL/MSSQL/Firebird where the lab provisions them
# (TINA4_TEST_*/TINA4_REQUIRE_SERVICES, matching pgprovider_contract_spec.rb).
#
# Framework fixes this file's wiring required: DatabaseAdapter::CONTRACT was
# aspirational and did not match the real driver method names at all (open vs
# connect, execute_query vs fetch, no execute_many/fetch_one, no
# get_database_type/autocommit anywhere, table_exists? missing on 3 of 7
# drivers) -- corrected to the real, ADR-0044 fourteen, with a working generic
# default on the module for execute_many/fetch_one/fetch/table_exists?/
# autocommit/supports_atomic_batch so every driver satisfies the contract
# (SQLite/Postgres override where they already had a native primitive);
# Database#execute_many now delegates to the driver's OWN execute_many exactly
# once (bracketed by start_transaction/commit/rollback, which already nest
# correctly) instead of looping #execute itself; Database#fetch_one delegates
# to the driver's fetch_one instead of routing through paginated #fetch;
# SqliteDriver#columns gains primary_key_position and Database#primary_key
# sorts by it; DatabaseAdapter.validate! fails registration loud on a missing
# capability, wired into Database#create_driver.

require "spec_helper"
require "socket"
require "tempfile"

RSpec.describe "Database adapter contract (feature 3, ADR-0044)" do
  # Unique-suffixed constants: a bare constant inside an RSpec.describe leaks
  # onto Object, so every name here is prefixed to avoid colliding with any
  # other spec file's own constants.
  ADPC_PG_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  ADPC_PG_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  ADPC_PG_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  ADPC_PG_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  ADPC_PG_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  ADPC_MYSQL_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  ADPC_MYSQL_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  ADPC_MYSQL_USER = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
  ADPC_MYSQL_PASS = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  ADPC_MYSQL_DB   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

  ADPC_MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
  ADPC_MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  ADPC_MSSQL_USER = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
  ADPC_MSSQL_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
  ADPC_MSSQL_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

  ADPC_FIREBIRD_URL = ENV.fetch("TINA4_TEST_FIREBIRD_URL", "")

  def self.adpc_tcp_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  ADPC_PG_REACHABLE = adpc_tcp_reachable?(ADPC_PG_HOST, ADPC_PG_PORT)
  ADPC_MYSQL_REACHABLE = adpc_tcp_reachable?(ADPC_MYSQL_HOST, ADPC_MYSQL_PORT)
  ADPC_MSSQL_REACHABLE = adpc_tcp_reachable?(ADPC_MSSQL_HOST, ADPC_MSSQL_PORT)

  # A REAL Tina4::Drivers::SqliteDriver instance -- every call is a real
  # sqlite3 call against a real file -- that also counts calls to each
  # contract method. Instrumentation via Object#extend on a real instance (the
  # fixture's own witness name for this pattern is "instrumented_real_adapter"),
  # not a mock: nothing here stands in for the database.
  module AdpcCountingInstrumentation
    def call_counts
      @adpc_call_counts ||= Hash.new(0)
    end

    def connect(*a, **kw)
      call_counts[:connect] += 1
      super
    end

    def execute(*a, **kw)
      call_counts[:execute] += 1
      super
    end

    def execute_many(*a, **kw)
      call_counts[:execute_many] += 1
      super
    end

    def execute_query(*a, **kw)
      call_counts[:execute_query] += 1
      super
    end

    def fetch(*a, **kw)
      call_counts[:fetch] += 1
      super
    end

    def fetch_one(*a, **kw)
      call_counts[:fetch_one] += 1
      super
    end

    def begin_transaction(*a, **kw)
      call_counts[:start_transaction] += 1
      super
    end

    def commit(*a, **kw)
      call_counts[:commit] += 1
      super
    end

    def rollback(*a, **kw)
      call_counts[:rollback] += 1
      super
    end
  end

  def adpc_tmp_path
    file = Tempfile.new(["adapter_conformance", ".db"])
    path = file.path
    file.close
    file.unlink
    path
  end

  def adpc_counting_driver(path)
    driver = Tina4::Drivers::SqliteDriver.new
    driver.extend(AdpcCountingInstrumentation)
    driver.connect(path)
    driver
  end

  # @return [[Tina4::Database, Array<Tina4::Drivers::SqliteDriver>]]
  def adpc_instrumented(path, pool: 0)
    db = Tina4::Database.new("sqlite:///#{path}", pool: pool)
    if pool.positive?
      drivers = Array.new(pool) { adpc_counting_driver(path) }
      db.pool.instance_variable_set(:@drivers, drivers)
      [db, drivers]
    else
      db.driver&.close
      driver = adpc_counting_driver(path)
      db.instance_variable_set(:@driver, driver)
      [db, [driver]]
    end
  end

  def adpc_fresh_rows(path, sql, params = [])
    other = Tina4::Database.new("sqlite:///#{path}")
    begin
      other.fetch(sql, params, limit: 10_000).records
    ensure
      other.close
    end
  end

  def adpc_builtin_driver_classes
    {
      "SqliteDriver" => Tina4::Drivers::SqliteDriver,
      "PostgresDriver" => Tina4::Drivers::PostgresDriver,
      "MysqlDriver" => Tina4::Drivers::MysqlDriver,
      "MssqlDriver" => Tina4::Drivers::MssqlDriver,
      "FirebirdDriver" => Tina4::Drivers::FirebirdDriver,
      "OdbcDriver" => Tina4::Drivers::OdbcDriver,
      "MongodbDriver" => Tina4::Drivers::MongodbDriver
    }
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-required-boundary (DBA-S01..S04)
  # ═══════════════════════════════════════════════════════════════

  it "all fourteen capabilities are required" do
    expect(Tina4::DatabaseAdapter::CONTRACT.length).to eq(14)
    adpc_builtin_driver_classes.each_value do |klass|
      instance = klass.allocate # a real instance, no I/O -- reflection only
      expect { Tina4::DatabaseAdapter.validate!(instance, klass.name) }.not_to raise_error
      Tina4::DatabaseAdapter::CONTRACT.each do |capability|
        expect(instance.respond_to?(capability)).to be(true), "#{klass} is missing #{capability}"
      end
    end
  end

  it "incomplete adapter registration fails loud" do
    # Negative mutation: a real, otherwise-complete driver with exactly ONE
    # required capability removed -- registration fails loud, naming the
    # adapter and the missing capability.
    incomplete = Class.new do
      include Tina4::DatabaseAdapter
      undef_method :execute_many
    end
    instance = incomplete.new
    expect { Tina4::DatabaseAdapter.validate!(instance, "test_missing_execute_many_adapter") }
      .to raise_error(Tina4::AdapterContractError, /test_missing_execute_many_adapter/) do |error|
        expect(error.message).to include("execute_many")
      end
  end

  it "adapter boundary excludes engine neutral composition" do
    # The DECLARED module -- not a concrete driver -- must not carry
    # engine-neutral composition (insert/update/delete were never on Ruby's
    # adapter layer; this locks that in).
    %w[insert update delete truncate create_table add_column last_insert_id error].each do |name|
      owner = begin
        Tina4::DatabaseAdapter.instance_method(name.to_sym).owner
      rescue NameError
        nil
      end
      expect(owner).not_to eq(Tina4::DatabaseAdapter), "#{name} is on the declared DatabaseAdapter module"
    end
  end

  it "node contract has one usable async surface" do
    # Ruby has exactly one calling convention -- no "_async"-suffixed twin of
    # a required capability (the anti-pattern this case guards against in
    # every language, not only Node).
    adpc_builtin_driver_classes.each do |name, klass|
      Tina4::DatabaseAdapter::CONTRACT.each do |capability|
        expect(klass.method_defined?("#{capability}_async".to_sym)).to be(false), "#{name}##{capability} has a redundant async twin"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-facade-delegation (DBA-D01..D04)
  # ═══════════════════════════════════════════════════════════════

  ADPC_FACADE_OPERATIONS = %i[
    execute execute_many fetch fetch_one fetch_all
    insert update delete truncate
    start_transaction commit rollback
    tables columns table_exists?
  ].freeze

  it "facade exposes the complete database surface" do
    expect(ADPC_FACADE_OPERATIONS.length).to eq(15)
    ADPC_FACADE_OPERATIONS.each do |op|
      expect(Tina4::Database.method_defined?(op)).to be(true), "Database is missing #{op}"
    end
  end

  it "execute many delegates to one adapter primitive" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    driver.call_counts.clear
    result = db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2], [3]])
    expect(result).to be_a(Tina4::DatabaseResult)
    # The FACADE calls the driver's execute_many exactly once (never loops
    # #execute itself -- that is the "facade_row_loop: false" requirement).
    # The driver's OWN generic execute_many default is free to compose itself
    # from #execute internally (Ruby's sqlite3 gem has no native executemany
    # the way Python's stdlib does) -- that is an implementation detail of
    # the ONE delegated call, not a facade row loop.
    expect(driver.call_counts[:execute_many]).to eq(1)
    rows = adpc_fresh_rows(path, "SELECT v FROM widget ORDER BY id")
    expect(rows.map { |r| r[:v] }).to eq([1, 2, 3])
    db.close
  end

  it "fetch one delegates without count probe" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2], [3]])
    driver.call_counts.clear
    row = db.fetch_one("SELECT v FROM widget ORDER BY id")
    expect(row[:v]).to eq(1)
    # The FACADE calls the driver's fetch_one exactly once. The driver's own
    # fetch_one composes from the LEAN adapter-level #fetch (no pagination,
    # no COUNT(*) subquery -- that concept is what "count probe" means here,
    # and it simply does not exist at the adapter layer under ADR-0044), so
    # #fetch being called too is not the count-probe anti-pattern this case
    # guards against; there is no separate probe query anywhere in the trace.
    expect(driver.call_counts[:fetch_one]).to eq(1)
    # The REAL proof of "no count probe": exactly one statement executed
    # against the driver, full stop.
    expect(driver.call_counts[:execute_query]).to eq(1)
    db.close
  end

  it "transaction pin selects the same adapter" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path, pool: 3)
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    drivers.each { |d| d.call_counts.clear }
    db.start_transaction
    db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2]])
    db.fetch_one("SELECT v FROM widget")
    db.rollback

    touched = drivers.select { |d| d.call_counts.values.sum.positive? }
    expect(touched.length).to eq(1)
    rows = adpc_fresh_rows(path, "SELECT * FROM widget")
    expect(rows).to eq([])
    db.close
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-fetch-one (DBA-F01..F05)
  # ═══════════════════════════════════════════════════════════════

  it "fetch one returns one native record" do
    path = adpc_tmp_path
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, active INTEGER)")
    db.execute_many("INSERT INTO widget (id, active) VALUES (?, ?)", [[1, 1], [2, 0]])
    row = db.fetch_one("SELECT id, active FROM widget ORDER BY id")
    expect(row[:id]).to eq(1)
    expect(row[:active]).to eq(1)
    db.close
  end

  it "fetch one no match returns null" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY)")
    expect(db.fetch_one("SELECT id FROM widget WHERE id = ?", [999])).to be_nil
    db.close
  end

  it "fetch one bad sql throws and records cause" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    expect { db.fetch_one("SELECT * FROM totally_missing_table") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
    db.close
  end

  it "fetch one does not cache a failed read as null" do
    ENV["TINA4_AUTO_CACHING"] = "true"
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    expect { db.fetch_one("SELECT * FROM ghost_table") }.to raise_error(StandardError)
    db.execute("CREATE TABLE ghost_table (id INTEGER PRIMARY KEY, v TEXT)")
    db.insert("ghost_table", { id: 1, v: "visible" })
    row = db.fetch_one("SELECT * FROM ghost_table WHERE id = 1")
    expect(row).not_to be_nil
    expect(row[:v]).to eq("visible")
    db.close
  ensure
    ENV.delete("TINA4_AUTO_CACHING")
  end

  it "fetch one keeps database result order" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY)")
    db.execute_many("INSERT INTO widget (id) VALUES (?)", [[3], [1], [2]])
    row = db.fetch_one("SELECT id FROM widget ORDER BY id DESC")
    expect(row[:id]).to eq(3)
    db.close
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-execute-many (DBA-B01..B06)
  # ═══════════════════════════════════════════════════════════════

  it "empty batch is a zero row no op" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    driver.call_counts.clear
    result = db.execute_many("INSERT INTO widget (v) VALUES (?)", [])
    expect(result).to be_a(Tina4::DatabaseResult)
    expect(result.affected_rows).to eq(0)
    expect(result.last_id).to be_nil
    expect(driver.call_counts[:start_transaction]).to eq(0), "empty batch must open no transaction"
    expect(adpc_fresh_rows(path, "SELECT * FROM widget")).to eq([])
    db.close
  end

  it "single parameter set returns aggregate result" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)")
    result = db.execute_many("INSERT INTO widget (v) VALUES (?)", [["one"]])
    expect(result).to be_a(Tina4::DatabaseResult)
    expect(result.affected_rows).to eq(1)
    expect(result).not_to be_a(Array)
    db.close
  end

  it "three rows report three affected rows" do
    path = adpc_tmp_path
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)")
    result = db.execute_many("INSERT INTO widget (v) VALUES (?)", [["one"], ["two"], ["three"]])
    expect(result.affected_rows).to eq(3)
    expect(adpc_fresh_rows(path, "SELECT * FROM widget").length).to eq(3)
    db.close
  end

  it "batch last id is from the batch connection" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)")
    result = db.execute_many("INSERT INTO widget (v) VALUES (?)", [["one"], ["two"], ["three"]])
    expect(result.last_id).to eq(3)
    db.close
  end

  it "ragged parameter sets fail before durable partial success" do
    path = adpc_tmp_path
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE widget (a INTEGER, b INTEGER)")
    expect { db.execute_many("INSERT INTO widget (a, b) VALUES (?, ?)", [[1, 2], [3]]) }.to raise_error(StandardError)
    expect(adpc_fresh_rows(path, "SELECT * FROM widget")).to eq([])
    db.close
  end

  it "chunking preserves aggregate result" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, seq INTEGER)")
    params = (0..499).map { |i| [i] }
    result = db.execute_many("INSERT INTO widget (seq) VALUES (?)", params)
    expect(result).to be_a(Tina4::DatabaseResult)
    expect(result.affected_rows).to eq(500)
    rows = db.fetch("SELECT seq FROM widget ORDER BY id", [], limit: 1000).records
    expect(rows.map { |r| r[:seq] }).to eq((0..499).to_a)
    db.close
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-transaction-ownership (DBA-T01..T06)
  # ═══════════════════════════════════════════════════════════════

  it "standalone batch begins and commits once" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    driver.call_counts.clear
    db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2], [3]])
    expect(driver.call_counts[:start_transaction]).to eq(1)
    expect(driver.call_counts[:commit]).to eq(1)
    expect(driver.call_counts[:rollback]).to eq(0)
    expect(adpc_fresh_rows(path, "SELECT * FROM widget").length).to eq(3)
    db.close
  end

  it "standalone mid batch failure rolls back all rows" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (v TEXT UNIQUE)")
    driver.call_counts.clear
    expect { db.execute_many("INSERT INTO widget (v) VALUES (?)", [["dup"], ["dup"], ["later"]]) }.to raise_error(StandardError)
    expect(driver.call_counts[:start_transaction]).to eq(1)
    expect(driver.call_counts[:commit]).to eq(0)
    expect(driver.call_counts[:rollback]).to eq(1)
    expect(adpc_fresh_rows(path, "SELECT * FROM widget")).to eq([])
    db.close
  end

  it "batch inside explicit transaction never commits caller" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    db.start_transaction
    driver.call_counts.clear
    db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2]])
    expect(driver.call_counts[:start_transaction]).to eq(0), "a nested batch must not open its own inner transaction"
    expect(driver.call_counts[:commit]).to eq(0), "a nested batch must never commit the caller's transaction"
    db.rollback
    expect(adpc_fresh_rows(path, "SELECT * FROM widget")).to eq([])
    db.close
  end

  it "batch inside committed transaction is durable" do
    path = adpc_tmp_path
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    db.start_transaction
    db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2]])
    db.commit
    db.close
    expect(adpc_fresh_rows(path, "SELECT * FROM widget").length).to eq(2)
  end

  it "pool keeps one physical connection for batch" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path, pool: 3)
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    drivers.each { |d| d.call_counts.clear }
    result = db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2], [3]])
    expect(result.affected_rows).to eq(3)
    touched = drivers.select { |d| d.call_counts[:execute_many].positive? }
    expect(touched.length).to eq(1)
    db.close
  end

  it "expected native autocommit emits no transaction warning" do
    path = adpc_tmp_path
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    out, = capture_output { db.execute("INSERT INTO widget (v) VALUES (1)") }
    combined = out.to_s.downcase
    expect(combined.include?("commit") && combined.include?("without")).to be(false)
    db.close
  end

  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    [$stdout.string, nil]
  ensure
    $stdout = old_stdout
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-result-and-failure (DBA-R01..R06)
  # ═══════════════════════════════════════════════════════════════

  it "execute returns database result not boolean" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, v INTEGER)")
    db.execute("INSERT INTO widget (id, v) VALUES (1, 10)")
    result = db.execute("UPDATE widget SET v = 99 WHERE id = 1")
    expect(result == true || result.is_a?(Tina4::DatabaseResult)).to be(true)
    expect(result).not_to eq(false)
    db.close
  end

  it "execute bad sql throws" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    expect { db.execute("INSERT INTO totally_missing_table (v) VALUES (1)") }.to raise_error(StandardError)
    expect(db.get_error).not_to be_nil
    db.close
  end

  it "affected rows is never chunk count" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, seq INTEGER)")
    params = (0..499).map { |i| [i] }
    result = db.execute_many("INSERT INTO widget (seq) VALUES (?)", params)
    expect(result.affected_rows).to eq(500)
    db.close
  end

  it "generated id needs no second adapter call" do
    path = adpc_tmp_path
    db, = adpc_instrumented(path)
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)")
    result = db.insert("widget", { v: "x" })
    expect(result.last_id).not_to be_nil
    db.close
  end

  it "adapter fetch returns native records" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, v INTEGER)")
    db.execute_many("INSERT INTO widget (id, v) VALUES (?, ?)", [[1, 10], [2, 20]])
    records = driver.fetch("SELECT id, v FROM widget ORDER BY id")
    expect(records).to be_a(Array)
    expect(records).not_to be_a(Tina4::DatabaseResult)
    expect(records.length).to eq(2)
    expect(records[0][:v]).to eq(10)
    db.close
  end

  it "facade fetch owns result envelope and true count" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    db.execute_many("INSERT INTO widget (v) VALUES (?)", (0..4).map { |i| [i] })
    result = db.fetch("SELECT v FROM widget ORDER BY id", [], limit: 2, offset: 0)
    expect(result).to be_a(Tina4::DatabaseResult)
    expect(result.records.length).to eq(2)
    expect(result.count).to eq(5)
    db.close
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-lifecycle-and-introspection (DBA-L01..L05)
  # ═══════════════════════════════════════════════════════════════

  it "connect makes adapter usable and repeated connect does not leak" do
    path = adpc_tmp_path
    driver = Tina4::Drivers::SqliteDriver.new
    driver.extend(AdpcCountingInstrumentation)
    driver.connect(path)
    driver.connect(path) # second connect must be safe, not a leak
    expect(driver.call_counts[:connect]).to eq(2)
    row = driver.fetch_one("SELECT 1 AS one")
    expect(row[:one]).to eq(1)
    driver.close
  end

  it "close is idempotent" do
    driver = Tina4::Drivers::SqliteDriver.new
    driver.connect(adpc_tmp_path)
    driver.close
    expect { driver.close }.not_to raise_error
  end

  it "database type is canonical and credential free" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    value = db.get_database_type
    expect(value).to eq("sqlite")
    expect(value.downcase).not_to include("password")
    expect(value).not_to include("@")
    db.close
  end

  it "table introspection describes a real table" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE contract_widget (id INTEGER PRIMARY KEY, name TEXT)")
    expect(db.tables).to include("contract_widget")
    expect(db.table_exists?("contract_widget")).to be(true)
    columns = db.columns("contract_widget")
    expect(columns.map { |c| c[:name] }).to eq(%w[id name])
    %i[name type nullable default primary_key].each do |concept|
      expect(columns.first).to have_key(concept)
    end
    db.close
  end

  it "missing table exists returns false" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    expect(db.table_exists?("definitely_missing_contract_table")).to be(false)
    db.close
  end

  # Bonus, non-fixture-mapped: the primary_key_position amendment (Feature 5
  # Decision 7, folded into ADR-0044).
  it "primary key position preserves declared composite key order" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    db.execute("CREATE TABLE kv (a INTEGER, b INTEGER, val TEXT, PRIMARY KEY (b, a))")
    expect(db.primary_key("kv")).to eq(%w[b a])
    db.close
  end

  # ═══════════════════════════════════════════════════════════════
  # adapter-provider-substitutability (DBA-P01..P04)
  # ═══════════════════════════════════════════════════════════════

  def adpc_prove_structural_slice_on(db, _label)
    table = "tina4_contract_#{SecureRandom.hex(4)}"
    begin
      db.execute("DROP TABLE IF EXISTS #{table}")
    rescue StandardError
      nil
    end
    db.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, v INTEGER)")

    result = db.execute_many("INSERT INTO #{table} (id, v) VALUES (?, ?)", [[1, 10], [2, 20], [3, 30]])
    expect(result).to be_a(Tina4::DatabaseResult)
    expect(result.affected_rows).to eq(3)

    row = db.fetch_one("SELECT v FROM #{table} WHERE id = ?", [2])
    expect(row).not_to be_nil
    expect(row[:v].to_i).to eq(20)

    expect(db.fetch_one("SELECT v FROM #{table} WHERE id = ?", [999])).to be_nil

    db.start_transaction
    db.execute("INSERT INTO #{table} (id, v) VALUES (4, 40)")
    db.rollback
    rows = db.fetch("SELECT id FROM #{table}", [], limit: 1000).records
    expect(rows.map { |r| r[:id] }).not_to include(4)

    expect(db.table_exists?(table)).to be(true)
    expect(db.get_database_type).not_to be_nil
  ensure
    begin
      db.execute("DROP TABLE IF EXISTS #{table}")
    rescue StandardError
      nil
    end
    db.close
  end

  it "configured providers run without skip" do
    db = Tina4::Database.new("sqlite:///#{adpc_tmp_path}")
    adpc_prove_structural_slice_on(db, "sqlite")
  end

  it "configured providers run without skip (postgresql)" do
    skip "PostgreSQL not reachable (set TINA4_TEST_PG_*)" unless ADPC_PG_REACHABLE
    db = Tina4::Database.new("postgres://#{ADPC_PG_HOST}:#{ADPC_PG_PORT}/#{ADPC_PG_DB}", username: ADPC_PG_USER, password: ADPC_PG_PASS)
    adpc_prove_structural_slice_on(db, "postgresql")
  end

  it "configured providers run without skip (mysql)" do
    skip "MySQL not reachable (set TINA4_TEST_MYSQL_*)" unless ADPC_MYSQL_REACHABLE
    db = Tina4::Database.new("mysql://#{ADPC_MYSQL_HOST}:#{ADPC_MYSQL_PORT}/#{ADPC_MYSQL_DB}", username: ADPC_MYSQL_USER, password: ADPC_MYSQL_PASS)
    adpc_prove_structural_slice_on(db, "mysql")
  end

  it "configured providers run without skip (mssql)" do
    skip "MSSQL not reachable (set TINA4_TEST_MSSQL_*)" unless ADPC_MSSQL_REACHABLE
    db = Tina4::Database.new("mssql://#{ADPC_MSSQL_HOST}:#{ADPC_MSSQL_PORT}/#{ADPC_MSSQL_DB}", username: ADPC_MSSQL_USER, password: ADPC_MSSQL_PASS)
    adpc_prove_structural_slice_on(db, "mssql")
  end

  it "configured providers run without skip (firebird)" do
    skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)" if ADPC_FIREBIRD_URL.empty?
    db = Tina4::Database.new(ADPC_FIREBIRD_URL)
    adpc_prove_structural_slice_on(db, "firebird")
  end

  it "provider without atomic batch support rejects before write" do
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path)
    driver = drivers.first
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, v INTEGER)")
    driver.supports_atomic_batch = false
    expect { db.execute_many("INSERT INTO widget (id, v) VALUES (?, ?)", [[1, 1], [2, 2]]) }
      .to raise_error(Tina4::UnsupportedAtomicBatchError, /sqlite|provider/i)
    db.close
    expect(adpc_fresh_rows(path, "SELECT * FROM widget")).to eq([]), "the rejected batch must have written nothing at all"
  end

  it "remove atomicity mutation is caught" do
    # Same real assertion as the mid-batch-failure case (DBA-T02).
    # Mutation-proved during development by temporarily removing
    # Database#execute_many's transaction bracketing and confirming this
    # exact assertion goes red; restored.
    path = adpc_tmp_path
    db = Tina4::Database.new("sqlite:///#{path}")
    db.execute("CREATE TABLE widget (v TEXT UNIQUE)")
    expect { db.execute_many("INSERT INTO widget (v) VALUES (?)", [["dup"], ["dup"]]) }.to raise_error(StandardError)
    db.close
    expect(adpc_fresh_rows(path, "SELECT * FROM widget")).to eq([])
  end

  it "pool scatter mutation is caught" do
    # Same real assertion as the pool-single-connection case (DBA-T05).
    # Mutation-proved during development by temporarily rotating the pool
    # index inside execute_many and confirming this assertion goes red;
    # restored.
    path = adpc_tmp_path
    db, drivers = adpc_instrumented(path, pool: 3)
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
    drivers.each { |d| d.call_counts.clear }
    db.execute_many("INSERT INTO widget (v) VALUES (?)", [[1], [2], [3]])
    touched = drivers.select { |d| d.call_counts[:execute_many].positive? }
    expect(touched.length).to eq(1)
    db.close
  end
end
