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
    SPATIAL_ENGINES = %w[postgres postgresql].freeze
    SPATIAL_IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/

    class << self
      def require_spatial(engine, feature)
        name = engine.to_s.downcase
        return name if SPATIAL_ENGINES.include?(name)
        raise SpatialNotSupportedError,
              "#{feature} is not supported on the '#{name.empty? ? 'unknown' : name}' database engine. " \
              "Tina4 GIS support is PostGIS-first: use PostgreSQL with CREATE EXTENSION postgis. " \
              "Tina4 will not replace a spatial query with an approximate coordinate query."
      end

      def spatial_identifier(name, what = "column")
        text = name.to_s
        raise ArgumentError, "Spatial #{what} is not a valid SQL identifier: #{text}" unless SPATIAL_IDENTIFIER.match?(text)
        text
      end

      def point_column_type(engine, srid = Point::DEFAULT_SRID)
        require_spatial(engine, "PointField")
        "geography(Point,#{Integer(srid)})"
      end

      def spatial_index(engine, table, column)
        require_spatial(engine, "spatial index creation")
        table = spatial_identifier(table, "table")
        column = spatial_identifier(column)
        "CREATE INDEX IF NOT EXISTS #{table.tr('.', '_')}_#{column}_gist ON #{table} USING GIST (#{column})"
      end

      def point_literal(engine, srid = Point::DEFAULT_SRID)
        require_spatial(engine, "spatial predicates")
        "ST_SetSRID(ST_MakePoint(?, ?), #{Integer(srid)})::geography"
      end

      def within_distance(engine, column, srid = Point::DEFAULT_SRID)
        "ST_DWithin(#{spatial_identifier(column)}, #{point_literal(engine, srid)}, ?)"
      end

      def distance(engine, column, srid = Point::DEFAULT_SRID)
        "ST_Distance(#{spatial_identifier(column)}, #{point_literal(engine, srid)})"
      end

      def distance_as(engine, column, alias_name, srid = Point::DEFAULT_SRID)
        "#{distance(engine, column, srid)} AS #{spatial_identifier(alias_name, 'result alias')}"
      end

      def geometry_literal(engine, form = :ewkt, srid = Point::DEFAULT_SRID)
        require_spatial(engine, "spatial predicates")
        return "ST_GeogFromText(?)" if form.to_sym == :ewkt
        return "ST_SetSRID(ST_GeomFromGeoJSON(?), #{Integer(srid)})::geography" if form.to_sym == :geojson
        raise ArgumentError, "Unsupported spatial geometry form: #{form}"
      end

      def intersects(engine, column, form = :ewkt, srid = Point::DEFAULT_SRID)
        "ST_Intersects(#{spatial_identifier(column)}, #{geometry_literal(engine, form, srid)})"
      end

      def bbox(engine, column, srid = Point::DEFAULT_SRID)
        require_spatial(engine, "bbox")
        "ST_Intersects(#{spatial_identifier(column)}, ST_MakeEnvelope(?, ?, ?, ?, #{Integer(srid)})::geography)"
      end

      # ── Literal-safe rewriting ────────────────────────────────────
      #
      # A dialect rewrite (|| -> CONCAT, TRUE -> 1, ILIKE -> LOWER LIKE) must NEVER
      # touch text inside a string literal, a quoted identifier or a comment: a
      # column value of 'a||b', a label 'TRUE', or a LIKE pattern that mentions
      # ILIKE is DATA, not SQL. Each transform masks every literal/identifier/
      # comment to an opaque token, rewrites the masked SQL, then restores the
      # tokens, so the rewrite only ever sees real SQL structure.
      #
      # NOTE on the removed methods (SQLTRANS-DEC-02): +limit_to_rows+,
      # +limit_to_top+ and +placeholder_style+ were deleted here. Ruby's DRIVERS
      # own pagination and placeholders by design and do it correctly per engine
      # (Firebird +SELECT FIRST/SKIP+, MSSQL +OFFSET ... FETCH+, Postgres +$1+),
      # whereas these translator helpers emitted a DIFFERENT and inferior shape
      # (MSSQL +TOP+, Firebird +ROWS x TO y+) that nothing called. Keeping a dead
      # public method that also disagrees with the live driver is a footgun, so
      # they are gone. concat/bool/ilike stay (they fill a real gap - the drivers
      # do not translate them) and are now WIRED into the MySQL driver.

      # Replace string literals, quoted identifiers and comments with opaque
      # "\x00N\x00" tokens. Returns [masked_sql, literals]; doubled-quote escapes
      # ('' "" ``) are handled so an embedded quote never ends the span early.
      def mask_literals(sql)
        literals = []
        out = +""
        i = 0
        n = sql.length
        while i < n
          ch = sql[i]
          nxt = sql[i + 1]
          if ch == "'" || ch == '"' || ch == "`"
            start = i
            i += 1
            while i < n
              if sql[i] == ch
                if sql[i + 1] == ch
                  i += 2
                  next
                end
                i += 1
                break
              end
              i += 1
            end
            out << "\x00#{literals.length}\x00"
            literals << sql[start...i]
            next
          end
          if ch == "-" && nxt == "-"
            start = i
            i += 1 while i < n && sql[i] != "\n"
            out << "\x00#{literals.length}\x00"
            literals << sql[start...i]
            next
          end
          if ch == "/" && nxt == "*"
            start = i
            i += 2
            i += 1 while i < n && !(sql[i] == "*" && sql[i + 1] == "/")
            i = [i + 2, n].min
            out << "\x00#{literals.length}\x00"
            literals << sql[start...i]
            next
          end
          out << ch
          i += 1
        end
        [out, literals]
      end

      # Inverse of #mask_literals.
      def restore_literals(masked, literals)
        masked.gsub(/\x00(\d+)\x00/) { literals[::Regexp.last_match(1).to_i] }
      end

      # Convert || string concatenation to CONCAT() for MySQL/MSSQL. Rewrites ONLY
      # || operators joining expression operands OUTSIDE any string literal or
      # comment, and only the operand chain - never the whole statement.
      #
      #   SELECT a || b FROM t   =>  SELECT CONCAT(a, b) FROM t
      #   WHERE data = 'a||b'    =>  WHERE data = 'a||b'   (literal untouched)
      #
      # @param sql [String]
      # @return [String]
      def concat_pipes_to_func(sql)
        return sql unless sql.include?("||")

        masked, literals = mask_literals(sql)
        return sql unless masked.include?("||")

        chain = /#{SQLTranslator::PRIMARY}(?:\s*\|\|\s*#{SQLTranslator::PRIMARY})+/
        rewritten = masked.gsub(chain) do |m|
          "CONCAT(#{m.split(/\s*\|\|\s*/).join(', ')})"
        end
        restore_literals(rewritten, literals)
      end

      # Convert a bare TRUE/FALSE to 1/0 for engines without a boolean type. A
      # TRUE/FALSE INSIDE a string literal is data and is left untouched.
      #
      # @param sql [String]
      # @return [String]
      def boolean_to_int(sql)
        return sql unless sql.match?(/\b(?:TRUE|FALSE)\b/i)

        masked, literals = mask_literals(sql)
        masked = masked.gsub(/\bTRUE\b/i, "1").gsub(/\bFALSE\b/i, "0")
        restore_literals(masked, literals)
      end

      # Convert +col ILIKE pattern+ to +LOWER(col) LIKE LOWER(pattern)+ for engines
      # without ILIKE. The pattern operand is captured whole (a multi-word
      # '%two words%' survives), and an ILIKE INSIDE a string literal is untouched.
      #
      # @param sql [String]
      # @return [String]
      def ilike_to_like(sql)
        return sql unless sql =~ /ilike/i

        masked, literals = mask_literals(sql)
        pattern = /(#{SQLTranslator::PRIMARY})\s+ILIKE\s+(#{SQLTranslator::PRIMARY})/i
        rewritten = masked.gsub(pattern) do
          "LOWER(#{::Regexp.last_match(1)}) LIKE LOWER(#{::Regexp.last_match(2)})"
        end
        restore_literals(rewritten, literals)
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
          # BIGINT PRIMARY KEY AUTOINCREMENT -> BIGSERIAL (a real 64-bit sequence);
          # INTEGER -> SERIAL. A plain BIGINT with the keyword merely stripped has
          # no sequence and cannot auto-increment.
          sql
            .gsub(/\bBIGINT\s+PRIMARY\s+KEY\s+AUTOINCREMENT\b/i, "BIGSERIAL PRIMARY KEY")
            .gsub(/\bINTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT\b/i, "SERIAL PRIMARY KEY")
            .gsub(/\s*\bAUTOINCREMENT\b/i, "")
        when "mssql"
          sql.gsub(/AUTOINCREMENT/i, "IDENTITY(1,1)")
        when "firebird"
          sql.gsub(/\s*AUTOINCREMENT\b/i, "")
        else
          sql
        end
      end

      # NOTE (SQLTRANS-DEC-02): +placeholder_style+ was removed - every Ruby
      # driver owns its own placeholder shape (+?+ for MySQL/SQLite/MSSQL/Firebird,
      # +$1+ for Postgres), so this helper had zero callers and disagreed with the
      # live drivers. The cache KEY helper +query_key+ was also removed here: it
      # duplicated the live +.query_key+ class method the ORM cache path (defined
      # in lib/tina4/cache.rb, per spec/docs_truth_spec.rb's D12 lock-in that this
      # file stays free of that class's name) actually uses. One source, not two.

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

    # A concat/ilike operand: a masked literal-or-identifier token, a simple
    # function call, a (qualified) identifier, a placeholder, or a number. The
    # function-call args exclude +|+ so a nested +||+ never splits the chain.
    PRIMARY = '(?:\x00\d+\x00|[A-Za-z_][\w$]*\s*\([^()|]*\)|[A-Za-z_][\w$]*(?:\.[A-Za-z_][\w$]*)*|:[A-Za-z_]\w*|\$\d+|\?|%s|\d+(?:\.\d+)?)'

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
