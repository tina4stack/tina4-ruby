# frozen_string_literal: true

# Seeder + fake-data cross-engine contract - feature 28 (seeder_contract.json),
# parity with tina4-python/tests/test_seeder_contract.py.
#
# SEED-DEC-01 (OWNER-DECISIONS.md Batch 4, feature 028-seeder-fake-data.md):
#   * SEED-PHP-BACKTICK is PHP-specific (not reproducible here - Ruby's
#     seed_table already routes every INSERT through db.insert(), the
#     parameterized adapter path, so it was never backtick-quoted). Ruby's
#     part of the contract is engine-portability parity: seed_table inserts
#     correctly on the SAME PostgreSQL/MSSQL/Firebird engines PHP's fix
#     targets, proven below.
#   * SEED-TABLE-SEED-INERT: seed_table's `seed:` keyword is REMOVED
#     (SEED-DEC-01, ratified 2026-08-11 - same principle as the no-op
#     ForeignKeyField on_delete). Ruby's seed_table was, uniquely among the
#     four, NOT fully inert for the plain type-symbol columns form (its
#     internal FakeData WAS threaded by the old seed: kwarg for that one
#     path) - it is unified anyway for consistency with the ratified decision
#     and because the old behaviour was a footgun: it silently stopped being
#     deterministic the moment a caller supplied their own generator callable
#     that ignored the internal FakeData. Passing seed: now raises
#     ArgumentError: unknown keyword: :seed (Ruby's own signature error - no
#     custom code needed). The documented replacement, proven below, is a
#     caller-seeded FakeData closed over in `columns`.
#
# SEED-DEC-02 (low, Ruby-specific): FakeData#boolean returned 0/1 (Integer)
# instead of a native true/false - fixed. seed_orm's idempotency short-circuit
# used to run unconditionally, silently skipping a seed run whenever the
# table already held >= count rows (even unrelated ones) - it is now opt-in
# via `idempotent: true`, off by default, matching Python/PHP/Node (which
# never had this behaviour). SEED-DETERMINISM-PERLANG and SEED-SECRETS-DOC
# are documented on the FakeData class docblock in all four.
# SEED-VOCAB-PARITY pins one generator vocabulary (idiomatic spelling per
# language) present in all four, gated below.
#
# Real engines only, no mocks: SQLite (local, fast) + PostgreSQL :55432 +
# MSSQL :1433 + Firebird :3050 (the lab's real service coordinates - same
# TINA4_TEST_* convention as pgprovider/mssqlprovider/firebirdprovider
# contract specs). seed_table_inserts_on_every_engine is the case that must
# run on all three non-SQLite engines. The other cases are seeder-LOGIC
# properties (RNG determinism, FK topo-order, failure counting) that are
# engine-agnostic once routed through the already adapter-contract-proven
# db.insert()/ORM#save paths, so they run on SQLite + PostgreSQL for a
# real-engine sanity check without re-proving the adapter contracts again.

require "spec_helper"
require "socket"
require "set"

# ── ORM fixtures (top level - Ruby ORM classes are defined once, not per
#    example; unique names avoid colliding with other specs') ─────────────

class SeederContractAuthor < Tina4::ORM
  table_name "seedercontract_author"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class SeederContractBook < Tina4::ORM
  table_name "seedercontract_book"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  foreign_key_field :author_id, references: SeederContractAuthor
end

class SeederContractPerson < Tina4::ORM
  table_name "seedercontract_person"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :email
  integer_field :age
end

