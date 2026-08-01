# frozen_string_literal: true

# The row-cap DETECTOR and the row-cap APPEND SITE — two independent bugs that
# wore one coat, each pinned here with a positive AND a negative half.
#
# == What broke, measured
#
# Database#fetch caps a read at 100 rows unless the caller asked for something
# else. It skips the cap when the caller's SQL already carries its own LIMIT.
# That test used to be:
#
#     has_limit = sql.upcase.split("--")[0].include?("LIMIT")
#
# a substring search over the whole statement. MEASURED 2026-08-01 against a
# real 150-row SQLite table, fetch() with no limit argument (so the 100-row cap
# must apply). Every one of these came back with ALL 150 ROWS:
#
#     SELECT * FROM t WHERE label != 'LIMIT' ORDER BY id     -> 150 (want 100)
#     SELECT * FROM t ORDER BY id -- LIMIT 5                 -> 150 (want 100)
#     SELECT * FROM t ORDER BY id /* LIMIT 5 */              -> 150 (want 100)
#     SELECT id, label AS rate_limit FROM t                  -> 150 (want 100)
#
# A column NAMED rate_limit silently returning a whole table is the production
# incident the cap exists to prevent, reachable through an innocuous column
# name. The fix scrubs string literals, quoted identifiers and both comment
# forms from a COPY of the SQL, then matches a LIMIT clause ANCHORED TO THE END
# (tina4-php's SqlNormalizerTrait::hasTrailingLimit regex, so all four
# frameworks answer identically).
#
# The SECOND bug is at the APPEND SITE and survives a perfect detector: the
# clause was appended with a SPACE, so on
#
#     SELECT * FROM t ORDER BY id -- LIMIT 5
#
# the appended " LIMIT 100 OFFSET 0" landed INSIDE the trailing comment and the
# engine never saw it. It now goes on a NEW LINE. That is why the comment cases
# below assert the ROW COUNT and not just the detector's answer: only executing
# the statement can tell the two halves apart.
#
# == Why the negative half is load-bearing
#
# "Fixing" the detector could simply mean ALWAYS appending — every positive
# example above would pass and every caller with their own LIMIT would get
# "... LIMIT 7 LIMIT 100 OFFSET 0", a syntax error on every engine. So the
# negative half is pinned too: a REAL trailing LIMIT is still honoured (and no
# second clause is appended), and a LIMIT that appears only in a SUBQUERY still
# lets the OUTER statement be capped.
#
# No mocks: a real SQLite file in a temp dir, real rows, real counts. The pure
# detector examples call Tina4::Database.has_trailing_limit?, which is a pure
# function of its string argument — no dependency, no double.

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "row-cap detector and append site" do
  rows = 150 # MUST exceed the cap, else "capped" and "uncapped" look the same
  cap  = 100
  table = "cap_rows"

  before(:each) do
    @tmp_dir = Dir.mktmpdir("tina4_row_cap_detector")
    @db = Tina4::Database.new("sqlite:///#{File.join(@tmp_dir, 'cap.db')}")
    @db.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT, rate_limit INTEGER)")
    rows.times { |i| @db.execute("INSERT INTO #{table} (label, rate_limit) VALUES (?, ?)", ["row#{i}", i]) }
    @db.commit

    # The fixture is the instrument — fail as a fixture bug, not a false green.
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

  # ── POSITIVE HALF: the cap is applied where it used to be defeated ──────────

  describe "the cap survives text that merely CONTAINS the letters l-i-m-i-t" do
    it "caps a query whose WHERE compares against the string literal 'LIMIT'" do
      sql = "SELECT * FROM #{table} WHERE label != 'LIMIT' ORDER BY id"
      expect(@db.fetch(sql).records.length).to eq(cap)
    end

    it "caps a query with a column ALIASED rate_limit" do
      sql = "SELECT id, label AS rate_limit FROM #{table}"
      expect(@db.fetch(sql).records.length).to eq(cap)
    end

    it "caps a query SELECTing a column NAMED rate_limit" do
      # The production incident in its plainest form: an ordinary column name
      # turned a capped read into a full-table read.
      sql = "SELECT id, rate_limit FROM #{table}"
      expect(@db.fetch(sql).records.length).to eq(cap)
    end

    it "caps a query with a quoted identifier containing limit" do
      sql = %(SELECT id, rate_limit AS "my limit" FROM #{table})
      expect(@db.fetch(sql).records.length).to eq(cap)
    end
  end

  describe "the cap survives a LIMIT that lives only in a COMMENT" do
    # These two examples fail for the DETECTOR bug and, independently, for the
    # APPEND-SITE bug — appended with a space the clause lands inside the
    # comment and is swallowed. Executing the statement is what tells them
    # apart, so assert the row count, not the detector's answer.
    it "caps a query with a trailing -- LIMIT 5 line comment" do
      sql = "SELECT * FROM #{table} ORDER BY id -- LIMIT 5"
      result = @db.fetch(sql)
      expect(result.records.length).to eq(cap)
      # The appended clause must be on its OWN line, outside the comment.
      expect(result.sql.lines.last.strip).to eq("LIMIT #{cap} OFFSET 0")
    end

    it "caps a query with a /* LIMIT 5 */ block comment" do
      sql = "SELECT * FROM #{table} ORDER BY id /* LIMIT 5 */"
      expect(@db.fetch(sql).records.length).to eq(cap)
    end
  end

  describe "the cap survives a LIMIT that is only in a SUBQUERY" do
    it "caps the OUTER statement when the inner SELECT has its own LIMIT" do
      # The inner LIMIT bounds the IN-list, not the outer read: without a cap
      # the outer statement returns every matching row.
      sql = "SELECT * FROM #{table} WHERE id NOT IN " \
            "(SELECT id FROM #{table} ORDER BY id LIMIT 5) ORDER BY id"
      expect(@db.fetch(sql).records.length).to eq(cap)
    end
  end

  # ── NEGATIVE HALF: a REAL trailing LIMIT is still the caller's ──────────────

  describe "a real trailing LIMIT is still honoured (no second clause)" do
    it "returns the caller's 7 rows and appends nothing" do
      result = @db.fetch("SELECT * FROM #{table} LIMIT 7")
      expect(result.records.length).to eq(7)
      expect(result.sql).to eq("SELECT * FROM #{table} LIMIT 7")
    end

    it "honours the caller's LIMIT even when limit: is passed explicitly" do
      result = @db.fetch("SELECT * FROM #{table} LIMIT 7", [], limit: 25)
      expect(result.records.length).to eq(7)
      expect(result.sql.upcase.scan("LIMIT").length).to eq(1)
    end

    it "honours a lowercase trailing limit" do
      expect(@db.fetch("select * from #{table} limit 7").records.length).to eq(7)
    end

    it "honours LIMIT ... OFFSET ..." do
      result = @db.fetch("SELECT * FROM #{table} ORDER BY id LIMIT 7 OFFSET 3")
      expect(result.records.length).to eq(7)
      expect(result.records.first[:id]).to eq(4)
    end

    it "honours a trailing LIMIT followed by a semicolon" do
      # fetch strips trailing semicolons first, so the detector sees the LIMIT
      # at the end of the statement.
      expect(@db.fetch("SELECT * FROM #{table} LIMIT 7;").records.length).to eq(7)
    end

    it "honours a trailing LIMIT followed by a comment" do
      sql = "SELECT * FROM #{table} LIMIT 7 -- caller's own cap"
      expect(@db.fetch(sql).records.length).to eq(7)
    end
  end

  # ── The detector itself, as a pure function ────────────────────────────────

  describe "Tina4::Database.has_trailing_limit?" do
    it "is true for every real trailing LIMIT form" do
      [
        "SELECT * FROM t LIMIT 10",
        "SELECT * FROM t limit 10",
        "SELECT * FROM t LIMIT 10 OFFSET 5",
        "SELECT * FROM t LIMIT 5, 10",          # MySQL comma form
        "SELECT * FROM t LIMIT ?",              # bound placeholder
        "SELECT * FROM t LIMIT $1 OFFSET $2",   # PostgreSQL numbered
        "SELECT * FROM t LIMIT :max",           # named
        "SELECT * FROM t LIMIT %s OFFSET %s",   # Python/psycopg style
        "SELECT * FROM t LIMIT 10;",
        "SELECT * FROM t LIMIT 10 -- with a trailing comment"
      ].each do |sql|
        expect(Tina4::Database.has_trailing_limit?(sql)).to be(true), "expected a trailing LIMIT in: #{sql}"
      end
    end

    it "is false when the letters appear in a literal, an identifier or a comment" do
      [
        "SELECT * FROM t WHERE label != 'LIMIT' ORDER BY id",
        "SELECT id, label AS rate_limit FROM t",
        %(SELECT id AS "my limit" FROM t),
        "SELECT * FROM t ORDER BY id -- LIMIT 5",
        "SELECT * FROM t ORDER BY id /* LIMIT 5 */",
        "SELECT * FROM t WHERE note = 'ends with LIMIT 10'",
        "SELECT * FROM t WHERE id IN (SELECT id FROM u LIMIT 5) ORDER BY id",
        "SELECT * FROM t"
      ].each do |sql|
        expect(Tina4::Database.has_trailing_limit?(sql)).to be(false), "did NOT expect a trailing LIMIT in: #{sql}"
      end
    end

    it "handles an escaped quote inside a literal without losing the rest of the statement" do
      # A doubled '' is an escaped quote INSIDE the literal, not its end. Get
      # that wrong and everything after it is treated as quoted text, so a real
      # trailing LIMIT would be scrubbed away and a second one appended.
      expect(Tina4::Database.has_trailing_limit?("SELECT * FROM t WHERE s = 'it''s' LIMIT 10")).to be(true)
      expect(Tina4::Database.has_trailing_limit?("SELECT * FROM t WHERE s = 'it''s a LIMIT 3'")).to be(false)
    end
  end

  describe "Tina4::Database.scrub_sql_text" do
    it "blanks literals and comments while preserving length and newlines" do
      sql = "SELECT 'LIMIT' -- LIMIT 5\nFROM t /* LIMIT 9 */"
      scrubbed = Tina4::Database.scrub_sql_text(sql)
      expect(scrubbed.length).to eq(sql.length)          # offsets still line up
      expect(scrubbed.count("\n")).to eq(sql.count("\n")) # line structure kept
      expect(scrubbed).not_to include("LIMIT")
      expect(scrubbed).to include("SELECT")
      expect(scrubbed).to include("FROM t")
    end
  end

  # ── The append site, proven separately from the detector ───────────────────

  describe "the appended clause lands on its own line" do
    it "puts LIMIT on a new line so a trailing comment cannot swallow it" do
      result = @db.fetch("SELECT * FROM #{table} ORDER BY id -- trailing note")
      expect(result.sql).to eq("SELECT * FROM #{table} ORDER BY id -- trailing note\nLIMIT #{cap} OFFSET 0")
      expect(result.records.length).to eq(cap)
    end

    it "still strips a trailing semicolon before appending" do
      result = @db.fetch("SELECT * FROM #{table};")
      expect(result.sql).to eq("SELECT * FROM #{table}\nLIMIT #{cap} OFFSET 0")
      expect(result.records.length).to eq(cap)
    end
  end

  # ── What the result REPORTS about the cap it applied ───────────────────────

  describe "DatabaseResult#limit reports the limit ACTUALLY applied" do
    it "reports the default cap on a fetch with no limit argument" do
      # It reported 10 on EVERY fetch before this: fetch_direct never passed
      # limit:, so DatabaseResult's constructor default leaked through.
      result = @db.fetch("SELECT * FROM #{table}")
      expect(result.limit).to eq(cap)
      expect(result.offset).to eq(0)
    end

    it "reports an explicit limit, in both directions" do
      expect(@db.fetch("SELECT * FROM #{table}", [], limit: 25).limit).to eq(25)
      expect(@db.fetch("SELECT * FROM #{table}", [], limit: 120).limit).to eq(120)
    end

    it "reports the offset it applied" do
      result = @db.fetch("SELECT * FROM #{table} ORDER BY id", [], limit: 10, offset: 5)
      expect(result.limit).to eq(10)
      expect(result.offset).to eq(5)
      expect(result.records.first[:id]).to eq(6)
    end

    it "reports 0 when NO cap was applied — an explicit no-limit read" do
      result = @db.fetch("SELECT * FROM #{table}", [], limit: nil)
      expect(result.records.length).to eq(rows)
      expect(result.limit).to eq(0)
    end

    it "reports 0 when the caller's own trailing LIMIT is the one in force" do
      result = @db.fetch("SELECT * FROM #{table} LIMIT 7")
      expect(result.records.length).to eq(7)
      expect(result.limit).to eq(0) # the framework appended nothing
    end
  end
end
