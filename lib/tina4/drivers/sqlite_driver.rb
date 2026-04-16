# frozen_string_literal: true

module Tina4
  module Drivers
    class SqliteDriver
      attr_reader :connection

      def connect(connection_string, username: nil, password: nil)
        require "sqlite3"
        db_path = self.class.resolve_path(connection_string)

        @connection = SQLite3::Database.new(db_path)
        @connection.results_as_hash = true
        @connection.execute("PRAGMA journal_mode=WAL")
        @connection.execute("PRAGMA foreign_keys=ON")
      end

      # Resolve a SQLite URL / path against the project root (cwd).
      #
      # Convention (matches tina4-python, tina4-php, tina4-nodejs):
      #   sqlite::memory:              → :memory:
      #   sqlite:///:memory:           → :memory:
      #   sqlite:///app.db             → {cwd}/app.db  (relative)
      #   sqlite:///data/app.db        → {cwd}/data/app.db  (relative; auto-mkdir under cwd)
      #   sqlite:////var/data/app.db   → /var/data/app.db  (absolute; no auto-mkdir)
      #   sqlite:///C:/Users/app.db    → C:/Users/app.db  (Windows absolute)
      #
      # Never mkdir outside cwd — that was the root cause of the
      # "Read-only file system: '/data'" crash on macOS.
      def self.resolve_path(connection_string)
        return ":memory:" if connection_string == "sqlite::memory:" || connection_string == "sqlite:///:memory:"

        # Strip the scheme + up to three slashes, preserving a potential fourth
        # slash (absolute) or drive letter.
        raw = connection_string.sub(/^sqlite:\/\/\//, "").sub(/^sqlite:\/\//, "").sub(/^sqlite:/, "")
        return ":memory:" if raw == ":memory:"

        is_windows_abs = raw.match?(/^[A-Za-z]:[\/\\]/)
        is_unix_abs    = raw.start_with?("/")

        if is_windows_abs || is_unix_abs
          # Absolute — trust the user; don't auto-mkdir outside cwd.
          raw
        else
          # Relative — resolve under cwd; auto-mkdir parent dir.
          resolved = File.join(Dir.pwd, raw)
          parent = File.dirname(resolved)
          require "fileutils"
          FileUtils.mkdir_p(parent) unless File.directory?(parent)
          resolved
        end
      end

      def close
        @connection&.close
      end

      def execute_query(sql, params = [])
        results = @connection.execute(sql, params)
        results.map { |row| symbolize_keys(row) }
      end

      def execute(sql, params = [])
        @connection.execute(sql, params)
      end

      def last_insert_id
        @connection.last_insert_row_id
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      def apply_limit(sql, limit, offset = 0)
        "#{sql} LIMIT #{limit} OFFSET #{offset}"
      end

      def begin_transaction
        @connection.execute("BEGIN TRANSACTION")
      end

      def commit
        @connection.execute("COMMIT")
      end

      def rollback
        @connection.execute("ROLLBACK")
      end

      def tables
        rows = execute_query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        rows.map { |r| r[:name] }
      end

      def columns(table_name)
        rows = execute_query("PRAGMA table_info(#{table_name})")
        rows.map do |r|
          {
            name: r[:name],
            type: r[:type],
            nullable: r[:notnull] == 0,
            default: r[:dflt_value],
            primary_key: r[:pk] == 1
          }
        end
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
