# frozen_string_literal: true

# The write-path contract (feature 3/4 of the feature audit).
#
# spec/fixtures/write_path_contract.json is byte-identical in all four
# frameworks and is the shared answer key: the same cases, the same seeds, the
# same expectations, executed identically in python, php, ruby and node.
#
# The bug these lock in: db.update(table, data) with no explicit filter used to
# build "UPDATE table SET ..." with NO WHERE clause, so it overwrote EVERY row
# and reported success. A write with no filter is now an error.
#
# The fixture used to be ORPHANED - nothing read it, and the four runners were
# hand-written independently. They drifted to 17/16/15/14 cases with different
# names, and the case "a_string_filter_with_params_works_the_same_as_a_hash_filter"
# was executed by NONE of them while exactly that shape shipped broken in four
# Node adapters. Every case now runs in every framework, from this one file.
#
# RUN IT AGAINST EVERY LIVE ENGINE. SQLite alone proves nothing: the whole
# reason per-adapter write SQL exists is that placeholder style, RETURNING
# support and identifier quoting differ exactly where the engine differs.
#
#   TINA4_TEST_WRITE_PATH_URL=postgres://host:5432/db \
#   TINA4_TEST_WRITE_PATH_USERNAME=u TINA4_TEST_WRITE_PATH_PASSWORD=p \
#     bundle exec rspec spec/write_path_contract_spec.rb
#
# Unset, it falls back to a temp SQLite file so the suite still runs anywhere.
# No mocks - a database is a real dependency and CI provisions it.

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

