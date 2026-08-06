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
    # The REDESIGNED contract: only what genuinely differs per engine.
    #
    # CRUD (insert/update/delete), executeMany, fetchOne and DDL
    # (create_table/add_column) are NOT here. They are composable above the
    # adapter from execute + fetch + get_database_type, and Ruby was already
    # doing exactly that in the facade - which is why Ruby's driver layer is
    # 1335 LOC against PHP's 5823 for the same job. The first contract this row
    # produced would have made Ruby write those seven more times; this one keeps
    # the shape Ruby already had and asks the other three to adopt it.
    CONTRACT = %i[
      open close get_database_type
      execute fetch
      start_transaction commit rollback autocommit
      get_tables get_columns table_exists
      last_insert_id error
    ].freeze

    CONTRACT.each do |name|
      define_method(name) do |*_args, **_kwargs, &_block|
        raise NotImplementedError,
              "#{self.class} does not implement ##{name}, which the Tina4 " \
              "database adapter contract requires. See Tina4::DatabaseAdapter."
      end
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

    # Clock slack when deciding whether a failed connect was OUR bound expiring.
    # A native bound of 10s is measured back as 9.998s often enough to matter,
    # and without the slack the contract error would degrade into the raw driver
    # error at random.
    CONNECT_TIMEOUT_SLACK_SECONDS = 0.25

    # Seconds to bound a connect by, or nil when the operator disabled the bound.
    def self.connect_timeout_seconds
      seconds = Tina4::Env.float(CONNECT_TIMEOUT_VAR, default: DEFAULT_CONNECT_TIMEOUT_SECONDS)
      seconds.positive? ? seconds : nil
    end

    # Whole seconds for the native options that accept only an integer (libpq,
    # libmysqlclient, FreeTDS). Rounds UP and never below 1: libpq reads
    # connect_timeout=0 as "wait forever", so rounding 0.4 DOWN to 0 would
    # silently disable the very bound being set.
    def self.connect_timeout_whole_seconds
      seconds = connect_timeout_seconds
      seconds && [seconds.ceil, 1].max
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

    # Run a driver's natively-bounded connect and translate an expiry into the
    # contract error above. The NATIVE option does the bounding; this only names
    # it. Whether the bound expired is decided by ELAPSED TIME, not by matching
    # driver error text - the four clients word it four different ways
    # ("timeout expired", "waiting for initial communication packet", "TDS
    # server connection timed out", "Connection timed out"), and a marker table
    # is one more thing to drift and MISS. A missed timeout is the whole defect.
    def self.bounding_connect(host, port)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    rescue StandardError => error
      bound = connect_timeout_seconds
      raise if bound.nil?

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      raise if elapsed < bound - CONNECT_TIMEOUT_SLACK_SECONDS

      connect_timed_out!(host, port, elapsed, error)
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
