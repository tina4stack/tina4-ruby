# frozen_string_literal: true

module Tina4
  module Adapters
    class Sqlite3Adapter
      attr_reader :connection, :db_path

      def initialize(connection_string = nil)
        @connection = nil
        @db_path = nil
        @in_transaction = false
        connect(connection_string) if connection_string
      end

      def connect(connection_string)
        require "sqlite3"
        @db_path = self.class.resolve_path(connection_string)
        @connection = SQLite3::Database.new(@db_path)
        @connection.results_as_hash = true
        @connection.execute("PRAGMA journal_mode=WAL")
        @connection.execute("PRAGMA foreign_keys=ON")
        self
      end

      # Resolve a SQLite URL / path against the project root (cwd).
      # Convention matches Tina4::Drivers::SqliteDriver.resolve_path —
      # three slashes = relative, four = absolute, drive letter = Windows abs.
      def self.resolve_path(connection_string)
        return ":memory:" if connection_string == "sqlite::memory:" || connection_string == "sqlite:///:memory:"

        raw = connection_string.to_s
          .sub(/^sqlite3?:\/\/\//, "")
          .sub(/^sqlite3?:\/\//, "")
          .sub(/^sqlite3?:/, "")
        return ":memory:" if raw == ":memory:"

        is_windows_abs = raw.match?(/^[A-Za-z]:[\/\\]/)
        is_unix_abs    = raw.start_with?("/")

        if is_windows_abs || is_unix_abs
          raw
        else
          resolved = File.join(Dir.pwd, raw)
          parent = File.dirname(resolved)
          require "fileutils"
          FileUtils.mkdir_p(parent) unless File.directory?(parent)
          resolved
        end
      end

      def close
        @connection.close if @connection
        @connection = nil
      end

      def connected?
        !@connection.nil? && !@connection.closed?
      end

      # Execute a query and return rows as array of symbol-keyed hashes
      def query(sql, params = [])
        results = @connection.execute(sql, params)
        symbolize_rows(results)
      end

      # Paginated fetch
      def fetch(sql, limit = 100, offset = nil)
        effective_sql = sql
        if limit
          effective_sql = "#{sql} LIMIT #{limit}"
          effective_sql += " OFFSET #{offset}" if offset && offset > 0
        end
        query(effective_sql)
      end

      # Execute DDL or DML without returning rows
      def exec(sql, params = [])
        @connection.execute(sql, params)
        { affected_rows: @connection.changes }
      end

      # Check if a table exists
      def table_exists?(table)
        rows = query(
          "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
          [table.to_s]
        )
        !rows.empty?
      end

      # Get column metadata for a table
      def columns(table)
        query("PRAGMA table_info(#{table})").map do |r|
          {
            name: r[:name],
            type: r[:type],
            nullable: r[:notnull] == 0,
            default: r[:dflt_value],
            primary_key: r[:pk] == 1
          }
        end
      end

      # List all user tables
      def tables
        rows = query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        rows.map { |r| r[:name] }
      end

      # Get last inserted row id
      def last_insert_id
        @connection.last_insert_row_id
      end

      # Transaction support
      def begin_transaction
        return if @in_transaction
        @connection.execute("BEGIN TRANSACTION")
        @in_transaction = true
      end

      def commit
        return unless @in_transaction
        @connection.execute("COMMIT")
        @in_transaction = false
      end

      def rollback
        return unless @in_transaction
        @connection.execute("ROLLBACK")
        @in_transaction = false
      end

      def transaction
        begin_transaction
        yield self
        commit
      rescue => e
        rollback
        raise e
      end

      # Convenience: placeholder for parameterized queries
      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      def apply_limit(sql, limit, offset = 0)
        "#{sql} LIMIT #{limit} OFFSET #{offset}"
      end

      private

      # Symbolize a whole result set's keys, computing the mapping ONCE per query
      # rather than per cell. See the matching helper in drivers/sqlite_driver.rb
      # for the rationale: the per-row form ran k.to_s.to_sym for every cell, so a
      # 5,000-row x 6-column fetch did 30,000 conversions for 6 distinct keys. The
      # is_a? guard still drops any positional Integer keys older gems emit.
      def symbolize_rows(rows)
        return rows if rows.empty?

        str_keys = rows.first.keys.select { |k| k.is_a?(String) || k.is_a?(Symbol) }
        sym_keys = str_keys.map(&:to_sym)
        count = str_keys.length
        rows.map do |row|
          out = {}
          i = 0
          while i < count
            out[sym_keys[i]] = row[str_keys[i]]
            i += 1
          end
          out
        end
      end

      def symbolize_keys(hash)
        symbolize_rows([hash]).first
      end
    end
  end
end
