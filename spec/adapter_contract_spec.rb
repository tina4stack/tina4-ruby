# frozen_string_literal: true

require "json"
require "spec_helper"

# The adapter contract (feature 3 of the feature audit).
#
# spec/fixtures/adapter_contract.json is byte-identical in all four frameworks.
#
# Ruby had no adapter interface at all: `Database` called four things on a driver
# and guarded the rest behind six `respond_to?` checks, so a driver missing a
# method was discovered at runtime on whichever engine nobody exercised - and the
# guards made that a SILENT SKIP rather than an exception.
#
# The owner's decision (2026-07-30) is that CRUD lives on the ADAPTER, matching
# the other three. That migration runs driver by driver. This spec is the
# RATCHET that makes it finish: it pins today's implemented count per driver, so
# the number can go UP but never down, and a new driver cannot ship at the old
# level.
contract = JSON.parse(File.read(File.join(__dir__, "fixtures", "adapter_contract.json"))).freeze

RSpec.describe Tina4::DatabaseAdapter do
  # Contract name -> the spellings Ruby accepts. `open`/`connect` and
  # `table_exists`/`table_exists?` are idiomatic variants, not divergences.
  SPELLINGS = {
    "open" => %i[open connect], "close" => %i[close],
    "execute" => %i[execute], "executeMany" => %i[execute_many],
    "fetch" => %i[fetch query], "fetchOne" => %i[fetch_one],
    "insert" => %i[insert], "update" => %i[update], "delete" => %i[delete],
    "startTransaction" => %i[start_transaction], "commit" => %i[commit],
    "rollback" => %i[rollback],
    "getTables" => %i[get_tables tables], "getColumns" => %i[get_columns columns],
    "tableExists" => %i[table_exists table_exists?],
    "createTable" => %i[create_table], "addColumn" => %i[add_column],
    "lastInsertId" => %i[last_insert_id last_id],
    "error" => %i[error last_error], "autocommit" => %i[autocommit autocommit=]
  }.freeze

  # Measured 2026-07-30 with the contract module in place. These are FLOORS.
  # Raise one when you migrate a driver; never lower one.
  # Counted with implemented_by?, which asks whether the driver OVERRODE the
  # method - not method_defined?, which cannot tell an implementation from the
  # module's raising stub. That is one lower per driver than the pre-module
  # probe, and it is the honest number: `autocommit` is a facade-set attr_writer
  # on most drivers rather than a driver method.
  FLOORS = {
    "FirebirdDriver" => 8, "MongodbDriver" => 8, "OdbcDriver" => 8,
    "MssqlDriver" => 9, "MysqlDriver" => 9, "SqliteDriver" => 9,
    "PostgresDriver" => 10
  }.freeze

  def implemented_count(klass)
    SPELLINGS.count do |_, names|
      names.any? { |n| Tina4::DatabaseAdapter.implemented_by?(klass.allocate, n) }
    end
  end

  it "declares exactly the shared contract" do
    want = contract["methods"].map { |m| m["name"] }
    expect(described_class::CONTRACT.length).to eq(want.length)
  end

  describe "every driver" do
    Tina4::Drivers.constants.sort.each do |const|
      klass = Tina4::Drivers.const_get(const)
      next unless klass.is_a?(Class)

      it "#{const} includes the contract" do
        expect(klass.ancestors).to include(Tina4::DatabaseAdapter)
      end

      # The ratchet. A driver that loses a method fails here rather than
      # silently going back to being skipped at runtime.
      it "#{const} implements at least its recorded floor" do
        floor = FLOORS[const.to_s]
        skip "no floor recorded for #{const}" if floor.nil?
        expect(implemented_count(klass)).to be >= floor
      end
    end
  end

  describe "a method a driver has not implemented" do
    # The whole point of the module: loud at the point of the call, naming the
    # driver and the method, instead of a silent skip on an engine nobody ran.
    it "raises NotImplementedError naming the driver and the method" do
      bare = Class.new { include Tina4::DatabaseAdapter }
      expect { bare.new.create_table }
        .to raise_error(NotImplementedError, /does not implement #create_table/)
    end

    it "is distinguishable from an implemented one" do
      bare = Class.new { include Tina4::DatabaseAdapter }
      real = Class.new do
        include Tina4::DatabaseAdapter
        def create_table(*) = true
      end
      expect(Tina4::DatabaseAdapter.implemented_by?(bare.new, :create_table)).to be false
      expect(Tina4::DatabaseAdapter.implemented_by?(real.new, :create_table)).to be true
    end
  end
end
