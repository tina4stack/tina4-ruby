# frozen_string_literal: true
require "json"
require "uri"
require "digest"
require "weakref"

module Tina4
  # Thread-safe connection pool with round-robin rotation.
  # Connections are created lazily on first use.
  class ConnectionPool
    attr_reader :size

    def initialize(pool_size, driver_factory:, connection_string:, username: nil, password: nil)
      @pool_size = pool_size
      @driver_factory = driver_factory
      @connection_string = connection_string
      @username = username
      @password = password
      @drivers = Array.new(pool_size)  # nil slots — lazy creation
      @index = 0
      @mutex = Mutex.new
    end

    # Get the next driver via round-robin. Thread-safe.
    def checkout
      @mutex.synchronize do
        idx = @index
        @index = (@index + 1) % @pool_size

        if @drivers[idx].nil?
          driver = @driver_factory.call
          driver.connect(@connection_string, username: @username, password: @password)
          @drivers[idx] = driver
        end

        @drivers[idx]
      end
    end

    # Return a driver to the pool. Currently a no-op for round-robin.
    def checkin(_driver)
      # no-op
    end

    # Close all active connections.
    def close_all
      @mutex.synchronize do
        @drivers.each_with_index do |driver, i|
          if driver
            driver.close rescue nil
            @drivers[i] = nil
          end
        end
      end
    end

    # Number of connections that have been created.
    def active_count
      @mutex.synchronize do
        @drivers.count { |d| !d.nil? }
      end
    end

    def size
      @pool_size
    end
  end

  class Database
    attr_reader :driver, :driver_name, :connected, :pool

    # Live Database instances, so the request dispatcher can reset the
    # request-scoped query cache on every connection at the start of a request.
    # WeakRefs avoid keeping closed connections (or short-lived script
    # connections) alive — parity with Python's weakref.WeakSet. Guarded by a
    # mutex because connections can be created from multiple threads.
    @instances = []
    @instances_mutex = Mutex.new

    class << self
      # Register a live connection in the class-level WeakRef registry.
      def register_instance(db)
        @instances_mutex.synchronize do
          @instances << WeakRef.new(db)
        end
      end

      # Clear the request-scoped query cache on every live Database instance.
      #
      # The request dispatcher calls this at the start of each HTTP request so
      # request-scoped caching never serves rows across requests (zero
      # cross-request staleness). Persistent-mode connections are left alone.
      # Dead WeakRefs (closed/GC'd connections) are pruned as we go.
      def reset_request_caches
        @instances_mutex.synchronize do
          @instances.reject! do |ref|
            begin
              inst = ref.__getobj__
              inst.cache_new_request
              false
            rescue WeakRef::RefError, StandardError
              true  # dead reference (or errored) — prune it
            end
          end
        end
      end
    end

    DRIVERS = {
      "sqlite" => "Tina4::Drivers::SqliteDriver",
      "sqlite3" => "Tina4::Drivers::SqliteDriver",
      "postgres" => "Tina4::Drivers::PostgresDriver",
      "postgresql" => "Tina4::Drivers::PostgresDriver",
      "pgsql" => "Tina4::Drivers::PostgresDriver",
      "mysql" => "Tina4::Drivers::MysqlDriver",
      "mssql" => "Tina4::Drivers::MssqlDriver",
      "sqlserver" => "Tina4::Drivers::MssqlDriver",
      "firebird" => "Tina4::Drivers::FirebirdDriver",
      "mongodb" => "Tina4::Drivers::MongodbDriver",
      "mongo" => "Tina4::Drivers::MongodbDriver",
      "odbc" => "Tina4::Drivers::OdbcDriver"
    }.freeze

    # v3.13.12 — strip trailing `;` from user SQL before the framework
    # wraps it with COUNT(*) subqueries or appends LIMIT/OFFSET. Without
    # this, ``"SELECT * FROM t;"`` produces ``"SELECT * FROM t; LIMIT 100
    # OFFSET 0"`` — a syntax error on every engine. Internal semicolons
    # (inside string literals, between meaningful statements) are left
    # alone; drivers reject those if multi-statement isn't supported.
    def self.strip_trailing_semicolons(sql)
      return sql if sql.nil? || sql.empty?
      stripped = sql.rstrip
      while stripped.end_with?(";")
        stripped = stripped[0..-2].rstrip
      end
      stripped
    end

    # Static factory — cross-framework consistency: Database.create(url)
    def self.create(url, username: "", password: "", pool: nil)
      new(url, username: username.empty? ? nil : username,
               password: password.empty? ? nil : password,
               pool: pool)
    end

    # Construct a Database from environment variables.
    # Returns nil if the named env var is not set.
    def self.from_env(env_key: "TINA4_DATABASE_URL", pool: nil)
      url = ENV[env_key]
      return nil if url.nil? || url.strip.empty?

      new(url,
          username: ENV["TINA4_DATABASE_USERNAME"],
          password: ENV["TINA4_DATABASE_PASSWORD"],
          pool: pool)
    end

    # Open a database connection — convention name matching SQLAlchemy
    # engine.connect() and the cross-framework Database.get_connection()
    # surface shipped in 3.13.x.
    #
    # The first argument may be either a URL (containing `://` or `sqlite:`)
    # or an env-var name. Falls back to in-memory SQLite when no URL
    # resolves — matches Python tina4_python's default behaviour.
    #
    #   db = Tina4::Database.get_connection                     # from TINA4_DATABASE_URL
    #   db = Tina4::Database.get_connection("sqlite::memory:")  # explicit URL
    #   db = Tina4::Database.get_connection("postgres://...", username: "u", password: "p")
    def self.get_connection(url_or_env_key = "TINA4_DATABASE_URL", username: nil, password: nil, pool: nil)
      if url_or_env_key.include?("://") || url_or_env_key.start_with?("sqlite:")
        return new(url_or_env_key, username: username, password: password, pool: pool)
      end

      db = from_env(env_key: url_or_env_key, pool: pool)
      return db if db

      # Fallback: in-memory SQLite — matches Python parity.
      new("sqlite::memory:", username: username, password: password, pool: pool)
    end

    def initialize(connection_string = nil, username: nil, password: nil, driver_name: nil, pool: nil)
      @connection_string = connection_string || ENV["TINA4_DATABASE_URL"]
      @username = username || ENV["TINA4_DATABASE_USERNAME"]
      @password = password || ENV["TINA4_DATABASE_PASSWORD"]
      @driver_name = driver_name || detect_driver(@connection_string)
      # TINA4_DB_POOL falls back when caller doesn't pass `pool:` explicitly.
      # Default 0 = single connection, N>0 = N pooled connections (round-robin).
      @pool_size = if pool.nil?
                     (ENV["TINA4_DB_POOL"] || "0").to_i
                   else
                     pool
                   end
      @connected = false

      # Per-instance thread-local key for the transaction adapter pin.
      # Without this pin, every Database method call rotates to a different
      # pooled connection. Inside a transaction this silently breaks atomicity:
      # start_transaction begins on adapter A, executes autocommit on B/C, and
      # commit/rollback land on D — a no-op. start_transaction sets the pin,
      # commit/rollback clear it. While pinned, current_driver returns the same
      # driver for every call so the whole transaction runs on one connection.
      @tx_pin_key = :"tina4_pinned_adapter_#{object_id}"
      # Per-thread nested-transaction depth counter (DB-contract C, v3.13.37).
      # A second start_transaction on a thread that already holds the pin is a
      # double-begin: most engines silently commit or no-op the inner BEGIN,
      # leaving the connection mid-transaction. We warn + increment depth instead
      # of re-beginning; the inner commit just decrements; the outer commit/any
      # rollback releases the pin.
      @tx_depth_key = :"tina4_tx_depth_#{object_id}"

      # Query cache. One store, two layers (parity with Python connection.py).
      # BOTH layers are OPT-IN — the DEFAULT is OFF.
      #
      # A request-scoped cache that defaults ON is a footgun: a SELECT MAX(id)
      # (or generator read) right before an INSERT in the SAME request returns a
      # cached pre-write value → duplicate primary keys, and any read-after-write
      # in one request shows stale state. So both layers default OFF:
      #   • request-scoped (opt-in, TINA4_AUTO_CACHING=true) — dedupes identical
      #     SELECTs to protect the DB from rapid repeat reads on read-heavy
      #     endpoints. Cleared at the START of every HTTP request (so it never
      #     serves rows across requests) AND on any write, with a short safety
      #     TTL (5s) for non-request contexts (scripts/workers).
      #   • persistent (opt-in, TINA4_DB_CACHE=true) — cross-request TTL cache
      #     that is NOT cleared per request; entries expire by TINA4_DB_CACHE_TTL.
      @cache_persistent = truthy?(ENV["TINA4_DB_CACHE"])
      # Default OFF; honour the same truthy semantics the framework uses
      # (mirrors Python's is_truthy(get("TINA4_AUTO_CACHING", "false"))).
      @cache_request_scoped = truthy?(ENV["TINA4_AUTO_CACHING"] || "false")
      @cache_enabled = @cache_persistent || @cache_request_scoped
      @cache_ttl = if @cache_persistent
                     (ENV["TINA4_DB_CACHE_TTL"] || "30").to_i
                   else
                     (ENV["TINA4_AUTO_CACHING_TTL"] || "5").to_i
                   end
      @query_cache = {}  # key => { expires_at:, value: }
      @cache_hits = 0
      @cache_misses = 0
      @cache_mutex = Mutex.new

      # Persistent mode may route through the unified CacheBackend (redis/
      # valkey/memcached/mongodb/database via TINA4_DB_CACHE_BACKEND) so
      # multiple instances can share one cache with global write-invalidation.
      # Request-scoped mode always stays in-process (the @query_cache dict).
      # The DatabaseResult is serialized to a JSON-friendly Hash before storing
      # and reconstructed on read so shared backends work cross-instance.
      @cache_backend = nil
      if @cache_persistent
        begin
          @cache_backend = Tina4::CacheBackends.create_backend(
            backend: ENV["TINA4_DB_CACHE_BACKEND"] || "memory",
            url: ENV["TINA4_DB_CACHE_URL"],
            max_entries: 1000
          )
        rescue StandardError
          @cache_backend = nil # fall back to the in-process dict
        end
      end

      # Autocommit is ON by default — parity with Python/PHP/Node. A standalone
      # write (execute/insert/update/delete made OUTSIDE an explicit
      # start_transaction()/commit() block) commits on its own connection before
      # returning, so a write actually persists. An UNSET TINA4_AUTOCOMMIT is
      # treated as TRUE; set TINA4_AUTOCOMMIT=false for strict manual mode (every
      # write needs an explicit commit). Inside an explicit transaction the
      # framework-issued commit is suppressed (gated on the thread tx-pin), so
      # explicit transactions stay atomic. Mirrors Python's
      # DatabaseAdapter._autocommit ("true"/"1"/"yes", default "true").
      @autocommit = truthy?(ENV.fetch("TINA4_AUTOCOMMIT", "true"))

      # Register this connection so Tina4::Database.reset_request_caches can
      # clear its request-scoped entries at the start of every HTTP request.
      Tina4::Database.register_instance(self)

      if @pool_size > 0
        # Pooled mode — create a ConnectionPool with lazy driver creation
        @pool = ConnectionPool.new(
          @pool_size,
          driver_factory: method(:create_driver),
          connection_string: @connection_string,
          username: @username,
          password: @password
        )
        @driver = nil
        @connected = true
      else
        # Single-connection mode — current behavior
        @pool = nil
        @driver = create_driver
        connect
      end
    end

    def connect
      @driver.connect(@connection_string, username: @username, password: @password)
      @connected = true

      # Push the resolved autocommit setting down to the driver when it exposes a
      # native toggle (default ON — see @autocommit in #initialize). The
      # framework-level commit in #autocommit_standalone_write covers drivers
      # that have no native setter.
      @driver.autocommit = @autocommit if @driver.respond_to?(:autocommit=)

      Tina4::Log.info("Database connected: #{@driver_name}")
    rescue => e
      Tina4::Log.error("Database connection failed: #{e.message}")
      @connected = false
    end

    def close
      if @pool
        @pool.close_all
      elsif @driver && @connected
        @driver.close
      end
      @connected = false
    end

    # Get the current driver — from pool (round-robin) or single connection.
    #
    # Inside a transaction, all calls must land on the SAME driver — otherwise
    # start_transaction, execute, and commit each rotate to a different pooled
    # connection and the transaction is meaningless. start_transaction pins
    # the driver to the calling thread; commit/rollback release it.
    def current_driver
      pinned = Thread.current[@tx_pin_key]
      return pinned if pinned
      if @pool
        @pool.checkout
      else
        @driver
      end
    end

    # ── Query Cache ──────────────────────────────────────────────

    def cache_stats
      if @cache_backend
        bs = @cache_backend.stats
        return {
          enabled: @cache_enabled,
          mode: cache_mode,
          hits: @cache_hits,
          misses: @cache_misses,
          size: bs[:size],
          backend: bs[:backend] || @cache_backend.name,
          ttl: @cache_ttl
        }
      end

      @cache_mutex.synchronize do
        {
          enabled: @cache_enabled,
          mode: cache_mode,
          hits: @cache_hits,
          misses: @cache_misses,
          size: @query_cache.size,
          backend: "memory",
          ttl: @cache_ttl
        }
      end
    end

    def cache_clear
      @cache_backend.clear if @cache_backend
      @cache_mutex.synchronize do
        @query_cache.clear
        @cache_hits = 0
        @cache_misses = 0
      end
    end

    # Clear the request-scoped query cache at the start of an HTTP request.
    #
    # No-op in persistent mode (TINA4_DB_CACHE=true) so cross-request entries
    # survive up to their TTL. Cumulative hit/miss counters are preserved.
    def cache_new_request
      return unless @cache_request_scoped && !@cache_persistent

      @cache_mutex.synchronize { @query_cache.clear }
    end

    # Fetch rows and return the records array directly.
    #
    # Symmetric with fetch_one. Cross-framework parity with Python
    # db.fetch_all() / PHP $db->fetchAll() / Node db.fetchAll().
    #
    #   rows = db.fetch_all("SELECT * FROM users WHERE active = ?", [1])
    #   rows.each { |row| puts row["name"] }
    #
    # Returns [] (not nil) when no rows match.
    #
    # v3.13.12: default `limit` is **nil** (no truncation) — the method
    # name says fetch_all, so it returns all matching rows. Pre-v3.13.12
    # silently truncated to 100. Pass an explicit `limit:` to cap.
    #
    # Pass `no_cache: true` to bypass the query cache for this call (see #fetch).
    def fetch_all(sql, params = [], limit: nil, offset: nil, no_cache: false)
      fetch(sql, params, limit: limit, offset: offset, no_cache: no_cache).records
    end

    # Fetch rows with pagination, returning a DatabaseResult.
    #
    # FAILS LOUD (v3.13.37, DB-contract A): a SQL error in the main query
    # propagates — a typo'd / bad SELECT RAISES, it never silently returns an
    # empty result. The cause is captured on @last_error / #get_error before the
    # re-raise (parity with #execute and the Python master), so the public API
    # can read why it failed even for engines whose driver doesn't expose its
    # own last_error. Because the raise happens BEFORE cache_set is reached, a
    # buried failure is never written into the query cache.
    #
    # Pass `no_cache: true` to bypass the query cache entirely for this single
    # call — no lookup, no store — and run the query directly against the
    # driver. Works for both the request-scoped auto-cache and the persistent
    # DB cache. The default `false` preserves the cached behaviour. Parity with
    # Python db.fetch(no_cache=) / PHP / Node.
    def fetch(sql, params = [], limit: 100, offset: nil, no_cache: false)
      offset ||= 0
      drv = current_driver

      # v3.13.12: strip trailing `;` so the driver's apply_limit
      # (which appends "LIMIT N OFFSET M") doesn't produce
      # "SELECT * FROM t; LIMIT 100 OFFSET 0" — a syntax error
      # on every engine. Also helps any COUNT(*) FROM (sql)
      # subqueries downstream survive a user-supplied semicolon.
      sql = Tina4::Database.strip_trailing_semicolons(sql)

      effective_sql = sql
      # Skip appending LIMIT if SQL already has one
      has_limit = sql.upcase.split("--")[0].include?("LIMIT")
      if limit && !has_limit
        effective_sql = drv.apply_limit(effective_sql, limit, offset)
      end

      if @cache_enabled && !no_cache
        key = cache_key(effective_sql, params)
        cached = cache_get(key)
        if cached
          @cache_mutex.synchronize { @cache_hits += 1 }
          return cached
        end
        # fetch_direct RAISES on a SQL error (and captures @last_error), so a
        # failed read never reaches cache_set below — we never cache an empty
        # result produced by a buried failure.
        result = fetch_direct(drv, effective_sql, params)
        cache_set(key, result)
        @cache_mutex.synchronize { @cache_misses += 1 }
        return result
      end

      fetch_direct(drv, effective_sql, params)
    end

    # Fetch a single row (or nil).
    #
    # FAILS LOUD (v3.13.37, DB-contract A): a SQL error RAISES and populates
    # @last_error / #get_error the same way #execute and #fetch do — pre-fix
    # fetch_one ran the query through #fetch but did not separately guarantee the
    # error capture, and a buried failure could be cached as nil. It now routes
    # the uncached path through fetch_one_direct (capture + re-raise) and, on the
    # cached path, only ever stores a value produced by a SUCCESSFUL read.
    #
    # Pass `no_cache: true` to bypass the query cache entirely for this call —
    # no lookup, no store — running the query directly. The `no_cache` flag is
    # propagated to the inner read so the request-scoped/persistent cache is
    # never populated either. Default `false` preserves cached behaviour.
    def fetch_one(sql, params = [], no_cache: false)
      sql = Tina4::Database.strip_trailing_semicolons(sql)
      if @cache_enabled && !no_cache
        key = cache_key(sql + ":ONE", params)
        cached = cache_get(key)
        if cached
          @cache_mutex.synchronize { @cache_hits += 1 }
          return cached
        end
        # Raises (and captures @last_error) BEFORE cache_set, so a failed read
        # is never cached as nil.
        value = fetch_one_direct(sql, params)
        cache_set(key, value)
        @cache_mutex.synchronize { @cache_misses += 1 }
        return value
      end

      fetch_one_direct(sql, params)
    end

    def insert(table, data)
      cache_invalidate if @cache_enabled
      drv = current_driver

      # List of hashes — batch insert.
      #
      # Cross-framework parity (mirrors the Python master's DatabaseAdapter.insert
      # → execute_many): build ONE parameterised INSERT and run it once per row
      # inside a SINGLE transaction on a SINGLE connection (see #execute_many),
      # then report a DatabaseResult whose affected_rows == the number of rows
      # (deterministic — the batch is all-or-raise) and a sensible last_id read
      # from that same connection. The per-driver #insert overrides (e.g.
      # PostgreSQL's INSERT ... RETURNING *) call data.keys, so they only ever
      # see a single Hash — the Array is intercepted here and never reaches them,
      # which is exactly the crash Python hit when a list fell through to a
      # keys-only override.
      if data.is_a?(Array)
        return Tina4::DatabaseResult.new([], affected_rows: 0, last_id: nil) if data.empty?
        keys = data.first.keys.map(&:to_s)
        placeholders = drv.placeholders(keys.length)
        sql = "INSERT INTO #{table} (#{keys.join(', ')}) VALUES (#{placeholders})"
        params_list = data.map { |row| keys.map { |k| row[k.to_sym] || row[k] } }
        return execute_many(sql, params_list)
      end

      # Issue #256: a driver that can surface the ACTUAL generated primary key
      # (PostgreSQL, via INSERT ... RETURNING *) owns its own insert so a UUID
      # PK comes back as the real 36-char string and a SERIAL PK as the integer
      # — instead of probing a session sequence (lastval()) that returns nil or
      # a stale wrong id for a UUID table. Other engines (SQLite/MySQL/MSSQL/
      # Firebird) keep the generic build-then-last_insert_id path below.
      if drv.respond_to?(:insert)
        result = drv.insert(table, data)
        autocommit_standalone_write(drv)
        return result
      end

      columns = data.keys.map(&:to_s)
      placeholders = drv.placeholders(columns.length)
      sql = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders})"
      drv.execute(sql, data.values)
      last_id = drv.last_insert_id
      autocommit_standalone_write(drv)
      { success: true, last_id: last_id }
    end

    def update(table, data, filter = {}, params = nil)
      cache_invalidate if @cache_enabled
      drv = current_driver

      # String filter with explicit params array
      if filter.is_a?(String) && !params.nil?
        set_parts = data.keys.map { |k| "#{k} = #{drv.placeholder}" }
        sql = "UPDATE #{table} SET #{set_parts.join(', ')}"
        sql += " WHERE #{filter}" unless filter.empty?
        drv.execute(sql, data.values + Array(params))
        autocommit_standalone_write(drv)
        return { success: true }
      end

      set_parts = data.keys.map { |k| "#{k} = #{drv.placeholder}" }
      where_parts = filter.keys.map { |k| "#{k} = #{drv.placeholder}" }
      sql = "UPDATE #{table} SET #{set_parts.join(', ')}"
      sql += " WHERE #{where_parts.join(' AND ')}" unless filter.empty?
      values = data.values + filter.values
      drv.execute(sql, values)
      autocommit_standalone_write(drv)
      { success: true }
    end

    def delete(table, filter = {}, params = nil)
      cache_invalidate if @cache_enabled
      drv = current_driver

      # List of hashes — delete each row
      if filter.is_a?(Array)
        filter.each { |row| delete(table, row) }
        return { success: true }
      end

      # String filter — raw WHERE clause with optional params
      if filter.is_a?(String)
        sql = "DELETE FROM #{table}"
        sql += " WHERE #{filter}" unless filter.empty?
        drv.execute(sql, Array(params))
        autocommit_standalone_write(drv)
        return { success: true }
      end

      # Hash filter — build WHERE from keys
      where_parts = filter.keys.map { |k| "#{k} = #{drv.placeholder}" }
      sql = "DELETE FROM #{table}"
      sql += " WHERE #{where_parts.join(' AND ')}" unless filter.empty?
      drv.execute(sql, filter.values)
      autocommit_standalone_write(drv)
      { success: true }
    end

    # Return the last execute() error message, or nil.
    def get_error
      @last_error
    end

    # Return the last insert ID from execute() or insert().
    def get_last_id
      current_driver.last_insert_id
    rescue
      nil
    end

    # Return the normalised engine name for this connection.
    #
    # Cross-framework parity with Python/PHP/Node ``get_database_type()``.
    # ORM.create_table needs this to emit engine-correct DDL (SERIAL vs
    # AUTOINCREMENT, BOOLEAN vs INTEGER, TIMESTAMP vs DATETIME). Returns the
    # resolved driver key ("postgres", "mysql", "mssql", "firebird",
    # "sqlite", ...) — the same alias-normalised value used to pick the
    # driver class, so callers don't have to re-parse the connection string.
    def get_database_type
      @driver_name
    end

    # Execute a write statement. FAILS LOUD — raises on a SQL error.
    #
    # On a SQL error (bad SQL, constraint violation, dead/aborted connection,
    # missing driver) the cause is captured on @last_error / #get_error AND the
    # error is re-raised — execute() never silently returns false on failure.
    # Almost no caller checks a boolean after every write, so the old
    # swallow-and-return-false behaviour turned a failed INSERT/UPDATE/DELETE
    # into a silent partial-write footgun. This mirrors fetch()/fetch_one(),
    # which already raise, and the Python master (database.execute).
    #
    # On SUCCESS the return is unchanged: a DatabaseResult when the SQL contains
    # RETURNING, CALL, EXEC, or SELECT (truthy), otherwise true. Never false.
    #
    # Higher-level callers that promise a boolean (ORM save/create_table) wrap
    # this in begin/rescue and return false themselves; the migration runner and
    # dev-admin/MCP DB tools catch the raise and surface it as a failed migration
    # or a clean { error: } payload respectively.
    def execute(sql, params = [])
      cache_invalidate if @cache_enabled
      drv = current_driver
      result = drv.execute(sql, params)
      @last_error = nil
      autocommit_standalone_write(drv)
      sql_upper = sql.strip.upcase
      if sql_upper.include?("RETURNING") || sql_upper.start_with?("CALL ") ||
         sql_upper.start_with?("EXEC ") || sql_upper.start_with?("SELECT ")
        return result
      end
      true
    rescue => e
      @last_error = e.message
      raise
    end

    # Run one statement once per row in a SINGLE transaction on a SINGLE
    # connection, returning a DatabaseResult.
    #
    # DB-contract / batch-insert parity (mirrors the Python master's
    # execute_many): the WHOLE batch runs on ONE driver — pinned for the
    # duration — so begin/execute*/commit can never scatter across pooled
    # connections (which made affected_rows / last_id non-deterministic). It is
    # all-or-raise (any row raising rolls the whole batch back), so:
    #
    #   * affected_rows is the ROW COUNT, computed deterministically from the
    #     number of supplied rows — NOT read from a driver rowcount. PostgreSQL's
    #     no-RETURNING INSERT reports cmd_tuples correctly, but other engines'
    #     rowcounts after a batch are unreliable, and a follow-up probe (lastval/
    #     SAVEPOINT) can clobber the rowcount, so the count is the supplied length.
    #   * last_id is read from last_insert_id() on the SAME connection AFTER the
    #     batch, so a SERIAL/AUTOINCREMENT table surfaces the last generated id
    #     (nil for engines/tables with no sequence — Firebird, a no-PK table).
    #
    # The pin is set here only when no transaction is already open on the thread
    # (an outer start_transaction already pinned the driver — leave it, and let
    # the outer commit/rollback own the lifecycle). When we pin, we own the
    # begin/commit/rollback; when an outer tx owns the pin, we just run the rows
    # and let the outer transaction commit them.
    def execute_many(sql, params_list = [])
      params_list ||= []
      already_pinned = !Thread.current[@tx_pin_key].nil?
      drv = current_driver
      Thread.current[@tx_pin_key] = drv unless already_pinned

      begin
        drv.begin_transaction unless already_pinned
        begin
          params_list.each { |params| drv.execute(sql, params) }
          drv.commit unless already_pinned
        rescue => e
          drv.rollback unless already_pinned
          @last_error = e.message
          raise e
        end
      ensure
        Thread.current[@tx_pin_key] = nil unless already_pinned
      end

      last_id = begin
        drv.last_insert_id
      rescue StandardError
        nil
      end

      Tina4::DatabaseResult.new(
        [],
        affected_rows: params_list.length,
        last_id: last_id,
        db: self
      )
    end

    def transaction
      drv = current_driver
      Thread.current[@tx_pin_key] = drv
      Thread.current[@tx_depth_key] = 1
      drv.begin_transaction
      yield self
      drv.commit
    rescue => e
      drv.rollback if drv
      raise e
    ensure
      Thread.current[@tx_pin_key] = nil
      Thread.current[@tx_depth_key] = nil
    end

    # Begin a transaction without a block — matches PHP/Python/Node API.
    # Pins the driver to this thread for the whole transaction so executes
    # and the final commit/rollback all run on the same connection.
    #
    # Nested-begin guard (v3.13.37, DB-contract C): a second start_transaction
    # on a thread that already holds the pin is a double-begin — the inner BEGIN
    # silently commits or no-ops on most engines, leaving the connection
    # mid-transaction with the caller none the wiser. We keep a per-thread depth
    # counter and log a clear warning instead of silently re-beginning. The pin
    # stays on the original driver so commit/rollback still land on the right
    # connection.
    def start_transaction
      pinned = Thread.current[@tx_pin_key]
      if pinned
        depth = (Thread.current[@tx_depth_key] || 1)
        Tina4::Log.warning(
          "start_transaction called while a transaction is already open on this " \
          "thread (depth would become #{depth + 1}). Nested transactions are not " \
          "supported — the existing transaction stays open on its pinned " \
          "connection and this nested begin is ignored. Commit or rollback the " \
          "outer transaction first."
        )
        Thread.current[@tx_depth_key] = depth + 1
        return
      end
      drv = current_driver
      Thread.current[@tx_pin_key] = drv
      Thread.current[@tx_depth_key] = 1
      drv.begin_transaction
    end

    # Commit the current transaction and release the driver pin.
    #
    # FAILS LOUD (v3.13.37, DB-contract C): if the underlying commit raises,
    # capture @last_error and RE-RAISE — never swallow. On failure the
    # transaction pin is RETAINED so the caller's follow-up #rollback lands on
    # the SAME connection (clearing it would leak a dirty connection back into
    # the pool and route the rollback to a different one). The pin is cleared
    # ONLY on a successful commit. An inner commit of an ignored nested begin
    # (depth > 1) just decrements the depth and returns — the outer commit is
    # the real one.
    def commit
      depth = (Thread.current[@tx_depth_key] || 0)
      if depth > 1
        Thread.current[@tx_depth_key] = depth - 1
        return
      end
      current_driver.commit
      @last_error = nil
      # Success — release the pin.
      Thread.current[@tx_pin_key] = nil
      Thread.current[@tx_depth_key] = nil
    rescue => e
      # Keep the pin so rollback reaches this same connection.
      @last_error = e.message
      raise
    end

    # Roll back the current transaction and release the driver pin.
    #
    # Rollback is the terminal cleanup of a transaction, so it ALWAYS clears the
    # pin (and the depth counter) — even after a failed commit it routes to the
    # retained pinned connection and cleans it up. If the underlying rollback
    # itself raises, @last_error is captured and the error re-raised, but the pin
    # is still released so a poisoned connection doesn't stay pinned forever.
    def rollback
      current_driver.rollback
      @last_error = nil
    rescue => e
      @last_error = e.message
      raise
    ensure
      Thread.current[@tx_pin_key] = nil
      Thread.current[@tx_depth_key] = nil
    end

    def tables
      current_driver.tables
    end

    # Cross-framework alias for tables — matches PHP/Python/Node get_tables.
    alias get_tables tables

    def columns(table_name)
      current_driver.columns(table_name)
    end

    # Cross-framework alias for columns — matches PHP/Python/Node get_columns.
    alias get_columns columns

    def table_exists?(table_name)
      drv = current_driver
      # v3.13.14 (#48): drivers that can resolve a schema/catalog-qualified
      # name ("gift_cards.gift_card", "dbo.widget", "attached.table") answer
      # directly; the rest fall back to a case-insensitive scan of tables.
      return drv.table_exists?(table_name) if drv.respond_to?(:table_exists?)

      tables.any? { |t| t.downcase == table_name.to_s.downcase }
    end

    # Cross-framework alias for table_exists? — matches PHP/Python/Node table_exists.
    alias table_exists table_exists?

    # Pre-generate the next available primary key ID using engine-aware strategies.
    #
    # Race-safe implementation using a `tina4_sequences` table for SQLite/MySQL/MSSQL
    # fallback. Each call atomically increments the stored counter, so concurrent
    # callers never receive the same value.
    #
    # - Firebird: auto-creates a generator if missing, then increments via GEN_ID.
    # - PostgreSQL: tries nextval() on the named sequence, auto-creates it if missing.
    # - SQLite/MySQL/MSSQL: atomic UPDATE on `tina4_sequences` table.
    # - Returns 1 if the table is empty or does not exist.
    #
    # @param table [String] Table name
    # @param pk_column [String] Primary key column name (default: "id")
    # @param generator_name [String, nil] Override for sequence/generator name
    # @return [Integer] The next available ID
    # Returns the underlying driver object (pool's current driver or single driver).
    def get_adapter
      current_driver
    end

    # Returns the configured pool size, or 1 for single-connection mode.
    def pool_size
      @pool_size > 0 ? @pool_size : 1
    end

    # Number of connections currently created (lazy pool connections counted).
    def active_count
      if @pool
        @pool.active_count
      else
        @connected ? 1 : 0
      end
    end

    # Check out a driver from the pool (or return the single driver).
    def checkout
      current_driver
    end

    # Return a driver to the pool. No-op for round-robin pool or single connection.
    def checkin(_driver)
      # no-op
    end

    # Close all pooled connections (or the single connection).
    def close_all
      close
    end

    def get_next_id(table, pk_column: "id", generator_name: nil)
      drv = current_driver

      # Firebird — use generators
      if @driver_name == "firebird"
        gen_name = generator_name || "GEN_#{table.upcase}_ID"

        # Auto-create the generator if it does not exist
        begin
          drv.execute("CREATE GENERATOR #{gen_name}")
        rescue
          # Generator already exists — ignore
        end

        rows = drv.execute_query("SELECT GEN_ID(#{gen_name}, 1) AS NEXT_ID FROM RDB$DATABASE")
        row = rows.is_a?(Array) ? rows.first : nil
        val = row_value(row, :NEXT_ID) || row_value(row, :next_id)
        return val&.to_i || 1
      end

      # PostgreSQL — try sequence first, auto-create if missing
      if @driver_name == "postgres"
        seq_name = generator_name || "#{table.downcase}_#{pk_column.downcase}_seq"
        begin
          rows = drv.execute_query("SELECT nextval('#{seq_name}') AS next_id")
          row = rows.is_a?(Array) ? rows.first : nil
          val = row_value(row, :next_id) || row_value(row, :nextval)
          return val.to_i if val
        rescue
          # Sequence does not exist — auto-create it seeded from MAX
          begin
            max_rows = drv.execute_query("SELECT COALESCE(MAX(#{pk_column}), 0) AS max_id FROM #{table}")
            max_row = max_rows.is_a?(Array) ? max_rows.first : nil
            max_val = row_value(max_row, :max_id)
            start_val = max_val ? max_val.to_i + 1 : 1
            drv.execute("CREATE SEQUENCE #{seq_name} START WITH #{start_val}")
            drv.commit rescue nil
            rows = drv.execute_query("SELECT nextval('#{seq_name}') AS next_id")
            row = rows.is_a?(Array) ? rows.first : nil
            val = row_value(row, :next_id) || row_value(row, :nextval)
            return val&.to_i || start_val
          rescue
            # Fall through to sequence table fallback
          end
        end
      end

      # SQLite / MySQL / MSSQL / PostgreSQL fallback — atomic sequence table
      seq_key = generator_name || "#{table}.#{pk_column}"
      sequence_next(seq_key, table: table, pk_column: pk_column)
    end

    private

    # Run a fetch straight against the driver — no cache lookup or store.
    #
    # DB-contract A (v3.13.37): shared by the cached and no_cache paths so error
    # capture is identical regardless of caching. FAILS LOUD: a SQL error in the
    # main query propagates (same contract as #execute). The cause is captured on
    # @last_error for #get_error before the re-raise — preferring the driver's own
    # last_error (when it exposes one, e.g. postgres) over the exception message.
    def fetch_direct(drv, effective_sql, params)
      result = drv.execute_query(effective_sql, params)
      @last_error = nil
      Tina4::DatabaseResult.new(result, sql: effective_sql, db: self)
    rescue => e
      @last_error = driver_error_message(drv, e)
      raise
    end

    # Run a fetch_one straight against the driver — no cache lookup or store.
    #
    # DB-contract A (v3.13.37): goes through #fetch (so the trailing-semicolon
    # strip + LIMIT-append + driver path stay identical), but wraps it so the
    # error is captured on @last_error and re-raised. Returns the first row (a
    # Hash) or nil on a SUCCESSFUL "no row" read.
    def fetch_one_direct(sql, params)
      result = fetch(sql, params, limit: 1, no_cache: true)
      @last_error = nil
      result.first
    rescue => e
      @last_error = driver_error_message(current_driver, e)
      raise
    end

    # Prefer the driver's own last_error (postgres sets one) over str(e), so the
    # captured message matches what each engine surfaces; never blank.
    def driver_error_message(drv, error)
      drv_err = drv.respond_to?(:last_error) ? drv.last_error : nil
      msg = drv_err || error.message
      msg = error.message if msg.nil? || msg.to_s.empty?
      msg || @last_error
    end

    # Ensure the tina4_sequences table exists for race-safe ID generation.
    def ensure_sequence_table
      return if table_exists?("tina4_sequences")

      drv = current_driver
      if @driver_name == "mssql"
        drv.execute("CREATE TABLE tina4_sequences (seq_name VARCHAR(200) NOT NULL PRIMARY KEY, current_value INTEGER NOT NULL DEFAULT 0)")
      else
        drv.execute("CREATE TABLE IF NOT EXISTS tina4_sequences (seq_name VARCHAR(200) NOT NULL PRIMARY KEY, current_value INTEGER NOT NULL DEFAULT 0)")
      end
      drv.commit rescue nil
    end

    # Atomically increment and return the next value for a named sequence.
    #
    # DB-contract B (v3.13.37): the old read-increment-read path had a RACE —
    # two concurrent callers could read the same current_value and return the
    # same id (duplicate primary keys). Each engine now uses a single atomic
    # increment-and-return, pinned to ONE driver so the two statements (where two
    # are needed) land on the same connection:
    #
    #   * SQLite (lib >= 3.35): UPDATE ... SET current_value = current_value + 1
    #     WHERE seq_name = ? RETURNING current_value — one atomic statement, run
    #     under the process-wide SqliteDriver.write_lock. Older SQLite falls back
    #     to UPDATE +1 then SELECT, still serialised by the held write_lock.
    #   * MySQL: UPDATE ... SET current_value = LAST_INSERT_ID(current_value + 1)
    #     then SELECT LAST_INSERT_ID() on the SAME connection (per-connection →
    #     race-safe).
    #   * MSSQL: UPDATE ... SET current_value += 1 OUTPUT inserted.current_value
    #     WHERE seq_name = ? — one atomic statement.
    #
    # Seeding is race-safe: an atomic insert-if-absent (INSERT OR IGNORE /
    # INSERT IGNORE / INSERT ... WHERE NOT EXISTS) seeded from MAX(pk) runs BEFORE
    # the atomic increment, so there is never a read-then-insert gap. On error we
    # RAISE (never silently fall back to 1).
    def sequence_next(seq_name, table: nil, pk_column: "id")
      # Pin a single driver for the whole sequence op so seed + increment + read
      # all hit the SAME connection. Inside an active transaction the driver is
      # already pinned; otherwise pin here and release in the ensure so the pool
      # can rotate afterwards.
      already_pinned = !Thread.current[@tx_pin_key].nil?
      drv = current_driver
      Thread.current[@tx_pin_key] = drv unless already_pinned

      begin
        case @driver_name
        when "sqlite"
          # SQLite does ensure-table + seed + increment all under the driver
          # write lock (a single shared connection — concurrent reads/writes on
          # it otherwise corrupt or race).
          sequence_next_sqlite(drv, seq_name, table, pk_column)
        when "mysql"
          ensure_sequence_table
          sequence_next_mysql(drv, seq_name, table, pk_column)
        when "mssql"
          ensure_sequence_table
          sequence_next_mssql(drv, seq_name, table, pk_column)
        else
          # Any other engine routed here (defensive) — generic atomic-ish path.
          ensure_sequence_table
          sequence_next_generic(drv, seq_name, table, pk_column)
        end
      ensure
        Thread.current[@tx_pin_key] = nil unless already_pinned
      end
    end

    # Best-effort MAX(pk) seed for a new sequence row. 0 if table missing/empty.
    def sequence_seed_value(drv, table, pk_column)
      return 0 unless table

      max_rows = drv.execute_query("SELECT MAX(#{pk_column}) AS max_id FROM #{table}")
      max_row = max_rows.is_a?(Array) ? max_rows.first : nil
      val = row_value(max_row, :max_id)
      val ? val.to_i : 0
    rescue StandardError
      0  # Table doesn't exist yet — start at 0
    end

    # SQLite atomic increment. Holds the process-wide write lock for the ENTIRE
    # op (ensure-table + seed + increment). The single UPDATE ... RETURNING (lib
    # >= 3.35) is itself atomic; the held lock serialises every connection touch
    # so no duplicate ids under concurrency. ensure-table is done inline under the
    # lock (NOT via ensure_sequence_table, which would re-enter current_driver/
    # table_exists? and risk a nested touch).
    def sequence_next_sqlite(drv, seq_name, table, pk_column)
      conn = drv.respond_to?(:connection) ? drv.connection : nil
      raise "get_next_id: SQLite driver has no live connection" if conn.nil?

      Tina4::Drivers::SqliteDriver.write_lock.synchronize do
        # Ensure the sequence table exists (idempotent) on this connection.
        conn.execute(
          "CREATE TABLE IF NOT EXISTS tina4_sequences (" \
          "seq_name VARCHAR(200) NOT NULL PRIMARY KEY, " \
          "current_value INTEGER NOT NULL DEFAULT 0)"
        )
        seed = sequence_seed_value(drv, table, pk_column)
        conn.execute(
          "INSERT OR IGNORE INTO tina4_sequences (seq_name, current_value) VALUES (?, ?)",
          [seq_name, seed]
        )

        if sqlite_supports_returning?
          # One atomic increment-and-return.
          rows = conn.execute(
            "UPDATE tina4_sequences SET current_value = current_value + 1 " \
            "WHERE seq_name = ? RETURNING current_value",
            [seq_name]
          )
          row = rows.is_a?(Array) ? rows.first : nil
        else
          # Older SQLite (< 3.35, no RETURNING): increment then read. Still
          # race-safe because we hold write_lock across both statements.
          conn.execute(
            "UPDATE tina4_sequences SET current_value = current_value + 1 WHERE seq_name = ?",
            [seq_name]
          )
          rows = conn.execute(
            "SELECT current_value FROM tina4_sequences WHERE seq_name = ?",
            [seq_name]
          )
          row = rows.is_a?(Array) ? rows.first : nil
        end

        val = sqlite_row_value(row, "current_value")
        raise "get_next_id: sequence row '#{seq_name}' vanished mid-increment" if val.nil?

        val.to_i
      end
    end

    # MySQL atomic increment. LAST_INSERT_ID(expr) stashes expr in this
    # CONNECTION's session var and returns it — atomic per-connection, no
    # read-back race. Calls the driver directly (not self.commit) so it doesn't
    # trip Database#commit's pin management.
    def sequence_next_mysql(drv, seq_name, table, pk_column)
      seed = sequence_seed_value(drv, table, pk_column)
      # Race-safe seed: INSERT IGNORE is a no-op if the row exists.
      drv.execute("INSERT IGNORE INTO tina4_sequences (seq_name, current_value) VALUES (?, ?)", [seq_name, seed])
      drv.commit rescue nil
      drv.execute(
        "UPDATE tina4_sequences SET current_value = LAST_INSERT_ID(current_value + 1) WHERE seq_name = ?",
        [seq_name]
      )
      drv.commit rescue nil
      rows = drv.execute_query("SELECT LAST_INSERT_ID() AS next_id")
      row = rows.is_a?(Array) ? rows.first : nil
      val = row_value(row, :next_id)
      raise "get_next_id: LAST_INSERT_ID() returned nothing for '#{seq_name}'" if val.nil?

      val.to_i
    end

    # MSSQL atomic increment via a single UPDATE ... OUTPUT statement.
    def sequence_next_mssql(drv, seq_name, table, pk_column)
      seed = sequence_seed_value(drv, table, pk_column)
      # Race-safe seed: INSERT only when absent (single statement).
      drv.execute(
        "INSERT INTO tina4_sequences (seq_name, current_value) " \
        "SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM tina4_sequences WHERE seq_name = ?)",
        [seq_name, seed, seq_name]
      )
      drv.commit rescue nil
      # Single atomic statement: increment + return the new value via OUTPUT.
      rows = drv.execute_query(
        "UPDATE tina4_sequences SET current_value = current_value + 1 " \
        "OUTPUT inserted.current_value AS next_id WHERE seq_name = ?",
        [seq_name]
      )
      drv.commit rescue nil
      row = rows.is_a?(Array) ? rows.first : nil
      val = row_value(row, :next_id)
      raise "get_next_id: OUTPUT produced no row for sequence '#{seq_name}'" if val.nil?

      val.to_i
    end

    # Defensive fallback for any engine not otherwise special-cased: seed if
    # absent (rollback on conflict), increment, then read on the pinned driver.
    def sequence_next_generic(drv, seq_name, table, pk_column)
      seed = sequence_seed_value(drv, table, pk_column)
      begin
        drv.execute("INSERT INTO tina4_sequences (seq_name, current_value) VALUES (?, ?)", [seq_name, seed])
        drv.commit rescue nil
      rescue StandardError
        # Row likely already exists (PK conflict) — fine, keep going.
        drv.rollback rescue nil
      end
      drv.execute("UPDATE tina4_sequences SET current_value = current_value + 1 WHERE seq_name = ?", [seq_name])
      drv.commit rescue nil
      rows = drv.execute_query("SELECT current_value FROM tina4_sequences WHERE seq_name = ?", [seq_name])
      row = rows.is_a?(Array) ? rows.first : nil
      val = row_value(row, :current_value)
      raise "get_next_id: sequence row '#{seq_name}' missing" if val.nil?

      val.to_i
    end

    # Whether the loaded SQLite library supports the RETURNING clause (>= 3.35).
    def sqlite_supports_returning?
      return @sqlite_returning unless @sqlite_returning.nil?

      ver = (defined?(SQLite3::SQLITE_VERSION) && SQLite3::SQLITE_VERSION) || "0.0.0"
      parts = ver.split(".").map(&:to_i)
      major, minor = parts[0].to_i, parts[1].to_i
      @sqlite_returning = (major > 3) || (major == 3 && minor >= 35)
    rescue StandardError
      @sqlite_returning = false
    end

    # Read a value from a raw sqlite3 row (results_as_hash → string keys; a bare
    # RETURNING row may come back as a positional Array on some gem versions).
    def sqlite_row_value(row, key)
      return nil if row.nil?

      if row.is_a?(Hash)
        row[key] || row[key.to_sym] || row.values.first
      elsif row.is_a?(Array)
        row.first
      end
    end

    # Safely extract a value from a driver result row, trying both symbol and string keys.
    def row_value(row, key)
      return nil unless row
      row[key.to_sym] || row[key.to_s] || row[key.to_s.upcase] || row[key.to_s.downcase]
    end

    def truthy?(val)
      %w[true 1 yes on].include?((val || "").to_s.strip.downcase)
    end

    # Durability: commit a standalone write so it actually persists.
    #
    # Called after a write (execute/insert/update/delete) issued OUTSIDE an
    # explicit transaction. The commit is suppressed when autocommit is off
    # (TINA4_AUTOCOMMIT=false, strict manual mode) OR when a transaction is open
    # on this thread (the thread tx-pin is set) — so an explicit
    # start_transaction()/commit() block stays atomic and is never broken up by
    # a per-statement commit. A commit with no transaction in progress is a
    # harmless no-op on every engine (SQLite swallows the specific
    # "no transaction is active" error in its driver; PostgreSQL/MySQL/MSSQL emit
    # at most a benign warning), so this never raises in the common case. Mirrors
    # the `not self._in_transaction and self.autocommit` gate in the Python
    # master and PHP's `autoCommit && transaction === null`.
    def autocommit_standalone_write(drv)
      return unless @autocommit
      return unless Thread.current[@tx_pin_key].nil?

      drv.commit
    rescue StandardError => e
      # A standalone write already succeeded; a follow-up commit failure here
      # must not mask that. Capture for #get_error and log, but don't raise.
      @last_error = e.message
      Tina4::Log.warning("autocommit commit after standalone write failed: #{e.message}")
    end

    # "persistent" / "request" / "off" — mirrors Python connection.py.
    def cache_mode
      if @cache_persistent
        "persistent"
      elsif @cache_request_scoped
        "request"
      else
        "off"
      end
    end

    def cache_key(sql, params)
      Digest::SHA256.hexdigest(sql + params.to_s)
    end

    def cache_get(key)
      # Shared backend (persistent + TINA4_DB_CACHE_BACKEND) — reconstruct the
      # DatabaseResult from the serialized Hash so cross-instance reads work.
      if @cache_backend
        raw = @cache_backend.get(key)
        return raw.is_a?(Hash) ? deserialize_result(raw) : nil
      end

      @cache_mutex.synchronize do
        entry = @query_cache[key]
        return nil unless entry
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > entry[:expires_at]
          @query_cache.delete(key)
          return nil
        end
        entry[:value]
      end
    end

    def cache_set(key, value)
      if @cache_backend
        @cache_backend.set(key, serialize_result(value), @cache_ttl)
        return
      end

      @cache_mutex.synchronize do
        @query_cache[key] = {
          expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + @cache_ttl,
          value: value
        }
      end
    end

    def cache_invalidate
      @cache_backend.clear if @cache_backend
      @cache_mutex.synchronize { @query_cache.clear }
    end

    # Flatten a DatabaseResult (or a single fetch_one Hash) into a JSON-friendly
    # Hash for shared backends. fetch_one stores a plain Hash row, so we tag the
    # shape so deserialize can return the right thing.
    def serialize_result(value)
      if value.is_a?(Tina4::DatabaseResult)
        {
          "kind" => "result",
          "records" => value.records,
          "count" => value.count,
          "limit" => value.limit,
          "offset" => value.offset,
          "affected_rows" => value.affected_rows,
          "last_id" => value.last_id
        }
      else
        # fetch_one row (Hash) or nil
        { "kind" => "row", "row" => value }
      end
    end

    # Reconstruct from a backend-cached Hash. JSON round-trips string keys, so
    # accept both string and symbol keys. Records are re-symbolised so a cached
    # result is byte-for-byte equivalent to an uncached fetch (driver rows use
    # symbol keys) regardless of which backend stored it.
    def deserialize_result(data)
      kind = data["kind"] || data[:kind]
      if kind == "row"
        row = data["row"] || data[:row]
        symbolize_row(row)
      else
        records = (data["records"] || data[:records] || []).map { |r| symbolize_row(r) }
        Tina4::DatabaseResult.new(
          records,
          count: data["count"] || data[:count] || 0,
          limit: data["limit"] || data[:limit] || 0,
          offset: data["offset"] || data[:offset] || 0,
          affected_rows: data["affected_rows"] || data[:affected_rows] || 0,
          last_id: data["last_id"] || data[:last_id]
        )
      end
    end

    # Driver rows use symbol keys; re-key a JSON-round-tripped Hash to match.
    def symbolize_row(row)
      return row unless row.is_a?(Hash)

      row.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    end

    def detect_driver(conn)
      case conn.to_s.downcase
      when /\.db$/, /\.sqlite/, /sqlite/
        "sqlite"
      when /postgres/, /^pg:/
        "postgres"
      when /mysql/
        "mysql"
      when /mssql/, /sqlserver/
        "mssql"
      when /firebird/, /\.fdb$/
        "firebird"
      when /mongodb/, /^mongo:/
        "mongodb"
      when /^odbc:/
        "odbc"
      else
        "sqlite"
      end
    end

    def create_driver
      klass_name = DRIVERS[@driver_name]
      raise "Unknown database driver: #{@driver_name}" unless klass_name
      klass = Object.const_get(klass_name)
      klass.new
    rescue NameError
      raise "Driver #{klass_name} not loaded. Install the required gem."
    end
  end
end
