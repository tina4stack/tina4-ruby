# frozen_string_literal: true

require "json"
require "tina4"

# The batch-write contract (feature 3 of the feature audit).
#
# spec/fixtures/batch_write_contract.json is byte-identical in all four
# frameworks and is the shared answer key: the same cases, the same engine
# parameter caps, the same rejections, checked identically in python, php, ruby
# and node.
#
# A batch that loops one INSERT per row pays a full network round-trip per row.
# Measured over 500 rows on the .99 host: PostgreSQL 9848ms row-at-a-time
# against 15.8ms as one multi-row VALUES (625x), MySQL 216x, MSSQL 121x.
#
# The chunking rules are PURE, so they are checked here without a database. The
# live-engine half of the contract lives in the write-path runner, which proves
# the rows actually land - a faster batch that writes the wrong rows is a bug,
# not an optimisation.
RSpec.describe Tina4::SQLTranslator, ".build_batch_inserts" do
  # Locals, not constants: a constant here leaks into every other spec file.
  fixture_path = File.join(__dir__, "fixtures", "batch_write_contract.json")
  contract = JSON.parse(File.read(fixture_path))

  def rows_for(count, columns)
    Array.new(count) { |r| Array.new(columns) { |c| "v#{r}c#{c}" } }
  end

  contract["cases"].each do |kase|
    it "#{kase['name']} (shared fixture)" do
      statements = described_class.build_batch_inserts(
        kase["sql"], rows_for(kase["rows"], kase["columns"]), kase["engine"]
      )

      expect(statements.length).to eq(kase["expect"]["statements"]),
                                   "#{kase['name']}: wrong statement count"
      next if kase["expect"]["statements"].zero?

      first_sql, first_params = statements[0]
      expect(first_sql.count("(") - 1).to eq(kase["expect"]["rows_in_first"])
      expect(first_params.length).to eq(kase["expect"]["params_in_first"])
      expect(first_sql.count("?")).to eq(kase["expect"]["params_in_first"])
    end
  end

  it "matches the engine caps in the shared fixture" do
    # The caps are a real engine limit, not a tunable. MSSQL's 2100 is the
    # tightest and is what makes chunking mandatory.
    contract["max_bind_params"].each do |engine, cap|
      next if engine.start_with?("_")

      expect(Tina4::SQLTranslator::MAX_BIND_PARAMS[engine]).to eq(cap),
                                                               "#{engine} cap drifted from the shared fixture"
    end
  end

  it "never emits a chunk exceeding the engine cap, at any column width" do
    # Exceeding the cap is a hard error on a real engine, so this is checked
    # exhaustively rather than at the two boundaries the fixture names.
    Tina4::SQLTranslator::MAX_BIND_PARAMS.each do |engine, cap|
      next if cap <= 0

      (1..11).each do |columns|
        cols = Array.new(columns) { |i| "c#{i}" }.join(", ")
        marks = Array.new(columns, "?").join(", ")
        sql = "INSERT INTO t (#{cols}) VALUES (#{marks})"
        described_class.build_batch_inserts(sql, rows_for(1500, columns), engine).each do |_s, params|
          expect(params.length).to be <= cap,
                                   "#{engine}/#{columns}col chunk had #{params.length} params, cap #{cap}"
        end
      end
    end
  end

  it "preserves every row and value, in order, across chunk boundaries" do
    rows = rows_for(701, 3)
    statements = described_class.build_batch_inserts(
      "INSERT INTO t (a, b, c) VALUES (?, ?, ?)", rows, "mssql"
    )
    expect(statements.length).to be > 1, "this case is only meaningful when it chunks"
    expect(statements.flat_map { |_s, params| params }).to eq(rows.flatten(1))
  end

  # --- negative cases ------------------------------------------------------
  # Returning empty means "keep looping", which is always correct. Collapsing
  # one of these would silently change what the batch writes.

  {
    "RETURNING" => ["INSERT INTO t (a) VALUES (?) RETURNING *", 1, 10],
    "ON CONFLICT" => ["INSERT INTO t (a) VALUES (?) ON CONFLICT (a) DO NOTHING", 1, 10],
    "ON DUPLICATE KEY" => ["INSERT INTO t (a) VALUES (?) ON DUPLICATE KEY UPDATE a = a", 1, 10],
    "not_an_insert" => ["UPDATE t SET a = ? WHERE b = ?", 2, 10],
    "literal_in_values" => ["INSERT INTO t (a, b) VALUES (?, now())", 1, 10],
    "single_row" => ["INSERT INTO t (a) VALUES (?)", 1, 1]
  }.each do |reason, (sql, columns, count)|
    it "negative: #{reason} never collapses" do
      expect(described_class.build_batch_inserts(sql, rows_for(count, columns), "postgres")).to eq([])
    end
  end

  it "negative: ragged parameter sets never collapse" do
    expect(
      described_class.build_batch_inserts("INSERT INTO t (a, b) VALUES (?, ?)", [%w[a b], ["c"]], "postgres")
    ).to eq([])
  end

  it "negative: a batch is never collapsed on Firebird, ODBC or MongoDB" do
    # Firebird has no multi-row VALUES syntax. Collapsing there emits SQL the
    # engine cannot parse, trading a working slow path for a broken fast one.
    %w[firebird odbc mongodb].each do |engine|
      expect(
        described_class.build_batch_inserts("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", rows_for(100, 3), engine)
      ).to eq([]), "#{engine} must keep the row-at-a-time loop"
    end
  end

  it "negative: an unknown engine falls back rather than guessing a cap" do
    expect(
      described_class.build_batch_inserts("INSERT INTO t (a) VALUES (?)", rows_for(10, 1), "some_new_engine")
    ).to eq([])
  end

  contract["engine_aliases"].each do |alias_name, canonical|
    next if alias_name.start_with?("_")

    it "resolves the engine alias #{alias_name} to #{canonical}" do
      # The drift that made this optimisation a no-op on PostgreSQL: Python and
      # PHP report "postgresql" while Ruby and Node report "postgres". Reading
      # the cap table without normalising misses, the cap comes back 0, and the
      # batch silently keeps looping - on the engine with the largest measured
      # win. A live run caught it; this pins it.
      expect(Tina4::SQLTranslator::ENGINE_ALIASES[alias_name]).to eq(canonical)

      sql = "INSERT INTO t (a, b, c) VALUES (?, ?, ?)"
      rows = rows_for(10, 3)
      expect(described_class.build_batch_inserts(sql, rows, alias_name))
        .to eq(described_class.build_batch_inserts(sql, rows, canonical))
    end
  end

  # Regression: collapsing a batch silently changed last_id on MySQL.
  #
  # MySQL's last_insert_id reports the FIRST generated id of a multi-row INSERT,
  # not the last (verified live: a 3-row insert into a fresh table reports 1
  # while MAX(id) is 3). A row-at-a-time batch reported the LAST row's id simply
  # because the last statement inserted the last row, so the collapse quietly
  # redefined the contract.
  it "still reports the LAST row's id on mysql after a collapse" do
    expect(described_class.batch_last_id(1, 3, "mysql")).to eq(3)
    expect(described_class.batch_last_id(10, 5, "mariadb")).to eq(14)
  end

  it "negative: leaves engines that already report the last id alone" do
    # Adding the offset on SQLite/PostgreSQL/MSSQL would push last_id PAST the
    # real row.
    %w[sqlite postgres postgresql mssql].each do |engine|
      expect(described_class.batch_last_id(7, 3, engine)).to eq(7), engine
    end
  end

  it "negative: never shifts the id for a single-row chunk" do
    %w[mysql sqlite postgres mssql].each do |engine|
      expect(described_class.batch_last_id(42, 1, engine)).to eq(42), engine
    end
  end

  it "negative: passes a non-numeric last id through unchanged" do
    # A UUID/ULID primary key has no arithmetic successor.
    expect(described_class.batch_last_id("018f-2b7c-uuid", 3, "mysql")).to eq("018f-2b7c-uuid")
    expect(described_class.batch_last_id(nil, 3, "mysql")).to be_nil
  end

  it "collapses when the engine is spelled postgresql in full" do
    # Ruby's own driver reports "postgres", but a caller may pass either and the
    # other three frameworks report "postgresql" - the shared rule must hold for
    # both spellings or the fixture is not really shared.
    statements = described_class.build_batch_inserts(
      "INSERT INTO t (a, b, c) VALUES (?, ?, ?)", rows_for(50, 3), "postgresql"
    )
    expect(statements.length).to eq(1)
    expect(statements[0][1].length).to eq(150)
  end
end
