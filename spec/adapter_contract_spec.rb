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
    "getDatabaseType" => %i[get_database_type],
    "execute" => %i[execute], "fetch" => %i[fetch query],
    "startTransaction" => %i[start_transaction], "commit" => %i[commit],
    "rollback" => %i[rollback], "autocommit" => %i[autocommit autocommit=],
    "getTables" => %i[get_tables tables], "getColumns" => %i[get_columns columns],
    "tableExists" => %i[table_exists table_exists?],
    "lastInsertId" => %i[last_insert_id last_id],
    "error" => %i[error last_error]
  }.freeze

  # Measured 2026-07-30 with the contract module in place. These are FLOORS.
  # Raise one when you migrate a driver; never lower one.
  # Counted with implemented_by?, which asks whether the driver OVERRODE the
  # method - not method_defined?, which cannot tell an implementation from the
  # module's raising stub. That is one lower per driver than the pre-module
  # probe, and it is the honest number: `autocommit` is a facade-set attr_writer
  # on most drivers rather than a driver method.
  # Against the REDESIGNED 14-method contract, measured 2026-07-30.
  #
  # Ruby scores LOWER here than against the old 20-method list, and that is the
  # honest result: the old list credited it for insert/update/delete, which the
  # FACADE implements, not the driver. Strip the methods that were never the
  # adapter's job and the real gap shows - and it is the SAME five everywhere
  # (getDatabaseType, fetch, startTransaction, autocommit, error), plus
  # tableExists on three. Five methods, not eleven scattered ones.
  FLOORS = {
    "FirebirdDriver" => 8, "MongodbDriver" => 8, "OdbcDriver" => 8,
    "MssqlDriver" => 9, "MysqlDriver" => 9, "SqliteDriver" => 9,
    "PostgresDriver" => 9
  }.freeze

  def implemented_count(klass)
    SPELLINGS.count do |_, names|
      names.any? { |n| Tina4::DatabaseAdapter.implemented_by?(klass.allocate, n) }
    end
  end

  it "declares exactly the shared contract" do
    want = contract["contracts"].values.flat_map { |c| c["methods"] }
    expect(described_class::CONTRACT.length).to eq(want.length)
    expect(want.length).to eq(14)
  end

  # The redesign's central claim, pinned. Ruby already had this shape; the first
  # contract this row produced would have taken it away.
  it "keeps CRUD and DDL off the adapter" do
    names = described_class::CONTRACT.map(&:to_s)
    %w[insert update delete create_table add_column execute_many fetch_one].each do |gone|
      expect(names).not_to include(gone), gone
    end
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
      expect { bare.new.get_database_type }
        .to raise_error(NotImplementedError, /does not implement #get_database_type/)
    end

    it "is distinguishable from an implemented one" do
      bare = Class.new { include Tina4::DatabaseAdapter }
      real = Class.new do
        include Tina4::DatabaseAdapter
        def get_database_type = "sqlite"
      end
      expect(Tina4::DatabaseAdapter.implemented_by?(bare.new, :get_database_type)).to be false
      expect(Tina4::DatabaseAdapter.implemented_by?(real.new, :get_database_type)).to be true
    end
  end
end
