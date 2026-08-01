# frozen_string_literal: true

# The RAW-FETCH row-cap contract: db.fetch() caps at 100 by default, and an
# explicit limit: overrides that default IN BOTH DIRECTIONS.
#
# == Why this file exists at all
#
# This test already existed in tina4-php - and NEVER RAN. It was written as a
# SECOND PHPUnit TestCase class inside tests/DevAdminTest.php, and PHPUnit only
# instantiates the class whose name matches the file. So the row-cap contract
# had a test, a green suite, and zero executions, for its entire life. When it
# was finally lifted into a file of its own and executed, it FAILED: it asserted
# a default cap of 10, a number that came from the V2 documentation and survived
# into v3 in two separate places. A buried test does not merely fail to catch a
# regression - it actively hides one, because "there is a test for that" reads
# as coverage in every review after it.
#
# So: one number, everywhere, 100 - and the test lives in a file named after
# what it tests, discovered by the default runner, with no way to bury it.
#
# == Why the fixture holds 150 rows and not 30
#
# The buried PHP version also seeded 30 rows and asserted 30 came back. That
# assertion is satisfied by a cap of 100, by a cap of 1000, and by NO CAP AT
# ALL - three completely different behaviours, one green test. A fixture
# SMALLER than the cap cannot observe the cap. The fixture here is 150, larger
# than the 100 it is measuring, so "capped at 100" and "uncapped" produce
# different numbers and the test can tell them apart. The before(:each) asserts
# the fixture size itself, so a truncated fixture fails as a fixture bug rather
# than passing as a contract.
#
# == The three properties, and why each is load-bearing
#
#   1. No limit argument -> 100 rows. The default, the thing that got the
#      wrong number.
#   2. An explicit limit overrides the default IN BOTH DIRECTIONS: limit 25
#      yields 25, and limit 120 yields 120 even though 120 > 100. Direction
#      matters: a hardcoded `LIMIT 100` passes (1) and passes (25 -> 25 is not
#      even needed if you clamp), and only the 120 case can distinguish a
#      DEFAULT from a CEILING. Without the upward case, `min(limit, 100)`
#      shipped as "the cap works".
#   3. SQL that already carries its own LIMIT must NOT get a second one
#      appended. Ruby's Database#fetch appends "LIMIT n OFFSET m" as text, so
#      appending it to SQL that already ends in LIMIT produces
#      "... LIMIT 7 LIMIT 100 OFFSET 0" - a syntax error on every engine. The
#      row count coming back proves both that no second clause was appended and
#      that the caller's own LIMIT is the one that won.
#
# == Where Ruby differs from PHP, measured rather than assumed
#
# In Ruby the cap is applied at the WRAPPER only (Database#fetch). The SQLite
# driver has no fetch of its own: `fetch` is one of Tina4::DatabaseAdapter's
# CONTRACT stubs, and SqliteDriver never overrides it, so a driver-level read
# raises NotImplementedError. PHP caps in BOTH its wrapper and its adapter. The
# last examples below pin what Ruby ACTUALLY does at the driver level rather
# than pretending it matches PHP - if SqliteDriver ever grows a real #fetch,
# that example goes red and the cap question has to be answered for it too.
#
# One measured DEFECT is pinned the same way: the "does this SQL already have
# its own LIMIT" test is a plain substring match, so a query over a column
# NAMED limit_amount / rate_limit is mistaken for an already-limited statement
# and gets no cap at all - an unbounded read, which is the exact incident the
# cap exists to prevent, reachable through an innocuous column name.
#
# Two more measured divergences are pinned as CHARACTERISATION (a record of
# what is, not a demand): on a capped fetch Ruby's DatabaseResult reports
# `count` = 100 (rows returned, NOT the 150 matching), and `limit` = 10 on
# every fetch regardless of the limit applied - the untouched `limit: 10`
# default in DatabaseResult#initialize, because Database#fetch_direct never
# passes limit:/offset:/count:. That 10 is the same stale number out of the v2
# docs that the buried PHP test asserted as the cap, still sitting one field
# away from the read path it fails to describe.
#
# No mocks: a real SQLite file in a temp dir, real rows, real counts.

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "raw fetch row-cap contract" do
  # Locals, not constants: a constant declared in an RSpec block lands on
  # Object and leaks into every other spec file in the suite.
  rows       = 150 # MUST exceed the cap - see the header
  cap        = 100
  smaller    = 25  # an explicit limit BELOW the default
  bigger     = 120 # an explicit limit ABOVE the default - the direction that matters
  table      = "row_cap_rows"

  before(:each) do
    @tmp_dir = Dir.mktmpdir("tina4_row_cap_contract")
    @db = Tina4::Database.new("sqlite:///#{File.join(@tmp_dir, 'row_cap.db')}")
    @db.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)")
    rows.times { |i| @db.execute("INSERT INTO #{table} (label) VALUES (?)", ["row#{i}"]) }
    @db.commit

    # The fixture is the instrument. If it is not bigger than the cap, every
    # assertion below would pass for the wrong reason, so check it first and
    # fail as a FIXTURE bug rather than reporting a false green contract.
    expect(@db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")[:c]).to eq(rows)
    expect(rows).to be > cap
  end

  after(:each) do
    begin
      @db&.close
    rescue StandardError
      nil # teardown must never mask a failure
    end
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.directory?(@tmp_dir)
  end

  describe "the default" do
    it "caps a raw fetch with NO limit argument at 100 rows" do
      # THE number. It was 10 in the v2 docs and in two v3 places; the buried
      # PHP test asserted 10 and never ran to say so.
      expect(@db.fetch("SELECT * FROM #{table}").records.length).to eq(cap)
    end

    it "appends exactly ONE limit clause to the executed SQL" do
      # The cap is text appended to the statement, so look at the statement.
      # This is the direct form of the property the row counts prove
      # indirectly, and it names the number in the failure message.
      expect(@db.fetch("SELECT * FROM #{table}").sql)
        .to eq("SELECT * FROM #{table} LIMIT #{cap} OFFSET 0")
    end
  end

  describe "an explicit limit overrides the default in BOTH directions" do
    it "honours a limit SMALLER than the cap (25 -> 25)" do
      expect(@db.fetch("SELECT * FROM #{table}", [], limit: smaller).records.length).to eq(smaller)
    end

    it "honours a limit LARGER than the cap (120 -> 120, not 100)" do
      # The half that a hardcoded LIMIT 100 - or a min(limit, 100) clamp -
      # cannot satisfy. 100 is a DEFAULT, not a ceiling.
      expect(@db.fetch("SELECT * FROM #{table}", [], limit: bigger).records.length).to eq(bigger)
    end

    it "reaches every row when the explicit limit covers the table" do
      expect(@db.fetch("SELECT * FROM #{table}", [], limit: rows).records.length).to eq(rows)
    end
  end

  describe "SQL that already carries its own LIMIT" do
    it "is not given a second LIMIT (the caller's own wins)" do
      # A second appended clause yields "... LIMIT 7 LIMIT 100 OFFSET 0", which
      # is a syntax error on every engine - so 7 rows coming back proves both
      # that nothing was appended and that the caller's LIMIT is in force.
      expect(@db.fetch("SELECT * FROM #{table} LIMIT 7").records.length).to eq(7)
    end

    it "is not given a second LIMIT even when limit: is passed explicitly" do
      expect(@db.fetch("SELECT * FROM #{table} LIMIT 7", [], limit: smaller).records.length).to eq(7)
    end

    it "detects the caller's LIMIT case-insensitively" do
      # The detector upcases before matching; lowercase SQL is the common form
      # and must not slip through into a double-LIMIT syntax error.
      expect(@db.fetch("select * from #{table} limit 7").records.length).to eq(7)
    end

    it "keeps working when the SQL ends in a semicolon" do
      # fetch strips trailing semicolons before appending, else the appended
      # clause lands AFTER the statement terminator.
      expect(@db.fetch("SELECT * FROM #{table};").records.length).to eq(cap)
    end

    it "leaves the executed SQL with exactly one LIMIT in it" do
      # The row count above proves it too, but only because a double LIMIT
      # happens to be a syntax error on SQLite. Counting the clauses in the
      # executed statement is the property itself, on any engine.
      executed = @db.fetch("SELECT * FROM #{table} LIMIT 7", [], limit: smaller).sql
      expect(executed.upcase.scan("LIMIT").length).to eq(1)
      expect(executed).to eq("SELECT * FROM #{table} LIMIT 7")
    end
  end

  describe "where the cap lives in THIS framework (measured, not assumed)" do
    it "reports result metadata that does NOT describe the cap (characterisation)" do
      # A RECORD of measured behaviour, not a requirement - and two findings.
      #
      # 1. `count` is the number of rows RETURNED, not the number of rows
      #    MATCHING. It reads 100 here, not 150. The comment in the
      #    neighbouring spec/orm_row_cap_spec.rb asserts in prose that count
      #    "stays 150 regardless of truncation" - that prose is wrong, and it
      #    was never executed as an assertion, which is how it stayed wrong.
      #    Anything paginating on `count` under a default fetch sees 100 of
      #    100 and cannot tell that 50 rows were truncated.
      #
      # 2. `limit` reads 10 - on EVERY fetch, whatever limit was applied. It
      #    is the untouched default in DatabaseResult#initialize
      #    (`limit: 10`), because Database#fetch_direct never passes limit:,
      #    offset: or count: when it builds the result. That is the SAME
      #    stale 10 out of the v2 docs that the buried PHP test asserted as
      #    the cap - still resident in this framework, one field away from
      #    the read path it fails to describe.
      #
      # If either number changes, the metadata got wired up: update this
      # example, it is describing reality rather than demanding it.
      result = @db.fetch("SELECT * FROM #{table}")
      expect(result.records.length).to eq(cap)
      expect(result.count).to eq(cap)
      expect(result.limit).to eq(10)
      expect(result.offset).to eq(0)
    end

    it "DEFECT: a column whose NAME contains 'limit' defeats the cap entirely" do
      # MEASURED, and a real bug - recorded here so it cannot be lost again.
      #
      # The "already has its own LIMIT" detector is a naive substring test:
      #   has_limit = sql.upcase.split("--")[0].include?("LIMIT")
      # (lib/tina4/database.rb, Database#fetch). It cannot tell a LIMIT CLAUSE
      # from the letters l-i-m-i-t inside an identifier, so any query touching
      # a column called limit_amount / rate_limit / limit_type is treated as
      # already limited and NO cap is appended at all. The read comes back
      # completely unbounded - which is the precise incident the cap exists to
      # prevent, reachable through an innocuous column name.
      #
      # This example pins the CURRENT behaviour, it does not bless it. When the
      # detector learns to parse a real trailing LIMIT clause, this goes red:
      # change the expectation to `cap` at that point, do not delete it.
      @db.execute("CREATE TABLE limit_named (id INTEGER PRIMARY KEY AUTOINCREMENT, limit_amount INTEGER)")
      rows.times { |i| @db.execute("INSERT INTO limit_named (limit_amount) VALUES (?)", [i]) }
      @db.commit

      result = @db.fetch("SELECT id, limit_amount FROM limit_named")
      expect(result.sql).to eq("SELECT id, limit_amount FROM limit_named") # no LIMIT appended
      expect(result.records.length).to eq(rows) # 150 - uncapped, not 100
    end

    it "applies the cap at the wrapper - the SQLite driver has no fetch of its own" do
      # Ruby's divergence from PHP, pinned rather than papered over. PHP caps in
      # its wrapper AND its adapter; here `fetch` is an unoverridden
      # Tina4::DatabaseAdapter CONTRACT stub on SqliteDriver, so there is no
      # driver-level read to cap. If this ever stops raising, a real driver
      # fetch exists and its cap behaviour needs its own assertion.
      driver = @db.current_driver
      expect(Tina4::DatabaseAdapter.implemented_by?(driver, :fetch)).to be(false)
      expect { driver.fetch("SELECT * FROM #{table}") }.to raise_error(NotImplementedError)
    end
  end
end