RSpec.describe "Seeder + fake-data cross-engine contract (feature 28)" do
  # Unique-suffixed constants (SDRC = SeeDeR Contract): a bare constant inside
  # an RSpec.describe leaks onto Object, so name them to avoid colliding with
  # another spec's TINA4_TEST_PG_HOST-style constant.
  SDRC_PG_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  SDRC_PG_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  SDRC_PG_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  SDRC_PG_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  SDRC_PG_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  SDRC_MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
  SDRC_MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  SDRC_MSSQL_USER = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
  SDRC_MSSQL_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
  SDRC_MSSQL_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

  SDRC_FIREBIRD_URL = ENV["TINA4_TEST_FIREBIRD_URL"]

  SDRC_GENERATOR_VOCABULARY = %i[
    name first_name last_name email phone address city country zip_code
    company job_title sentence paragraph text word integer numeric boolean
    date datetime uuid url color_hex currency ip_address credit_card choice
    for_field
  ].freeze

  def self.tcp_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  SDRC_PG_REACHABLE = tcp_reachable?(SDRC_PG_HOST, SDRC_PG_PORT)
  SDRC_MSSQL_REACHABLE = tcp_reachable?(SDRC_MSSQL_HOST, SDRC_MSSQL_PORT)

  def pg_db
    Tina4::Database.new(
      "postgres://#{SDRC_PG_HOST}:#{SDRC_PG_PORT}/#{SDRC_PG_DB}",
      username: SDRC_PG_USER, password: SDRC_PG_PASS
    )
  end

  def mssql_db
    Tina4::Database.new(
      "mssql://#{SDRC_MSSQL_HOST}:#{SDRC_MSSQL_PORT}/#{SDRC_MSSQL_DB}",
      username: SDRC_MSSQL_USER, password: SDRC_MSSQL_PASS
    )
  end

  def firebird_db
    Tina4::Database.new(SDRC_FIREBIRD_URL, username: "SYSDBA", password: "masterkey")
  end

  def drop_all(db, *statements)
    statements.each do |sql|
      begin
        db.execute(sql)
      rescue StandardError
        # best effort - tolerant of "does not exist" on a fresh DB
      end
    end
  end

  def reset_orm_bindings
    Tina4.bind_database(nil) if Tina4.respond_to?(:bind_database)
  end

  # ── seed_table_inserts_on_every_engine ──────────────────────────────────
  # Catches engine-portability regressions (SEED-PHP-BACKTICK is PHP-only,
  # but the SAME contract - real inserts on PG/MSSQL/Firebird - is proven for
  # Ruby too): creates the table with each engine's real DDL, seeds 5 rows
  # through seed_table (raw-SQL INSERT path via db.insert - no ORM), and
  # reads every row back on the SAME engine.

  def assert_seed_table_roundtrips(db, table, setup:, drop:)
    drop_all(db, *drop)
    begin
      setup.each { |sql| db.execute(sql) }
      Tina4.bind_database(db)
      fake = Tina4::FakeData.new(seed: 1)
      summary = Tina4.seed_table(table, {
        "name" => -> { fake.name },
        "score" => -> { fake.integer(min: 1, max: 100) },
      }, count: 5)
      expect(summary.seeded).to eq(5), "#{table}: seeded=#{summary.seeded} errors=#{summary.errors.inspect}"
      expect(summary.failed).to eq(0)
      rows = db.fetch("SELECT name, score FROM #{table}", [], limit: 100).to_a
      expect(rows.length).to eq(5)
      rows.each do |row|
        # Firebird's driver (spec/../lib/tina4/drivers/firebird_driver.rb) has
        # been separately observed returning STRING keys where SQLite/
        # PostgreSQL/MSSQL return Symbol keys for the identical fetch() call —
        # a pre-existing cross-engine inconsistency outside feature 28's scope
        # (it is feature 12's Firebird-adapter contract, not the seeder's).
        # Accept either so this seeder portability case is not blocked by it;
        # flagged separately for its own fix.
        name = row[:name] || row["name"]
        score = row[:score] || row["score"]
        expect(name).not_to be_nil
        expect(name.to_s).not_to be_empty
        expect(score.to_i).to be_between(1, 100)
      end
    ensure
      drop_all(db, *drop)
      db.close rescue nil
    end
  end

  it "seed_table_inserts_on_every_engine (sqlite)" do
    Dir.mktmpdir("tina4_seeder_contract") do |dir|
      db = Tina4::Database.new("sqlite:///" + File.join(dir, "seed_contract.db"))
      assert_seed_table_roundtrips(
        db, "contract_sqlite",
        setup: ["CREATE TABLE contract_sqlite (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, score INTEGER)"],
        drop: ["DROP TABLE contract_sqlite"],
      )
    end
  end

  it "seed_table_inserts_on_every_engine (postgresql)" do
    skip "no reachable postgres at #{SDRC_PG_HOST}:#{SDRC_PG_PORT} (set TINA4_TEST_PG_*)" unless SDRC_PG_REACHABLE
    assert_seed_table_roundtrips(
      pg_db, "contract_pg",
      setup: ["CREATE TABLE contract_pg (id SERIAL PRIMARY KEY, name VARCHAR(100), score INTEGER)"],
      drop: ["DROP TABLE contract_pg"],
    )
  end

  it "seed_table_inserts_on_every_engine (mssql)" do
    skip "MSSQL not reachable at #{SDRC_MSSQL_HOST}:#{SDRC_MSSQL_PORT} (set TINA4_TEST_MSSQL_*)" unless SDRC_MSSQL_REACHABLE
    assert_seed_table_roundtrips(
      mssql_db, "contract_mssql",
      setup: ["CREATE TABLE contract_mssql (id INTEGER IDENTITY(1,1) PRIMARY KEY, name VARCHAR(100), score INTEGER)"],
      drop: ["DROP TABLE contract_mssql"],
    )
  end

  it "seed_table_inserts_on_every_engine (firebird)" do
    skip "TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)" if SDRC_FIREBIRD_URL.nil? || SDRC_FIREBIRD_URL.empty?
    # Firebird has no AUTOINCREMENT - the real idiom is a generator + a BEFORE
    # INSERT trigger, so `id` is assigned without seed_table needing to know it.
    assert_seed_table_roundtrips(
      firebird_db, "contract_fb",
      setup: [
        "CREATE TABLE contract_fb (id INTEGER NOT NULL PRIMARY KEY, name VARCHAR(100), score INTEGER)",
        "CREATE GENERATOR gen_contract_fb_id",
        "CREATE TRIGGER contract_fb_bi FOR contract_fb ACTIVE BEFORE INSERT POSITION 0 " \
        "AS BEGIN IF (NEW.id IS NULL) THEN NEW.id = GEN_ID(gen_contract_fb_id, 1); END",
      ],
      drop: ["DROP TRIGGER contract_fb_bi", "DROP TABLE contract_fb", "DROP GENERATOR gen_contract_fb_id"],
    )
  end

  # ── seeded_run_reproduces_identical_rows ────────────────────────────────
  # seed_orm/seed_models: their OWN seed: is deterministic (unchanged).
  # seed_table: seed: is REMOVED - the documented replacement is a
  # caller-seeded FakeData closed over in `columns`, proven here.

  it "seeded_run_reproduces_identical_rows (seed_orm)" do
    run = lambda do |path|
      db = Tina4::Database.new("sqlite:///" + path)
      Tina4.bind_database(db)
      db.execute(
        "CREATE TABLE seedercontract_person (id INTEGER PRIMARY KEY AUTOINCREMENT, " \
        "name TEXT, email TEXT, age INTEGER)"
      )
      Tina4.seed_orm(SeederContractPerson, count: 6, seed: 4242)
      rows = db.fetch("SELECT name, email, age FROM seedercontract_person ORDER BY id", [], limit: 1000).to_a
      db.close
      rows
    end

    Dir.mktmpdir("tina4_seedorm_repro") do |dir|
      a = run.call(File.join(dir, "a.db"))
      b = run.call(File.join(dir, "b.db"))
      expect(a).to eq(b)
      expect(a.length).to eq(6)
    end
  end

  it "seeded_run_reproduces_identical_rows (seed_table)" do
    # Replacement pattern for the removed seed_table(seed:): the caller
    # builds its OWN seeded FakeData and closes over it in columns.
    run = lambda do |path|
      db = Tina4::Database.new("sqlite:///" + path)
      Tina4.bind_database(db)
      db.execute(
        "CREATE TABLE contract_seedtable_raw (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, score INTEGER)"
      )
      fake = Tina4::FakeData.new(seed: 777)
      Tina4.seed_table("contract_seedtable_raw", {
        "name" => -> { fake.name },
        "score" => -> { fake.integer(min: 1, max: 1000) },
      }, count: 6)
      rows = db.fetch("SELECT name, score FROM contract_seedtable_raw ORDER BY id", [], limit: 1000).to_a
      db.close
      rows
    end

    Dir.mktmpdir("tina4_seedtable_repro") do |dir|
      a = run.call(File.join(dir, "a.db"))
      b = run.call(File.join(dir, "b.db"))
      expect(a).to eq(b)
      expect(a.length).to eq(6)
    end
  end

  it "seeded_run_reproduces_identical_rows (seed_table seed: keyword raises)" do
    # SEED-TABLE-SEED-INERT fix, mutation witness: seed_table no longer HAS a
    # seed: keyword - passing one raises Ruby's own ArgumentError instead of
    # silently doing nothing.
    Dir.mktmpdir("tina4_seedtable_raises") do |dir|
      db = Tina4::Database.new("sqlite:///" + File.join(dir, "raises.db"))
      Tina4.bind_database(db)
      db.execute("CREATE TABLE contract_seedtable_raises (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      expect do
        Tina4.seed_table("contract_seedtable_raises", { "name" => -> { "x" } }, count: 1, seed: 99)
      end.to raise_error(ArgumentError, /seed/)
      db.close
    end
  end

  it "seeded_run_reproduces_identical_rows (postgresql)" do
    skip "no reachable postgres at #{SDRC_PG_HOST}:#{SDRC_PG_PORT} (set TINA4_TEST_PG_*)" unless SDRC_PG_REACHABLE

    run = lambda do |table|
      db = pg_db
      drop_all(db, "DROP TABLE #{table}")
      db.execute("CREATE TABLE #{table} (id SERIAL PRIMARY KEY, name VARCHAR(100), score INTEGER)")
      fake = Tina4::FakeData.new(seed: 555)
      Tina4.bind_database(db)
      Tina4.seed_table(table, {
        "name" => -> { fake.name },
        "score" => -> { fake.integer(min: 1, max: 100) },
      }, count: 5)
      rows = db.fetch("SELECT name, score FROM #{table} ORDER BY id", [], limit: 100).to_a
      drop_all(db, "DROP TABLE #{table}")
      db.close
      rows
    end

    a = run.call("contract_repro_pg_a")
    b = run.call("contract_repro_pg_b")
    expect(a).to eq(b)
    expect(a.length).to eq(5)
  end

  # ── seed_models_orders_parents_before_children ──────────────────────────

  it "seed_models_orders_parents_before_children (sqlite)" do
    Dir.mktmpdir("tina4_seedmodels_contract") do |dir|
      db = Tina4::Database.new("sqlite:///" + File.join(dir, "fk.db"))
      Tina4.bind_database(db)
      db.execute("CREATE TABLE seedercontract_author (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      db.execute(
        "CREATE TABLE seedercontract_book (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, " \
        "author_id INTEGER NOT NULL REFERENCES seedercontract_author(id))"
      )

      # Children declared BEFORE parents on purpose - topo-sort must fix it.
      results = Tina4.seed_models([SeederContractBook, SeederContractAuthor], count: 5, seed: 3)

      expect(results["SeederContractAuthor"].seeded).to eq(5)
      expect(results["SeederContractAuthor"].failed).to eq(0)
      expect(results["SeederContractBook"].seeded).to eq(5)
      expect(results["SeederContractBook"].failed).to eq(0)

      orphans = db.fetch(
        "SELECT * FROM seedercontract_book b LEFT JOIN seedercontract_author a ON b.author_id = a.id " \
        "WHERE a.id IS NULL", [], limit: 100
      ).to_a
      expect(orphans).to be_empty
      db.close
    end
  end

  it "seed_models_orders_parents_before_children (postgresql)" do
    skip "no reachable postgres at #{SDRC_PG_HOST}:#{SDRC_PG_PORT} (set TINA4_TEST_PG_*)" unless SDRC_PG_REACHABLE

    db = pg_db
    Tina4.bind_database(db)
    drop_all(db, "DROP TABLE seedercontract_book", "DROP TABLE seedercontract_author")
    db.execute("CREATE TABLE seedercontract_author (id SERIAL PRIMARY KEY, name VARCHAR(100))")
    db.execute(
      "CREATE TABLE seedercontract_book (id SERIAL PRIMARY KEY, title VARCHAR(100), " \
      "author_id INTEGER NOT NULL REFERENCES seedercontract_author(id))"
    )

    begin
      results = Tina4.seed_models([SeederContractBook, SeederContractAuthor], count: 5, seed: 9)

      expect(results["SeederContractAuthor"].seeded).to eq(5)
      expect(results["SeederContractAuthor"].failed).to eq(0)
      expect(results["SeederContractBook"].seeded).to eq(5)
      expect(results["SeederContractBook"].failed).to eq(0)

      orphans = db.fetch(
        "SELECT * FROM seedercontract_book b LEFT JOIN seedercontract_author a ON b.author_id = a.id " \
        "WHERE a.id IS NULL", [], limit: 100
      ).to_a
      expect(orphans).to be_empty
    ensure
      drop_all(db, "DROP TABLE seedercontract_book", "DROP TABLE seedercontract_author")
      db.close
    end
  end

  # ── failures_are_counted_not_silent ──────────────────────────────────────

  it "failures_are_counted_not_silent (sqlite)" do
    Dir.mktmpdir("tina4_fail_contract") do |dir|
      db = Tina4::Database.new("sqlite:///" + File.join(dir, "fail.db"))
      Tina4.bind_database(db)
      db.execute("CREATE TABLE contract_fail (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT NOT NULL)")

      # email is NOT NULL but every generated value is nil -> every INSERT
      # violates the constraint - never silent, never a crash.
      summary = Tina4.seed_table("contract_fail", {
        "name" => -> { "someone" },
        "email" => -> { nil },
      }, count: 4)

      expect(summary.seeded).to eq(0)
      expect(summary.failed).to eq(4)
      expect(summary.errors.length).to eq(4)
      expect(db.fetch_one("SELECT count(*) as cnt FROM contract_fail")[:cnt]).to eq(0)
      db.close
    end
  end

  it "failures_are_counted_not_silent (strict re-raises)" do
    Dir.mktmpdir("tina4_fail_strict_contract") do |dir|
      db = Tina4::Database.new("sqlite:///" + File.join(dir, "fail_strict.db"))
      Tina4.bind_database(db)
      db.execute("CREATE TABLE contract_fail_strict (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL)")

      expect do
        Tina4.seed_table("contract_fail_strict", { "email" => -> { nil } }, count: 3, strict: true)
      end.to raise_error(StandardError)
      db.close
    end
  end

  it "failures_are_counted_not_silent (postgresql)" do
    skip "no reachable postgres at #{SDRC_PG_HOST}:#{SDRC_PG_PORT} (set TINA4_TEST_PG_*)" unless SDRC_PG_REACHABLE

    db = pg_db
    Tina4.bind_database(db)
    table = "contract_fail_pg"
    drop_all(db, "DROP TABLE #{table}")
    db.execute("CREATE TABLE #{table} (id SERIAL PRIMARY KEY, email VARCHAR(100) NOT NULL)")

    begin
      summary = Tina4.seed_table(table, { "email" => -> { nil } }, count: 4)
      expect(summary.seeded).to eq(0)
      expect(summary.failed).to eq(4)
      expect(db.fetch_one("SELECT count(*) as cnt FROM #{table}")[:cnt]).to eq(0)
    ensure
      drop_all(db, "DROP TABLE #{table}")
      db.close
    end
  end

  # ── generator_vocabulary_present ──────────────────────────────────────────
  # SEED-VOCAB-PARITY: this exact generator set (idiomatic spelling per
  # language) exists in all four - Python/PHP/Ruby/Node.

  it "generator_vocabulary_present" do
    fake = Tina4::FakeData.new(seed: 1)
    SDRC_GENERATOR_VOCABULARY.each do |generator_name|
      expect(fake.respond_to?(generator_name)).to be(true), "FakeData missing generator: #{generator_name}"
    end

    expect(fake.name).to be_a(String).and satisfy { |v| !v.empty? }
    expect(fake.first_name).to be_a(String).and satisfy { |v| !v.empty? }
    expect(fake.last_name).to be_a(String).and satisfy { |v| !v.empty? }
    expect(fake.email).to include("@")
    expect(fake.phone).not_to be_empty
    expect(fake.address).not_to be_empty
    expect(fake.city).not_to be_empty
    expect(fake.country).not_to be_empty
    expect(fake.zip_code).not_to be_empty
    expect(fake.company).not_to be_empty
    expect(fake.job_title).not_to be_empty
    expect(fake.sentence).not_to be_empty
    expect(fake.paragraph).not_to be_empty
    expect(fake.text).not_to be_empty
    expect(fake.word).not_to be_empty
    expect(fake.integer(min: 1, max: 10)).to be_a(Integer)
    expect(fake.numeric(min: 0.0, max: 10.0)).to be_a(Float)
    expect([true, false]).to include(fake.boolean)
    expect(fake.date).not_to be_empty
    expect(fake.datetime).to be_a(Time)
    expect(fake.uuid).not_to be_empty
    expect(fake.url).to start_with("https://")
    expect(fake.color_hex).to start_with("#")
    expect(fake.currency.length).to eq(3)
    expect(fake.ip_address.count(".")).to eq(3)
    expect(fake.credit_card).not_to be_empty
    expect([1, 2, 3]).to include(fake.choice([1, 2, 3]))
    expect(fake.for_field({ type: :string })).not_to be_nil
  end
end
