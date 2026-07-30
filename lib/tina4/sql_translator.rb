# frozen_string_literal: true

require "digest"
require_relative "cache"

module Tina4
  # Cross-engine SQL translator.
  #
  # Each database adapter calls the rules it needs. Rules are composable
  # and stateless -- just string transforms.
  #
  # Also includes query caching with TTL support.
  #
  # Usage:
  #   translated = Tina4::SQLTranslator.limit_to_rows("SELECT * FROM users LIMIT 10 OFFSET 5")
  #   # => "SELECT * FROM users ROWS 6 TO 15"
  #
  class SQLTranslator
    class << self
      # Convert LIMIT/OFFSET to Firebird ROWS...TO syntax.
      #
      # LIMIT 10 OFFSET 5  =>  ROWS 6 TO 15
      # LIMIT 10           =>  ROWS 1 TO 10
      #
      # @param sql [String]
      # @return [String]
      def limit_to_rows(sql)
        # Try LIMIT X OFFSET Y first
        if (m = sql.match(/\bLIMIT\s+(\d+)\s+OFFSET\s+(\d+)\s*$/i))
          limit = m[1].to_i
          offset = m[2].to_i
          start_row = offset + 1
          end_row = offset + limit
          return sql[0...m.begin(0)] + "ROWS #{start_row} TO #{end_row}"
        end

        # Then try LIMIT X only
        if (m = sql.match(/\bLIMIT\s+(\d+)\s*$/i))
          limit = m[1].to_i
          return sql[0...m.begin(0)] + "ROWS 1 TO #{limit}"
        end

        sql
      end

      # Convert LIMIT to MSSQL TOP syntax.
      #
      # SELECT ... LIMIT 10  =>  SELECT TOP 10 ...
      # OFFSET queries are left unchanged (not supported by TOP).
      #
      # @param sql [String]
      # @return [String]
      def limit_to_top(sql)
        if (m = sql.match(/\bLIMIT\s+(\d+)\s*$/i)) && !sql.match?(/\bOFFSET\b/i)
          limit = m[1].to_i
          body = sql[0...m.begin(0)].strip
          return body.sub(/^(SELECT)\b/i, "\\1 TOP #{limit}")
        end

        sql
      end

      # Convert || concatenation to CONCAT() for MySQL/MSSQL.
      #
      # 'a' || 'b' || 'c'  =>  CONCAT('a', 'b', 'c')
      #
      # @param sql [String]
      # @return [String]
      def concat_pipes_to_func(sql)
        return sql unless sql.include?("||")

        parts = sql.split("||")
        if parts.length > 1
          "CONCAT(#{parts.map(&:strip).join(', ')})"
        else
          sql
        end
      end

      # Convert TRUE/FALSE to 1/0 for engines without boolean type.
      #
      # @param sql [String]
      # @return [String]
      def boolean_to_int(sql)
        sql.gsub(/\bTRUE\b/i, "1").gsub(/\bFALSE\b/i, "0")
      end

      # Convert ILIKE to LOWER() LIKE LOWER() for engines without ILIKE.
      #
      # @param sql [String]
      # @return [String]
      def ilike_to_like(sql)
        sql.gsub(/(\S+)\s+ILIKE\s+(\S+)/i) do
          col = ::Regexp.last_match(1).strip
          val = ::Regexp.last_match(2).strip
          "LOWER(#{col}) LIKE LOWER(#{val})"
        end
      end

      # Translate AUTOINCREMENT across engines in DDL.
      #
      # @param sql [String]
      # @param engine [String] one of: mysql, postgresql, mssql, firebird, sqlite
      # @return [String]
      def auto_increment_syntax(sql, engine)
        case engine
        when "mysql"
          sql.gsub("AUTOINCREMENT", "AUTO_INCREMENT")
        when "postgresql"
          sql.gsub(/INTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT/i, "SERIAL PRIMARY KEY")
        when "mssql"
          sql.gsub(/AUTOINCREMENT/i, "IDENTITY(1,1)")
        when "firebird"
          sql.gsub(/\s*AUTOINCREMENT\b/i, "")
        else
          sql
        end
      end

      # Convert ? placeholders to engine-specific style.
      #
      # ?  =>  %s       (MySQL, PostgreSQL)
      # ?  =>  :1, :2   (Oracle, Firebird)
      #
      # @param sql [String]
      # @param style [String] target placeholder style: "%s" or ":"
      # @return [String]
      def placeholder_style(sql, style)
        case style
        when "%s"
          sql.gsub("?", "%s")
        when ":"
          count = 0
          sql.chars.map do |ch|
            if ch == "?"
              count += 1
              ":#{count}"
            else
              ch
            end
          end.join
        else
          sql
        end
      end

      # Generate a cache key for a query and its parameters.
      #
      # @param sql [String]
      # @param params [Array, nil]
      # @return [String]
      def query_key(sql, params = nil)
        raw = params ? "#{sql}|#{params.inspect}" : sql
        "query:#{Digest::SHA256.hexdigest(raw)}"
      end

      # Collapse a row-at-a-time INSERT batch into chunked multi-row VALUES.
      #
      # A batch that loops one INSERT per row pays a full network round-trip per
      # row, and the round-trip - not SQL building - is the entire cost of a
      # batch write. Measured over 500 rows: PostgreSQL 9848ms row-at-a-time
      # against 15.8ms as a single multi-row statement (625x), MySQL 216x,
      # MSSQL 121x.
      #
      # PURE: no I/O and no engine contact, so the chunking rules are checkable
      # without a database. The live-engine runners prove the rows land.
      #
      # @param sql [String] the single-row INSERT the batch would loop
      # @param params_list [Array<Array>] one entry per row
      # @param engine [String] engine name as the driver reports it (aliases ok)
      # @return [Array<Array(String, Array)>] statements to run INSTEAD of the
      #   loop, or an EMPTY array meaning "not collapsible - keep looping",
      #   which is always correct.
      # Normalise a collapsed batch's last id to the LAST row's id.
      #
      # A row-at-a-time batch reports the last row's id simply because the last
      # statement inserted the last row. Collapsing rows into one statement
      # changes that on any engine that reports the FIRST generated id, so this
      # restores the contract instead of quietly redefining it.
      #
      # Verified live, not assumed: a 3-row insert into a fresh MySQL table
      # reports 1 while MAX(id) is 3. SQLite, PostgreSQL and MSSQL already
      # report the last and are left alone. The ids in one statement are
      # consecutive, so the last is +first + rows - 1+.
      def batch_last_id(reported_id, rows_in_chunk, engine)
        name = engine.to_s.downcase
        name = ENGINE_ALIASES.fetch(name, name)
        return reported_id unless FIRST_ID_ENGINES.include?(name)
        return reported_id unless reported_id.is_a?(Integer) || reported_id.to_s.match?(/\A-?\d+\z/)

        reported_id.to_i + [rows_in_chunk.to_i, 1].max - 1
      end

      def build_batch_inserts(sql, params_list, engine)
        rows = params_list || []
        return [] if rows.length < 2

        name = engine.to_s.downcase
        name = ENGINE_ALIASES.fetch(name, name)
        cap = MAX_BIND_PARAMS.fetch(name, 0)
        # Firebird has no multi-row VALUES syntax; ODBC's real ceiling depends on
        # the driver behind it. Emitting SQL the engine cannot parse to save a
        # round-trip is not a trade worth making.
        return [] if cap <= 0

        upper = sql.upcase
        # A collapsed statement returns N rows where the caller expects one, and
        # conflict arbitration changes once rows share a statement.
        return [] if upper.include?("RETURNING") ||
                     upper.include?("ON CONFLICT") ||
                     upper.include?("ON DUPLICATE KEY")

        match = INSERT_VALUES.match(sql)
        return [] if match.nil?

        # Every slot must be a bare placeholder. `now()` repeated per row inside
        # one statement is not the same write as `now()` evaluated per statement.
        slots = match[1].split(",").map(&:strip)
        return [] if slots.empty? || slots.any? { |slot| slot != "?" }

        columns = slots.length
        return [] if rows.any? { |params| params.length != columns }

        chunk_rows = [1, cap / columns].max
        return [] if chunk_rows < 2

        head = sql[0...(match.begin(1) - 1)].rstrip
        one_row = "(#{Array.new(columns, '?').join(', ')})"

        rows.each_slice(chunk_rows).map do |chunk|
          ["#{head} #{Array.new(chunk.length, one_row).join(', ')}", chunk.flatten(1)]
        end
      end
    end

    # Hard per-statement bind-parameter ceiling per engine. 0 = never collapse.
    # Sourced from spec/fixtures/batch_write_contract.json, byte-identical in
    # all four frameworks.
    MAX_BIND_PARAMS = {
      "sqlite" => 999,
      "postgres" => 65_535,
      "mysql" => 65_535,
      "mssql" => 2_100,
      "firebird" => 0,
      "odbc" => 0,
      "mongodb" => 0
    }.freeze

    # The four frameworks do not agree on what an engine calls itself - Python
    # and PHP report "postgresql", Ruby and Node report "postgres". Without
    # normalising, the cap lookup misses and the collapse silently does nothing
    # on the engine with the largest win.
    ENGINE_ALIASES = {
      "postgresql" => "postgres",
      "pgsql" => "postgres",
      "sqlite3" => "sqlite",
      "sqlserver" => "mssql",
      "sqlsrv" => "mssql",
      "mariadb" => "mysql"
    }.freeze

    INSERT_VALUES = /\A\s*INSERT\s+INTO\s+.+?\s+VALUES\s*\(([^()]*)\)\s*\z/im

    # Engines whose last_insert_id reports the FIRST generated id of a multi-row
    # INSERT rather than the last. Verified live against MySQL.
    FIRST_ID_ENGINES = %w[mysql].freeze
  end
end
