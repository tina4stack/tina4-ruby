# frozen_string_literal: true
require "json"
require "uri"
require "digest"

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

    DRIVERS = {
      "sqlite" => "Tina4::Drivers::SqliteDriver",
      "sqlite3" => "Tina4::Drivers::SqliteDriver",
      "postgres" => "Tina4::Drivers::PostgresDriver",
      "postgresql" => "Tina4::Drivers::PostgresDriver",
      "mysql" => "Tina4::Drivers::MysqlDriver",
      "mssql" => "Tina4::Drivers::MssqlDriver",
      "sqlserver" => "Tina4::Drivers::MssqlDriver",
      "firebird" => "Tina4::Drivers::FirebirdDriver"
    }.freeze

    def initialize(connection_string = nil, username: nil, password: nil, driver_name: nil, pool: 0)
      @connection_string = connection_string || ENV["DATABASE_URL"]
      @username = username || ENV["DATABASE_USERNAME"]
      @password = password || ENV["DATABASE_PASSWORD"]
      @driver_name = driver_name || detect_driver(@connection_string)
      @pool_size = pool  # 0 = single connection, N>0 = N pooled connections
      @connected = false

      # Query cache — off by default, opt-in via TINA4_DB_CACHE=true
      @cache_enabled = truthy?(ENV["TINA4_DB_CACHE"])
      @cache_ttl = (ENV["TINA4_DB_CACHE_TTL"] || "30").to_i
      @query_cache = {}  # key => { expires_at:, value: }
      @cache_hits = 0
      @cache_misses = 0
      @cache_mutex = Mutex.new

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

      # Enable autocommit if TINA4_AUTOCOMMIT env var is set
      if truthy?(ENV["TINA4_AUTOCOMMIT"]) && @driver.respond_to?(:autocommit=)
        @driver.autocommit = true
      end

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
    def current_driver
      if @pool
        @pool.checkout
      else
        @driver
      end
    end

    # ── Query Cache ──────────────────────────────────────────────

    def cache_stats
      @cache_mutex.synchronize do
        {
          enabled: @cache_enabled,
          hits: @cache_hits,
          misses: @cache_misses,
          size: @query_cache.size,
          ttl: @cache_ttl
        }
      end
    end

    def cache_clear
      @cache_mutex.synchronize do
        @query_cache.clear
        @cache_hits = 0
        @cache_misses = 0
      end
    end

    def fetch(sql, params = [], limit: 100, offset: nil)
      offset ||= 0
      drv = current_driver

      effective_sql = sql
      # Skip appending LIMIT if SQL already has one
      has_limit = sql.upcase.split("--")[0].include?("LIMIT")
      if limit && !has_limit
        effective_sql = drv.apply_limit(effective_sql, limit, offset)
      end

      if @cache_enabled
        key = cache_key(effective_sql, params)
        cached = cache_get(key)
        if cached
          @cache_mutex.synchronize { @cache_hits += 1 }
          return cached
        end
        result = drv.execute_query(effective_sql, params)
        result = Tina4::DatabaseResult.new(result, sql: effective_sql, db: self)
        cache_set(key, result)
        @cache_mutex.synchronize { @cache_misses += 1 }
        return result
      end

      rows = drv.execute_query(effective_sql, params)
      Tina4::DatabaseResult.new(rows, sql: effective_sql, db: self)
    end

    def fetch_one(sql, params = [])
      if @cache_enabled
        key = cache_key(sql + ":ONE", params)
        cached = cache_get(key)
        if cached
          @cache_mutex.synchronize { @cache_hits += 1 }
          return cached
        end
        result = fetch(sql, params, limit: 1)
        value = result.first
        cache_set(key, value)
        @cache_mutex.synchronize { @cache_misses += 1 }
        return value
      end

      result = fetch(sql, params, limit: 1)
      result.first
    end

    def insert(table, data)
      cache_invalidate if @cache_enabled
      drv = current_driver

      # List of hashes — batch insert
      if data.is_a?(Array)
        return { success: true, affected_rows: 0 } if data.empty?
        keys = data.first.keys.map(&:to_s)
        placeholders = drv.placeholders(keys.length)
        sql = "INSERT INTO #{table} (#{keys.join(', ')}) VALUES (#{placeholders})"
        params_list = data.map { |row| keys.map { |k| row[k.to_sym] || row[k] } }
        return execute_many(sql, params_list)
      end

      columns = data.keys.map(&:to_s)
      placeholders = drv.placeholders(columns.length)
      sql = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders})"
      drv.execute(sql, data.values)
      { success: true, last_id: drv.last_insert_id }
    end

    def update(table, data, filter = {})
      cache_invalidate if @cache_enabled
      drv = current_driver

      set_parts = data.keys.map { |k| "#{k} = #{drv.placeholder}" }
      where_parts = filter.keys.map { |k| "#{k} = #{drv.placeholder}" }
      sql = "UPDATE #{table} SET #{set_parts.join(', ')}"
      sql += " WHERE #{where_parts.join(' AND ')}" unless filter.empty?
      values = data.values + filter.values
      drv.execute(sql, values)
      { success: true }
    end

    def delete(table, filter = {})
      cache_invalidate if @cache_enabled
      drv = current_driver

      # List of hashes — delete each row
      if filter.is_a?(Array)
        filter.each { |row| delete(table, row) }
        return { success: true }
      end

      # String filter — raw WHERE clause
      if filter.is_a?(String)
        sql = "DELETE FROM #{table}"
        sql += " WHERE #{filter}" unless filter.empty?
        drv.execute(sql)
        return { success: true }
      end

      # Hash filter — build WHERE from keys
      where_parts = filter.keys.map { |k| "#{k} = #{drv.placeholder}" }
      sql = "DELETE FROM #{table}"
      sql += " WHERE #{where_parts.join(' AND ')}" unless filter.empty?
      drv.execute(sql, filter.values)
      { success: true }
    end

    def execute(sql, params = [])
      cache_invalidate if @cache_enabled
      current_driver.execute(sql, params)
    end

    def execute_many(sql, params_list = [])
      results = []
      drv = current_driver
      drv.begin_transaction
      begin
        params_list.each do |params|
          results << drv.execute(sql, params)
        end
        drv.commit
      rescue => e
        drv.rollback
        raise e
      end
      results
    end

    def transaction
      drv = current_driver
      drv.begin_transaction
      yield self
      drv.commit
    rescue => e
      drv.rollback
      raise e
    end

    def tables
      current_driver.tables
    end

    def columns(table_name)
      current_driver.columns(table_name)
    end

    def table_exists?(table_name)
      tables.any? { |t| t.downcase == table_name.to_s.downcase }
    end

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
    # Seeds from MAX(pk_column) on first use so existing data is respected.
    def sequence_next(seq_name, table: nil, pk_column: "id")
      ensure_sequence_table
      drv = current_driver

      # Check if the sequence key already exists
      rows = drv.execute_query("SELECT current_value FROM tina4_sequences WHERE seq_name = ?", [seq_name])
      row = rows.is_a?(Array) ? rows.first : nil

      if row.nil?
        # Seed from MAX(pk_column) if table data exists
        seed_value = 0
        if table
          begin
            max_rows = drv.execute_query("SELECT MAX(#{pk_column}) AS max_id FROM #{table}")
            max_row = max_rows.is_a?(Array) ? max_rows.first : nil
            val = row_value(max_row, :max_id)
            seed_value = val.to_i if val
          rescue
            # Table may not exist yet — start from 0
          end
        end
        drv.execute("INSERT INTO tina4_sequences (seq_name, current_value) VALUES (?, ?)", [seq_name, seed_value])
        drv.commit rescue nil
      end

      # Atomic increment
      drv.execute("UPDATE tina4_sequences SET current_value = current_value + 1 WHERE seq_name = ?", [seq_name])
      drv.commit rescue nil

      # Read back the incremented value
      rows = drv.execute_query("SELECT current_value FROM tina4_sequences WHERE seq_name = ?", [seq_name])
      row = rows.is_a?(Array) ? rows.first : nil
      val = row_value(row, :current_value)
      val ? val.to_i : 1
    end

    # Safely extract a value from a driver result row, trying both symbol and string keys.
    def row_value(row, key)
      return nil unless row
      row[key.to_sym] || row[key.to_s] || row[key.to_s.upcase] || row[key.to_s.downcase]
    end

    def truthy?(val)
      %w[true 1 yes on].include?((val || "").to_s.strip.downcase)
    end

    def cache_key(sql, params)
      Digest::SHA256.hexdigest(sql + params.to_s)
    end

    def cache_get(key)
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
      @cache_mutex.synchronize do
        @query_cache[key] = {
          expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + @cache_ttl,
          value: value
        }
      end
    end

    def cache_invalidate
      @cache_mutex.synchronize { @query_cache.clear }
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
