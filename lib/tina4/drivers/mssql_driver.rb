# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class MssqlDriver
      # Postgres, MySQL, MSSQL and ODBC all REQUIRE a name for a derived
      # table, so the COUNT probe in Database#count_probe wraps as
      # `FROM (sql) AS _count_query`. SQLite and Firebird do not define
      # this and get no alias - Firebird rejects `AS` in that position.
      def count_subquery_alias
        "_count_query"
      end

      include Tina4::DatabaseAdapter
      include SchemaSplit
      attr_reader :connection

      def connect(connection_string, username: nil, password: nil)
        begin
          require "tiny_tds"
        rescue LoadError
          raise LoadError,
                "The 'tiny_tds' gem is required for MSSQL connections. Install one of:\n" \
                "    bundle add tiny_tds     # if your project uses Bundler\n" \
                "    gem install tiny_tds    # bare driver"
        end
        uri = parse_connection(connection_string)
        options = {
          host: uri[:host],
          port: uri[:port] || 1433,
          username: username || uri[:username],
          password: password || uri[:password],
          database: uri[:database]
        }
        # FreeTDS's OWN login_timeout, in whole seconds - the bound on reaching
        # and logging in to the server. MEASURED: 3.01s ("TDS server connection
        # timed out") against a TCPServer that accepts and never replies, where
        # the same connect with no bound sat past 20s and needed SIGKILL. The
        # separate :timeout (per-query, tiny_tds default 5s) is untouched.
        seconds = Tina4::DatabaseAdapter.connect_timeout_whole_seconds
        options[:login_timeout] = seconds if seconds
        Tina4::DatabaseAdapter.bounding_connect(options[:host], options[:port]) do
          @connection = TinyTds::Client.new(**options)
        end
      end

      def close
        @connection&.close
      end

      def execute_query(sql, params = [])
        effective_sql = interpolate_params(sql, params)
        result = @connection.execute(effective_sql)
        rows = result.each(symbolize_keys: true).to_a
        result.cancel if result.respond_to?(:cancel)
        rows
      end

      def execute(sql, params = [])
        effective_sql = interpolate_params(sql, params)

        # Capture the generated IDENTITY AT WRITE TIME — mirror of the Python
        # master (mssql.py execute(): SELECT SCOPE_IDENTITY() runs straight after
        # the INSERT on the SAME cursor). tiny_tds runs each #execute as its OWN
        # T-SQL batch, and SCOPE_IDENTITY() is batch-scoped: read in a separate
        # later batch it is always NULL — which is why both insert(...).last_id
        # and db.get_last_id came back nil (issue #262). So for an INSERT we run
        # the INSERT and SELECT SCOPE_IDENTITY() in ONE batch (a single
        # @connection.execute), read the id from the SAME batch, and cache it.
        if sql.to_s.lstrip[0, 6].casecmp?("INSERT")
          # @@ROWCOUNT rides along in the SAME batch for the same reason
          # SCOPE_IDENTITY() does: it reports the row count of the immediately
          # preceding statement (the INSERT), and read in a later batch it would
          # describe something else entirely.
          result = @connection.execute(
            "#{effective_sql}; SELECT SCOPE_IDENTITY() AS id, @@ROWCOUNT AS affected"
          )
          rows = result.each(symbolize_keys: true).to_a
          result.cancel if result.respond_to?(:cancel)
          row = rows.last
          @last_insert_id = row && row[:id] ? row[:id].to_i : nil
          @affected_rows = row && row[:affected] ? row[:affected].to_i : 1
          return true
        end

        result = @connection.execute(effective_sql)
        # TinyTds::Result#do runs the statement and RETURNS the number of rows
        # it affected. That count was computed and thrown away: the driver
        # exposed no #affected_rows, so Database#write_affected fell through to
        # its default of 0 and an UPDATE that really changed a row reported
        # affected_rows = 0 — indistinguishable from "matched nothing".
        @affected_rows = result.do
      end

      def last_insert_id
        @last_insert_id
      end

      # Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
      # Parity with SQLite (connection.changes), MySQL (stmt.affected_rows),
      # PostgreSQL (cmd_tuples) and the Python master (cursor.rowcount).
      def affected_rows
        @affected_rows.to_i
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      def apply_limit(sql, limit, offset = 0)
        # SQL Server's OFFSET/FETCH paging REQUIRES an ORDER BY. A query with
        # none (a fetch_one aggregate like "SELECT COUNT(*)" / "SELECT MAX(id)",
        # or any unordered SELECT given a limit) otherwise raises "Incorrect
        # syntax near '0'" at the OFFSET. Append a no-op ORDER BY (SELECT NULL)
        # when the SQL has no ORDER BY, mirroring the Python master (mssql.py).
        #
        # Both appends go on a NEW LINE: inline they land inside a trailing
        # `-- comment` and are silently swallowed (see the note on
        # Drivers::SqliteDriver#apply_limit). The ORDER BY probe reads the
        # SCRUBBED SQL for the same reason — an ORDER BY that only appears
        # inside a comment or a string literal is not an ORDER BY.
        has_order = Tina4::Database.scrub_sql_text(sql) =~ /\bORDER\s+BY\b/i
        ordered = has_order ? sql : "#{sql}\nORDER BY (SELECT NULL)"
        "#{ordered}\nOFFSET #{offset} ROWS FETCH NEXT #{limit} ROWS ONLY"
      end

      def begin_transaction
        @connection.execute("BEGIN TRANSACTION").do
      end

      def commit
        @connection.execute("COMMIT").do
      end

      def rollback
        @connection.execute("ROLLBACK").do
      end

      # v3.13.14 (#48): honour a schema-qualified name ("dbo.widget"); a bare
      # name matches in any schema (NULL guard skips the schema filter).
      def table_exists?(name)
        schema, tbl = split_schema(name)
        sql = "SELECT 1 FROM INFORMATION_SCHEMA.TABLES " \
              "WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_NAME = ? " \
              "AND (? IS NULL OR TABLE_SCHEMA = ?)"
        rows = execute_query(sql, [tbl, schema, schema])
        !rows.empty?
      end

      # ADR-0044 required adapter capability.
      def get_database_type
        'mssql'
      end

      def tables
        rows = execute_query("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'")
        rows.map { |r| r[:TABLE_NAME] || r[:table_name] }
      end

      def columns(table_name)
        # v3.13.14 (#48): honour a schema-qualified name; bare names match any schema.
        schema, tbl = split_schema(table_name)
        # Same hole PostgreSQL had: :primary_key hardcoded false meant
        # Database#primary_key introspected NOTHING on SQL Server, so the
        # feature-4 filterless-write guard rejected every PK-keyed update.
        # Ported from the Python master; the subquery yields every column of the
        # PK, so a COMPOSITE key reports true on each of its columns.
        sql = <<~SQL
          SELECT c.COLUMN_NAME, c.DATA_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT,
                 CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS is_primary
          FROM INFORMATION_SCHEMA.COLUMNS c
          LEFT JOIN (
            SELECT ku.COLUMN_NAME
            FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
            JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE ku
              ON tc.CONSTRAINT_NAME = ku.CONSTRAINT_NAME
            WHERE tc.TABLE_NAME = ? AND (? IS NULL OR tc.TABLE_SCHEMA = ?)
              AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
          ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
          WHERE c.TABLE_NAME = ? AND (? IS NULL OR c.TABLE_SCHEMA = ?)
          ORDER BY c.ORDINAL_POSITION
        SQL
        rows = execute_query(sql, [tbl, schema, schema, tbl, schema, schema])
        rows.map do |r|
          {
            name: r[:COLUMN_NAME] || r[:column_name],
            type: r[:DATA_TYPE] || r[:data_type],
            nullable: (r[:IS_NULLABLE] || r[:is_nullable]) == "YES",
            default: r[:COLUMN_DEFAULT] || r[:column_default],
            primary_key: (r[:is_primary] || r[:IS_PRIMARY]).to_i == 1
          }
        end
      end

      private

      def parse_connection(str)
        # Format: mssql://user:pass@host:port/database
        match = str.match(%r{(?:mssql|sqlserver)://(?:(\w+):([^@]+)@)?([^:/]+)(?::(\d+))?/(.+)})
        if match
          { username: match[1], password: match[2], host: match[3],
            port: match[4]&.to_i, database: match[5] }
        else
          { host: "localhost", database: str }
        end
      end

      def interpolate_params(sql, params)
        return sql if params.empty?
        result = sql.dup
        params.each do |param|
          escaped =
            if param.nil?
              "NULL"
            elsif param == true
              # SQL Server has no boolean literal — BIT stores 0/1. A raw `true`
              # would interpolate as the bareword `true` ("Invalid column name
              # 'true'"). Coerce at the bind boundary, parity with the SQLite
              # driver's coerce_params and the Python/PHP/Node bind contract.
              "1"
            elsif param == false
              "0"
            elsif param.is_a?(Time) || param.is_a?(DateTime)
              "'#{(param.respond_to?(:iso8601) ? param.iso8601 : param.to_s).gsub("'", "''")}'"
            elsif param.is_a?(String)
              interpolate_string(param)
            elsif param.is_a?(Integer)
              param.to_s
            elsif param.is_a?(Float)
              # A finite Float is a valid numeric literal; NaN/Infinity are not
              # representable in T-SQL and would stringify to a bareword.
              raise ArgumentError, "MssqlDriver cannot bind a non-finite Float (#{param})" unless param.finite?

              param.to_s
            elsif param.is_a?(Numeric)
              # BigDecimal / Rational -> a plain decimal literal.
              param.to_s
            else
              # MSSQL-INTERP-RUBY: the old `else param.to_s` emitted a BAREWORD for
              # any unrecognised type (a Symbol became `WHERE x = active`, invalid
              # or unintended SQL - a breakage / injection vector). Refuse it loudly
              # instead of splicing an arbitrary object's #to_s into the statement.
              raise ArgumentError,
                    "MssqlDriver cannot safely bind a #{param.class} parameter to MSSQL " \
                    "(#{param.inspect}); pass nil, true/false, a Time, a String " \
                    "(text, or ASCII-8BIT bytes), or a Numeric - never a bareword"
            end
          result = result.sub("?", escaped)
        end
        result
      end

      # Bind a String parameter. ASCII-8BIT (binary) bytes become a T-SQL
      # varbinary literal `0x...`, NOT a quoted string: FreeTDS (tiny_tds) cannot
      # carry raw binary through a quoted literal - a NUL byte breaks the TDS
      # stream / truncates the value - whereas a `0x` literal round-trips
      # byte-for-byte (MEASURED against real SQL Server). A text String keeps the
      # quote-doubled literal (correct T-SQL escaping).
      def interpolate_string(param)
        if param.encoding == Encoding::BINARY
          param.empty? ? "0x" : "0x#{param.unpack1('H*')}"
        else
          "'#{param.gsub("'", "''")}'"
        end
      end
    end
  end
end