RSpec.describe "write-path contract" do
  # Locals, not constants: a constant here leaks into every other spec file.
  contract = JSON.parse(File.read(File.join(__dir__, "fixtures", "write_path_contract.json")))
  table_name = contract["table"]["name"]
  composite_table_name = contract["composite_table"]["name"]
  all_cases = contract["cases"] + contract["errors"]

  # Every op the dispatcher below implements. A fixture case naming an op that
  # is not here fails loudly rather than being silently skipped - the orphan
  # guard.
  implemented_ops = %w[
    insert insert_batch update delete truncate primary_key
    transaction_rollback transaction_commit execute_raw
  ].freeze

  def connect
    Tina4::Database.new(@url, username: @username, password: @password)
  end

  def table_for(kase)
    kase["table"] == "composite" ? @composite_table_name : @table_name
  end

  def rows(database, table)
    database.fetch("SELECT * FROM #{table}", [], limit: 1000)
            .records.map { |record| record.to_h.transform_keys(&:to_s) }
  end

  # Engine-tolerant value comparison. Engines disagree on the Ruby type of an
  # INTEGER column; this contract is about WHICH rows a write touched, not
  # about type mapping, which the adapter contract owns.
  def same?(actual, expected)
    actual == expected || actual.to_s == expected.to_s
  end

  # Both tables empty. Raw DELETE, never truncate() - that is under test.
  def reset_tables
    [@table_name, @composite_table_name].each { |table| @db.execute("DELETE FROM #{table}") }
  end

  def seed(kase, table)
    (kase["seed"] || []).each { |row| @db.insert(table, row) }
  end

  def run_op(kase, table)
    data = kase["data"]

    case kase["op"]
    when "insert", "insert_batch"
      @db.insert(table, data)
    when "update"
      if kase.key?("filter_sql")
        @db.update(table, data.dup, kase["filter_sql"], kase["filter_params"])
      elsif kase.key?("filter")
        @db.update(table, data.dup, kase["filter"])
      else
        @db.update(table, data.dup)
      end
    when "delete"
      if kase.key?("filter_sql")
        @db.delete(table, kase["filter_sql"], kase["filter_params"])
      elsif kase.key?("filter")
        @db.delete(table, kase["filter"])
      else
        @db.delete(table)
      end
    when "truncate"
      @db.truncate(table)
    when "primary_key"
      @db.primary_key(table)
    when "transaction_rollback", "transaction_commit"
      @db.start_transaction
      @db.insert(table, data)
      kase["op"] == "transaction_commit" ? @db.commit : @db.rollback
      nil
    when "execute_raw"
      @db.execute(kase["sql"])
    else
      raise "unimplemented op #{kase['op'].inspect} in case #{kase['name'].inspect}"
    end
  end

  # Every expectation the fixture declares, checked by name.
  def check_expectations(kase, table, result)
    name = kase["name"]
    expect_block = kase["expect"] || {}

    if expect_block.key?("affected_rows")
      expect(result.affected_rows).to eq(expect_block["affected_rows"]),
                                      "#{name}: wrong affected_rows"
    end

    current_rows = if expect_block.key?("rows_after") || expect_block.key?("unchanged")
                     rows(@db, table)
                   else
                     []
                   end

    if expect_block.key?("rows_after")
      expect(current_rows.length).to eq(expect_block["rows_after"]),
                                     "#{name}: expected #{expect_block['rows_after']} row(s), got #{current_rows.inspect}"
    end

    (expect_block["unchanged"] || []).each do |matcher|
      matched = current_rows.select { |row| matcher.all? { |key, value| same?(row[key], value) } }
      expect(matched.length).to eq(1),
                                "#{name}: expected exactly one row matching #{matcher.inspect}, " \
                                "found #{matched.length} in #{current_rows.inspect}"
    end

    if expect_block.key?("primary_key")
      expect(Array(result)).to eq(expect_block["primary_key"]), "#{name}: wrong primary key"
    end

    if expect_block["last_id_is_null"]
      expect(result.last_id).to be_nil,
                                "#{name}: last_id is insert-only, but this write reported #{result.last_id.inspect}"
    end

    if expect_block.key?("last_id_is_not_stale")
      reported = result.last_id
      # nil / 0 / "" all mean "this engine cannot report one", which the
      # contract allows. A stale value is the failure being pinned.
      unless [nil, 0, ""].include?(reported)
        expect(same?(reported, expect_block["last_id_is_not_stale"])).to be(false),
                                                                        "#{name}: last_id came back as the EARLIER row's id - the adapter is " \
                                                                        "reporting a stale id rather than nil"
      end
    end

    return unless expect_block["visible_after_reconnect"]

    # A write only visible on the connection that made it is not durable, and
    # reading it back on the same handle cannot tell the difference.
    other = connect
    begin
      expect(rows(other, table).length).to eq(expect_block["rows_after"] || 1),
                                           "#{name}: the write is not visible on a second connection - it was never durable"
    ensure
      begin
        other.close
      rescue StandardError
        nil
      end
    end
  end

  before(:all) do
    @table_name = table_name
    @composite_table_name = composite_table_name

    @tmpdir = Dir.mktmpdir("tina4-writepath")
    url = ENV["TINA4_TEST_WRITE_PATH_URL"].to_s.strip
    @url = url.empty? ? "sqlite:///#{File.join(@tmpdir, 'contract.db')}" : url
    @username = ENV["TINA4_TEST_WRITE_PATH_USERNAME"].to_s
    @password = ENV["TINA4_TEST_WRITE_PATH_PASSWORD"].to_s

    @db = connect
    [@table_name, @composite_table_name].each do |table|
      @db.execute("DROP TABLE #{table}")
    rescue StandardError
      nil # first run against this engine
    end
    # The DDL lives in the shared fixture so all four frameworks create
    # literally the same table. Ids come from the case data, not a sequence -
    # an identity column would fight the explicit ids the cases name.
    @db.execute(contract["table"]["ddl"])
    @db.execute(contract["composite_table"]["ddl"])
  end

  after(:all) do
    [@table_name, @composite_table_name].each do |table|
      @db&.execute("DROP TABLE #{table}")
    rescue StandardError
      nil # teardown must never mask a failure
    end
    begin
      @db&.close
    rescue StandardError
      nil
    end
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  it "records which engine it covered" do
    # Not a gate - the record. A reader must be able to see whether this
    # contract was checked against a real engine or only against the one that
    # shares nothing with them.
    warn "\nwrite-path contract covered: #{@db.get_database_type}"
    expect(@url).not_to be_empty
  end

  it "implements every op the shared fixture uses" do
    # The orphan guard. A case naming an op the dispatcher does not implement
    # must FAIL, never be quietly skipped - silent skipping is how the fixture
    # went unread for its whole life while the runners drifted apart.
    declared = all_cases.map { |kase| kase["op"] }.uniq
    expect(declared - implemented_ops).to eq([]),
                                          "the shared fixture declares op(s) this runner cannot execute"
  end

  all_cases.each do |kase|
    it "#{kase['name']} (shared fixture)" do
      table = table_for(kase)
      reset_tables
      seed(kase, table)

      if kase["expect_raises"]
        expect { run_op(kase, table) }.to raise_error(StandardError)
        # The write must not have landed. This is the data-loss property.
        check_expectations(kase, table, nil)
        if kase["expect_error_recorded"]
          expect(@db.get_error.to_s).not_to be_empty,
                                            "#{kase['name']}: the statement raised but get_error was empty - " \
                                            "the cause has to stay readable after the raise"
        end
      else
        check_expectations(kase, table, run_op(kase, table))
      end
    end
  end
end
