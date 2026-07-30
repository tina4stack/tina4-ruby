# frozen_string_literal: true

module Tina4
  # The contract every database driver must satisfy.
  #
  # Feature 3 of the feature audit. Ruby had NO adapter interface: `Database`
  # called four things on a driver and guarded the rest behind six `respond_to?`
  # checks. The consequences, in order of severity:
  #
  # - A driver missing a method was discovered at runtime, on whichever engine
  #   nobody exercised, and the guards meant the failure was often a SILENT SKIP
  #   rather than an exception - which is worse than a crash.
  # - Nothing told a contributor writing an eighth driver what to implement. The
  #   answer was "read database.rb and infer", and it is 828 lines.
  # - The audit could not compare Ruby's contract to the other three, because
  #   Ruby did not have one. That was the finding.
  #
  # Measured against the shared contract (spec/fixtures/adapter_contract.json,
  # byte-identical in all four), the seven drivers scored 9, 10 and 11 out of 20
  # - three different levels of completeness, because each implemented whatever
  # its facade path happened to need.
  #
  # Every method here raises. A driver that does not override one fails LOUDLY,
  # at the point of the call, naming itself and the method - instead of being
  # quietly skipped.
  #
  # == Migration in progress
  #
  # The owner's decision (2026-07-30) is that CRUD lives on the ADAPTER, matching
  # PHP, Python and Node. Today Ruby's facade builds the SQL for fetch / insert /
  # update / delete and calls the driver's +execute+, consulting +drv.insert+
  # only when a driver chooses to own it (PostgreSQL does, via RETURNING *).
  # Those methods are declared here so the gap is visible and countable; they are
  # migrated driver by driver, each with its own test, rather than in one sweep.
  #
  # Until a driver overrides them, +Database+ keeps using its own path - see
  # +Database#driver_implements?+, which asks whether the driver actually
  # OVERRODE a method rather than whether it merely responds to it. That
  # distinction is the whole point: including this module makes every driver
  # respond to everything, so +respond_to?+ stopped being able to tell the
  # difference.
  module DatabaseAdapter
    # Methods a driver MUST override. Kept as data so the conformance spec can
    # read it instead of maintaining a second copy of the list.
    CONTRACT = %i[
      open close
      execute execute_many fetch fetch_one
      insert update delete
      start_transaction commit rollback
      get_tables get_columns table_exists
      create_table add_column
      last_insert_id error autocommit
    ].freeze

    CONTRACT.each do |name|
      define_method(name) do |*_args, **_kwargs, &_block|
        raise NotImplementedError,
              "#{self.class} does not implement ##{name}, which the Tina4 " \
              "database adapter contract requires. See Tina4::DatabaseAdapter."
      end
    end

    # Did this driver actually OVERRIDE the contract method, or is it inheriting
    # the raising stub? `respond_to?` cannot answer that once the module is
    # included, and answering it wrongly turns a working silent-skip path into a
    # NotImplementedError at runtime.
    def self.implemented_by?(object, name)
      return false unless object.respond_to?(name)

      owner = begin
        object.class.instance_method(name).owner
      rescue NameError
        nil
      end
      !owner.nil? && owner != self
    end
  end
end
