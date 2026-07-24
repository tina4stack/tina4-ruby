# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class SqliteDriver
      include SchemaSplit
      attr_reader :connection

      # Process-wide write lock — parity with Python's SQLiteAdapter._write_lock.
      #
      # DB-contract B (v3.13.37): get_next_id's atomic sequence-table increment
      # serialises the ENTIRE ensure-table + seed + increment op under this lock
      # so concurrent callers can never read the same counter and return a
      # duplicate id. Class-level (one per process) so every Database instance /
      # pooled connection contends on the same lock for the same SQLite file.
      @write_lock = Mutex.new
      class << self
        attr_reader :write_lock
      end

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
        results = @connection.execute(sql, coerce_params(params))
        symbolize_rows(results)
      end

      def execute(sql, params = [])
        @connection.execute(sql, coerce_params(params))
      end

      # Coerce Ruby values to types the sqlite3 gem can bind. The gem RAISES
      # ("can't prepare TrueClass") on a raw boolean, so map true/false to 1/0 —
      # SQLite stores booleans as INTEGER 0/1. Time/DateTime serialise to ISO-8601
      # so a datetime field round-trips. Parity with the Python/PHP/Node adapters,
      # which coerce booleans at the same bind boundary.
      def coerce_params(params)
        return params unless params.is_a?(Array)

        params.map do |value|
          case value
          when true then 1
          when false then 0
          when Time, DateTime then value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
          else value
          end
        end
      end

      def last_insert_id
        @connection.last_insert_row_id
      end

      # Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
      # Feeds Database#insert/update/delete's DatabaseResult.affected_rows (parity
      # with the Python master + PHP, which surface affectedRows on writes).
      def affected_rows
        @connection.changes
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

      # Committing/rolling back when no transaction is open is a harmless no-op,
      # NOT a failure — SQLite raises "cannot commit - no transaction is active"
      # in that case. Swallow ONLY that specific condition so a stray commit
      # (e.g. after an autocommit standalone write) doesn't poison the
      # Database-level @last_error. A genuine commit/rollback failure (disk I/O,
      # constraint deferral, locked DB) still propagates so Database#commit can
      # FAIL LOUD per the DB-contract.
      def commit
        @connection.execute("COMMIT")
      rescue SQLite3::SQLException => e
        raise unless e.message.to_s.downcase.include?("no transaction is active")
      end

      def rollback
        @connection.execute("ROLLBACK")
      rescue SQLite3::SQLException => e
        raise unless e.message.to_s.downcase.include?("no transaction is active")
      end

      # v3.13.14 (#48): a SQLite "schema" is an ATTACH alias ("extra.widget").
      # Query that database's own sqlite_master when the prefix is a plain
      # identifier; otherwise treat the whole string as a bare table name.
      def table_exists?(name)
        schema, tbl = split_schema(name)
        master = schema && identifier?(schema) ? "#{schema}.sqlite_master" : "sqlite_master"
        rows = execute_query("SELECT 1 FROM #{master} WHERE type='table' AND name=?", [tbl])
        !rows.empty?
      end

      def tables
        rows = execute_query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        rows.map { |r| r[:name] }
      end

      def columns(table_name)
        # v3.13.14 (#48): PRAGMA accepts an attached-schema prefix.
        schema, tbl = split_schema(table_name)
        pragma = schema && identifier?(schema) && identifier?(tbl) ? "#{schema}.table_info(#{tbl})" : "table_info(#{table_name})"
        rows = execute_query("PRAGMA #{pragma}")
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

      # A safe-to-interpolate SQL identifier (no quoting/escaping needed).
      def identifier?(str)
        str.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      end

      # Symbolize the keys of a whole result set, computing the key mapping ONCE.
      #
      # results_as_hash=true hands back string-keyed hashes; every row of a query
      # has the same columns, so the string->symbol conversion is identical for
      # every row. The old code called `symbolize_keys` per row, which ran
      # `k.to_s.to_sym` and an `is_a?` guard PER CELL: a 5,000-row x 6-column
      # fetch did 30,000 conversions for 6 distinct keys and made Tina4 the
      # slowest of the four frameworks at bulk reads (Select ALL 5,000 rows:
      # 10.16ms vs raw sqlite3 2.56ms). Hoisting the mapping out of the loop
      # roughly halves the hydration cost with byte-identical output.
      #
      # The is_a?(String|Symbol) guard is preserved: older sqlite3 gems put
      # positional Integer keys in the hash alongside the string names, and those
      # must still be dropped.
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

      # Single-hash convenience kept for any external caller; delegates to the
      # batch path so there is one implementation of the mapping rule.
      def symbolize_keys(hash)
        symbolize_rows([hash]).first
      end
    end
  end
end
