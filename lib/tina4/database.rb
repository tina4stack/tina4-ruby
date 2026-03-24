# frozen_string_literal: true
require "json"
require "uri"
require "digest"

module Tina4
  class Database
    attr_reader :driver, :driver_name, :connected

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
      @pool_size = pool  # Reserved for future connection pooling (0 = single connection)
      @driver = create_driver
      @connected = false

      # Query cache — off by default, opt-in via TINA4_DB_CACHE=true
      @cache_enabled = truthy?(ENV["TINA4_DB_CACHE"])
      @cache_ttl = (ENV["TINA4_DB_CACHE_TTL"] || "30").to_i
      @query_cache = {}  # key => { expires_at:, value: }
      @cache_hits = 0
      @cache_misses = 0
      @cache_mutex = Mutex.new

      connect
    end

    def connect
      @driver.connect(@connection_string, username: @username, password: @password)
      @connected = true
      Tina4::Log.info("Database connected: #{@driver_name}")
    rescue => e
      Tina4::Log.error("Database connection failed: #{e.message}")
      @connected = false
    end

    def close
      @driver.close if @connected
      @connected = false
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

    def fetch(sql, params = [], limit: nil, skip: nil)
      effective_sql = sql
      if limit
        effective_sql = @driver.apply_limit(effective_sql, limit, skip || 0)
      end

      if @cache_enabled
        key = cache_key(effective_sql, params)
        cached = cache_get(key)
        if cached
          @cache_mutex.synchronize { @cache_hits += 1 }
          return cached
        end
        result = @driver.execute_query(effective_sql, params)
        result = Tina4::DatabaseResult.new(result, sql: effective_sql, db: self)
        cache_set(key, result)
        @cache_mutex.synchronize { @cache_misses += 1 }
        return result
      end

      rows = @driver.execute_query(effective_sql, params)
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

      # List of hashes — batch insert
      if data.is_a?(Array)
        return { success: true, affected_rows: 0 } if data.empty?
        keys = data.first.keys.map(&:to_s)
        placeholders = @driver.placeholders(keys.length)
        sql = "INSERT INTO #{table} (#{keys.join(', ')}) VALUES (#{placeholders})"
        params_list = data.map { |row| keys.map { |k| row[k.to_sym] || row[k] } }
        return execute_many(sql, params_list)
      end

      columns = data.keys.map(&:to_s)
      placeholders = @driver.placeholders(columns.length)
      sql = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders})"
      @driver.execute(sql, data.values)
      { success: true, last_id: @driver.last_insert_id }
    end

    def update(table, data, filter = {})
      cache_invalidate if @cache_enabled

      set_parts = data.keys.map { |k| "#{k} = #{@driver.placeholder}" }
      where_parts = filter.keys.map { |k| "#{k} = #{@driver.placeholder}" }
      sql = "UPDATE #{table} SET #{set_parts.join(', ')}"
      sql += " WHERE #{where_parts.join(' AND ')}" unless filter.empty?
      values = data.values + filter.values
      @driver.execute(sql, values)
      { success: true }
    end

    def delete(table, filter = {})
      cache_invalidate if @cache_enabled

      # List of hashes — delete each row
      if filter.is_a?(Array)
        filter.each { |row| delete(table, row) }
        return { success: true }
      end

      # String filter — raw WHERE clause
      if filter.is_a?(String)
        sql = "DELETE FROM #{table}"
        sql += " WHERE #{filter}" unless filter.empty?
        @driver.execute(sql)
        return { success: true }
      end

      # Hash filter — build WHERE from keys
      where_parts = filter.keys.map { |k| "#{k} = #{@driver.placeholder}" }
      sql = "DELETE FROM #{table}"
      sql += " WHERE #{where_parts.join(' AND ')}" unless filter.empty?
      @driver.execute(sql, filter.values)
      { success: true }
    end

    def execute(sql, params = [])
      cache_invalidate if @cache_enabled
      @driver.execute(sql, params)
    end

    def execute_many(sql, params_list = [])
      total_affected = 0
      params_list.each do |params|
        @driver.execute(sql, params)
        total_affected += 1
      end
      { success: true, affected_rows: total_affected }
    end

    def transaction
      @driver.begin_transaction
      yield self
      @driver.commit
    rescue => e
      @driver.rollback
      raise e
    end

    def tables
      @driver.tables
    end

    def columns(table_name)
      @driver.columns(table_name)
    end

    def table_exists?(table_name)
      tables.any? { |t| t.downcase == table_name.to_s.downcase }
    end

    private

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
