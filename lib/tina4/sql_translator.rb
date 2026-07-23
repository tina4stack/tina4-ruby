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
    end
  end
end
