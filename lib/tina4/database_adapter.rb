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
  # ADR-0044 / DBA-S02: a registered adapter does not satisfy the Tina4
  # database adapter contract. Raised at registration time, naming the
  # adapter and the missing capability.
  class AdapterContractError < StandardError; end

  # ADR-0044 / DBA-P02: a provider/deployment cannot guarantee an atomic
  # multi-row batch. Raised by the shared execute_many default (or a driver's
  # own override) before any row is written.
  class UnsupportedAtomicBatchError < StandardError; end

  # ADR-0044 / DBA-B05: a ragged/mismatched parameter set in a batch. Raised
  # before any row of the batch is written.
  class BindingCountMismatchError < StandardError; end

  module DatabaseAdapter
    # The exact fourteen capabilities every driver must provide (ADR-0044,
    # plan/v3/fixtures/adapter_contract.json). None is optional. Kept as data
    # so the conformance spec can read it instead of maintaining a second copy.
    #
    # CRUD (insert/update/delete) and DDL (create_table/add_column) are NOT
    # here - they are composable above the adapter from execute +
    # get_database_type, and Ruby was already doing exactly that in the
    # facade, which is why Ruby's driver layer is 1335 LOC against PHP's 5823
    # for the same job. executeMany and fetchOne, by contrast, ARE required
    # adapter primitives under ADR-0044 (superseding the original redesign
    # that placed them above the adapter) - see execute_many/fetch_one below.
    CONTRACT = %i[
      connect close get_database_type
      execute execute_many fetch fetch_one
      start_transaction commit rollback autocommit
      tables columns table_exists?
    ].freeze

    # The subset with NO usable generic default - a driver MUST override
    # these or the raising stub is inherited verbatim.
    ABSTRACT_CONTRACT = %i[
      connect close get_database_type
      execute commit rollback
      tables columns
    ].freeze

    ABSTRACT_CONTRACT.each do |name|
      define_method(name) do |*_args, **_kwargs, &_block|
        raise NotImplementedError,
              "#{self.class} does not implement ##{name}, which the Tina4 " \
              "database adapter contract requires. See Tina4::DatabaseAdapter."
      end
    end

    # `open` is the pre-3.14 spelling every Ruby driver's constructor already
    # calls; `connect` is the ADR-0044 canonical lifecycle name. A temporary
    # forwarding alias, to be removed or explicitly deprecated before 3.14.
    def open(*args, **kwargs)
      connect(*args, **kwargs)
    end

    # `begin_transaction` is every existing driver's real spelling;
    # `start_transaction` is the ADR-0044 canonical name (matches Python/PHP/
    # Node). A thin forwarding default, exactly like `open` above.
    def start_transaction(*args, **kwargs)
      begin_transaction(*args, **kwargs)
    end

    # -- Capabilities with a REAL, usable generic default -------------------
    # Every driver already implements execute_query/tables (required above)
    # with identical spelling, so these compose safely for any driver that
    # does not provide its own optimized override.

    # ADR-0044: the adapter-level read-many primitive. Returns a native list
    # of records with NO pagination envelope and NO count probe - the
    # facade (Database#fetch) owns pagination and the true-total count.
    def fetch(sql, params = [])
      execute_query(sql, params)
    end

    # ADR-0044: one native record or nil. No pagination count probe.
    def fetch_one(sql, params = [])
      fetch(sql, params).first
    end

    # ADR-0044: table_exists? is required on the adapter. Drivers that expose
    # a native, efficient check (SQLite, MySQL, MSSQL) override this; the rest
    # get a correct, if less efficient, default from the required `tables`.
    def table_exists?(name)
      tables.any? { |t| t.to_s.downcase == name.to_s.downcase }
    end

    # ADR-0044: readable and writable native boolean, defaulting true.
    def autocommit
      @tina4_autocommit.nil? ? true : @tina4_autocommit
    end

    def autocommit=(value)
      @tina4_autocommit = value
    end

    # ADR-0044 / DBA-P02: whether this adapter's deployment can guarantee an
    # atomic multi-row batch write. Every built-in driver defaults to true; a
    # deployment that genuinely cannot (a standalone MongoDB without a
    # replica set is the motivating real case) sets this false so
    # execute_many rejects BEFORE the first write.
    def supports_atomic_batch
      @tina4_supports_atomic_batch.nil? ? true : @tina4_supports_atomic_batch
    end

    def supports_atomic_batch=(value)
      @tina4_supports_atomic_batch = value
    end

    # ADR-0044: one aggregate result for the whole batch - {affected_rows:,
    # last_id:}. Transaction OWNERSHIP is deliberately NOT here: the facade
    # (Database#execute_many) brackets begin/commit/rollback around exactly
    # one call to this method, exactly as it already does for a standalone
    # start_transaction()/execute()/commit() sequence, so a driver that
    # overrides this for native batching never has to duplicate that policy.
    def execute_many(sql, params_list = [])
      rows = params_list || []
      return { affected_rows: 0, last_id: nil } if rows.empty?

      # ADR-0044 (DBA-B05): a ragged parameter set must fail BEFORE any
      # durable partial success. Checked generically (every row's length must
      # match the first) rather than parsing the SQL's own placeholder count,
      # so it holds for every driver without a dialect-specific parser.
      expected = rows.first.length
      rows.each do |params|
        next if params.length == expected

        raise Tina4::BindingCountMismatchError,
              "execute_many binding count mismatch - expected #{expected} " \
              "parameters, got #{params.length}"
      end

      if !supports_atomic_batch && rows.length > 1
        raise Tina4::UnsupportedAtomicBatchError,
              "provider #{get_database_type.inspect} cannot guarantee an atomic " \
              "batch write on this deployment (required deployment capability: " \
              "a transaction-capable configuration) - rejected before the first " \
              "write rather than risking partial durability"
      end

      # ONE round-trip per CHUNK instead of one per ROW - see
      # Tina4::SQLTranslator.build_batch_inserts for the measured 121x-625x.
      batched = Tina4::SQLTranslator.build_batch_inserts(sql, rows, get_database_type)
      if batched.empty?
        rows.each { |params| execute(sql, params) }
      else
        batched.each { |chunk_sql, chunk_params| execute(chunk_sql, chunk_params) }
      end

      last_id = begin
        last_insert_id
      rescue StandardError
        nil
      end
      { affected_rows: rows.length, last_id: last_id }
    end

    # Fail loud when a class does not declare every required capability.
    #
    # For ABSTRACT_CONTRACT this checks the method was actually OVERRIDDEN
    # (implemented_by?, below) rather than merely inherited as the raising
    # stub. For the capabilities with a real generic default (execute_many,
    # fetch, fetch_one, table_exists?, autocommit, supports_atomic_batch),
    # simple presence is sufficient - the module's own default IS a complete,
    # correct implementation.
    def self.validate!(adapter_object, name = nil)
      label = name || adapter_object.class.name
      missing = CONTRACT.select do |capability|
        if ABSTRACT_CONTRACT.include?(capability)
          !implemented_by?(adapter_object, capability)
        else
          !adapter_object.respond_to?(capability)
        end
      end
      return if missing.empty?

      raise Tina4::AdapterContractError,
            "adapter #{label.inspect} does not implement the required Tina4 " \
            "database adapter contract capabilities: #{missing.join(', ')} " \
            "(ADR-0044 / plan/v3/fixtures/adapter_contract.json)"
    end

    # == Bounding the connect
    #
    # A connect that can block forever hangs the whole application with NO log,
    # no error and no signal. MEASURED here on Ruby 3.2.3 / Ubuntu 24.04.4
    # against a real TCPServer that accepts the TCP connection and then never
    # replies: pg, mysql2, tiny_tds AND fb all sat past 20 seconds and needed
    # SIGKILL - `timeout`'s SIGTERM could not even be delivered, because the
    # blocking work happens inside a C client that never yields to the
    # interpreter. (A CLOSED port is a different thing entirely: it refuses in
    # 0.00s and tests nothing.)
    #
    # ONE variable governs every driver whose connect crosses a network:
    #
    #   TINA4_DATABASE_CONNECT_TIMEOUT   seconds, default 10; <= 0 disables the
    #                                    bound (unbounded, the old behaviour);
    #                                    a non-number warns and falls back to 10
    #
    # Each driver applies it through its OWN native option - libpq
    # connect_timeout, mysql2 connect_timeout, FreeTDS login_timeout, mongo
    # connect_timeout - because only the C client can interrupt its own blocking
    # socket work. Ruby's Timeout.timeout and Thread#join CANNOT: see
    # Tina4::Drivers::FirebirdDriver.bound_reachability! for the measurement.
    #
    # There is deliberately NO outer Ruby timeout racing the native one. The
    # native option is the ONLY timer; bounding_connect below merely TRANSLATES
    # whatever the client raises into the one contract message, so the operator
    # is never left holding a driver-worded error that names no variable. Where
    # a driver cannot produce that message at all, its own file says so at the
    # point of exclusion:
    #
    #   postgres  bounded + contract message   libpq connect_timeout
    #   mysql     bounded + contract message   mysql2 connect_timeout
    #   mssql     bounded + contract message   FreeTDS login_timeout
    #   firebird  bounded to REACHABILITY only stdlib socket; the attach itself
    #                                          cannot be bounded from Ruby
    #   mongodb   bounded, NO message possible Client.new never fails
    #   sqlite    n/a                          local file, no network peer
    #   odbc      NOT bounded                  gem untestable here; see its file
    CONNECT_TIMEOUT_VAR = "TINA4_DATABASE_CONNECT_TIMEOUT"
    DEFAULT_CONNECT_TIMEOUT_SECONDS = 10

    # Seconds to bound a connect by, or nil when the operator disabled the bound.
    def self.connect_timeout_seconds
      seconds = Tina4::Env.float(CONNECT_TIMEOUT_VAR, default: DEFAULT_CONNECT_TIMEOUT_SECONDS)
      seconds.positive? ? seconds : nil
    end

    # Whole seconds for the native options that accept only an integer (libpq,
    # libmysqlclient, FreeTDS). STRICTLY greater than the bound, never below 1.
    #
    # floor(s) + 1, not ceil(s): the native option must land AFTER our bound so
    # the driver's own timer fires first and bounding_connect gets to translate
    # its failure. ceil(N) == N for a whole-second bound - and the shipped
    # default of 10 is whole - which put the driver's deadline ON our bound
    # instead of after it, so which message reached the caller came down to which
    # clock ticked first. floor(s) + 1 is strictly greater for every input,
    # whole or fractional, at a cost of at most one extra second on a path that
    # has already failed. (libpq also reads connect_timeout=0 as "wait forever",
    # so the +1 doubles as the guard against rounding a sub-second bound to 0.)
    def self.connect_timeout_whole_seconds
      seconds = connect_timeout_seconds
      seconds && [seconds.floor + 1, 1].max
    end

    # The one error a timed-out connect raises: it names the host, the port, the
    # seconds actually spent, and the variable that tunes it.
    def self.connect_timed_out!(host, port, elapsed_seconds, cause = nil)
      detail = cause ? " Driver reported: #{cause.message.to_s.gsub(/\s+/, " ").strip}" : ""
      raise Tina4::DatabaseConnectionError,
            "Database connect to #{host}:#{port} timed out after " \
            "#{format("%.1f", elapsed_seconds)}s (#{CONNECT_TIMEOUT_VAR}=" \
            "#{connect_timeout_seconds} seconds; set it to 0 to wait " \
            "indefinitely).#{detail}"
    end

    # Did a connect that FAILED take at least the configured bound?
    #
    # Two readings, because the framework and the driver do not share a clock.
    # bounding_connect times on CLOCK_MONOTONIC; libpq times its own
    # connect_timeout on gettimeofday - CLOCK_REALTIME (libmysqlclient and
    # FreeTDS likewise measure against the wall clock). NTP slews and steps
    # realtime and never touches monotonic, so a forward step or slew can make
    # the driver abort while a monotonic reading over the very same connect is
    # still short of the bound - and then the driver's own message, which names
    # no tunable, reaches the caller.
    #
    # Taking the LARGER of the two readings covers both directions: the realtime
    # reading catches a forward jump, and keeping the monotonic reading means a
    # BACKWARD jump cannot hide a timeout that really did happen. Pure, so the
    # decision is testable without faking a clock.
    def self.bound_reached?(elapsed_monotonic, elapsed_realtime, seconds)
      return false if seconds.nil?

      [elapsed_monotonic, elapsed_realtime].max >= seconds
    end

    # Run a driver's natively-bounded connect and translate an expiry into the
    # contract error above. The NATIVE option does the bounding; this only names
    # it. Whether the bound expired is decided by ELAPSED TIME, not by matching
    # driver error text - the four clients word it four different ways
    # ("timeout expired", "waiting for initial communication packet", "TDS
    # server connection timed out", "Connection timed out"), and a marker table
    # is one more thing to drift and MISS. A missed timeout is the whole defect.
    #
    # The elapsed time is read on BOTH clocks and compared through
    # bound_reached?, because the driver measured its own deadline on the wall
    # clock while we started ours on the monotonic one - see that method. The
    # strictly-greater native option (connect_timeout_whole_seconds) leaves the
    # driver's deadline after ours, so on an undisturbed clock the larger reading
    # comfortably reaches the bound with no slack to tune.
    def self.bounding_connect(host, port)
      started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      started_realtime = Process.clock_gettime(Process::CLOCK_REALTIME)
      yield
    rescue StandardError => error
      bound = connect_timeout_seconds
      raise if bound.nil?

      elapsed_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic
      elapsed_realtime = Process.clock_gettime(Process::CLOCK_REALTIME) - started_realtime
      raise unless bound_reached?(elapsed_monotonic, elapsed_realtime, bound)

      connect_timed_out!(host, port, [elapsed_monotonic, elapsed_realtime].max, error)
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
