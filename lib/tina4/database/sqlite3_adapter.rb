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
        @db_path = connection_string.to_s.sub(/^sqlite3?:\/\//, "").sub(/^sqlite3?:/, "")
        @connection = SQLite3::Database.new(@db_path)
        @connection.results_as_hash = true
        @connection.execute("PRAGMA journal_mode=WAL")
        @connection.execute("PRAGMA foreign_keys=ON")
        self
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
        results.map { |row| symbolize_keys(row) }
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

      def symbolize_keys(hash)
        hash.each_with_object({}) do |(k, v), h|
          h[k.to_s.to_sym] = v if k.is_a?(String) || k.is_a?(Symbol)
        end
      end
    end
  end
end
