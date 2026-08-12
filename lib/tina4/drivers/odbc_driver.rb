# frozen_string_literal: true

module Tina4
  module Drivers
    class OdbcDriver
      # Postgres, MySQL, MSSQL and ODBC all REQUIRE a name for a derived
      # table, so the COUNT probe in Database#count_probe wraps as
      # `FROM (sql) AS _count_query`. SQLite and Firebird do not define
      # this and get no alias - Firebird rejects `AS` in that position.
      def count_subquery_alias
        "_count_query"
      end

      include Tina4::DatabaseAdapter
      attr_reader :connection

      # Connect to an ODBC data source.
      #
      # Connection string formats:
      #   odbc:///DSN=MyDSN
      #   odbc:///DSN=MyDSN;UID=user;PWD=pass
      #   odbc:///DRIVER={SQL Server};SERVER=host;DATABASE=db
      #
      # The leading scheme prefix "odbc:///" is stripped; the remainder is
      # passed verbatim to ODBC::Database.new as a connection string.
      # username: and password: are appended as UID/PWD if not already present
      # in the connection string.
      #
      # NOT bounded by TINA4_DATABASE_CONNECT_TIMEOUT, and this is a deliberate
      # exclusion rather than an oversight. Three reasons, in order of weight:
      #
      # 1. ruby-odbc is not a Tina4 dependency (it is in neither the gemspec nor
      #    the Gemfile) and its C extension will not build without unixodbc-dev,
      #    so it is installed in neither CI nor the lab. A change here could not
      #    be tested, and an untestable change to a connect path is exactly the
      #    kind of "protection" that turns out not to fire.
      # 2. An ODBC target is a DSN name, a file DSN or a local driver. In the
      #    general case there is no host and no port, so the contract's error
      #    message has nothing to name.
      # 3. The ODBC-standard bound is SQL_LOGIN_TIMEOUT, which the operator
      #    already controls: the DSN string below is passed through verbatim, so
      #    a driver-specific `Login Timeout=` / `Connection Timeout=` in it takes
      #    effect today with no framework code at all.
      #
      # If ruby-odbc ever becomes testable here, the hook exists:
      # ODBC::Database#login_timeout= maps to SQL_LOGIN_TIMEOUT (odbc.c:5475,
      # bound at odbc.c:9366), reachable by constructing an unconnected
      # ODBC::Database, setting it, then calling #drvconnect (odbc.c:9330)
      # instead of connecting inside ::new.
      def connect(connection_string, username: nil, password: nil)
        begin
          require "odbc"
        rescue LoadError
          raise LoadError,
                "The 'ruby-odbc' gem is required for ODBC connections. Install one of:\n" \
                "    bundle add ruby-odbc     # if your project uses Bundler\n" \
                "    gem install ruby-odbc    # bare driver"
        end

        dsn_string = connection_string.to_s
          .sub(/^odbc:\/\/\//, "")
          .sub(/^odbc:\/\//, "")
          .sub(/^odbc:/, "")

        # Append credentials if provided and not already embedded
        if username && !dsn_string.match?(/\bUID=/i)
          dsn_string = "#{dsn_string};UID=#{username}"
        end
        if password && !dsn_string.match?(/\bPWD=/i)
          dsn_string = "#{dsn_string};PWD=#{password}"
        end

        # ODBC::Database.new(string) routes to SQLConnect, which takes a DSN NAME
        # (data source), NOT a connection string - so a DRIVER={...} / DSN=...
        # string (exactly what Tina4's odbc:/// URL produces) raised "Invalid
        # string or buffer length" against a real driver. SQLDriverConnect is the
        # call that parses a connection string; reach it via #drvconnect on an
        # unconnected handle. MEASURED against a real psqlodbc source: this adapter
        # could never connect with a connection string until now.
        @connection = ODBC::Database.new
        @connection.drvconnect(dsn_string)
        @in_transaction = false
        self
      end

      def close
        @connection&.disconnect
        @connection = nil
      end

      def connected?
        !@connection.nil?
      end

      # Execute a SELECT query and return rows as an array of symbol-keyed hashes.
      def execute_query(sql, params = [])
        stmt = if params && !params.empty?
          s = @connection.prepare(sql)
          s.execute(*params)
          s
        else
          @connection.run(sql)
        end

        columns = stmt.columns(true).map { |c| c.name.to_s.to_sym }
        rows = []
        while (row = stmt.fetch)
          rows << columns.zip(row).to_h
        end
        stmt.drop
        rows
      rescue => e
        stmt&.drop rescue nil
        raise e
      end

      # Execute DDL or DML without returning rows.
      def execute(sql, params = [])
        if params && !params.empty?
          stmt = @connection.prepare(sql)
          stmt.execute(*params)
          stmt.drop
        else
          @connection.do(sql)
        end
        nil
      end

      # ODBC does not expose a universal last-insert-id API.
      # Drivers that support it can be queried via execute_query after insert.
      def last_insert_id
        nil
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      # Build paginated SQL.
      # Tries OFFSET/FETCH NEXT (SQL Server, newer ODBC sources) first.
      # Falls back to LIMIT/OFFSET for sources that support it (MySQL, PostgreSQL via ODBC).
      # The caller (Database#fetch) already gates on whether LIMIT is already present.
      # Every append goes on a NEW LINE: inline it lands inside a trailing
      # `-- comment` and the source silently ignores it (see the note on
      # Drivers::SqliteDriver#apply_limit). The ORDER BY probe reads the SCRUBBED
      # SQL, so an ORDER BY that only appears in a comment or a string literal
      # no longer counts as one.
      def apply_limit(sql, limit, offset = 0)
        offset ||= 0
        if offset > 0
          # SQL Server / ANSI syntax — requires ORDER BY; add a no-op if absent
          if Tina4::Database.scrub_sql_text(sql).upcase.include?("ORDER BY")
            "#{sql}\nOFFSET #{offset} ROWS FETCH NEXT #{limit} ROWS ONLY"
          else
            # LIMIT/OFFSET fallback (MySQL, PostgreSQL via ODBC, SQLite via ODBC)
            "#{sql}\nLIMIT #{limit} OFFSET #{offset}"
          end
        else
          "#{sql}\nLIMIT #{limit}"
        end
      end

      def begin_transaction
        return if @in_transaction
        @connection.autocommit = false
        @in_transaction = true
      end

      def commit
        return unless @in_transaction
        @connection.commit
        @connection.autocommit = true
        @in_transaction = false
      end

      def rollback
        return unless @in_transaction
        @connection.rollback
        @connection.autocommit = true
        @in_transaction = false
      end

      # List all user tables via ODBC metadata.
      def tables
        stmt = @connection.tables
        rows = []
        while (row = stmt.fetch_hash)
          type = row["TABLE_TYPE"] || row[:TABLE_TYPE] || ""
          name = row["TABLE_NAME"] || row[:TABLE_NAME]
          rows << name.to_s if type.to_s.upcase == "TABLE" && name
        end
        stmt.drop
        rows
      rescue => e
        stmt&.drop rescue nil
        raise e
      end

      # Return column metadata for a table via ODBC metadata.
      def columns(table_name)
        pk = primary_key_columns(table_name)
        stmt = @connection.columns(table_name.to_s)
        result = []
        while (row = stmt.fetch_hash)
          name    = row["COLUMN_NAME"]    || row[:COLUMN_NAME]
          type    = row["TYPE_NAME"]      || row[:TYPE_NAME]
          nullable_val = row["NULLABLE"]  || row[:NULLABLE]
          default = row["COLUMN_DEF"]     || row[:COLUMN_DEF]
          result << {
            name: name.to_s,
            type: type.to_s,
            nullable: nullable_val.to_i == 1,
            default: default,
            # Real PK, from the ODBC catalog (SQLPrimaryKeys) - not the old
            # `false` stub. The write-guard reads primary_key, so without this a
            # PK-keyed update(table, data) on ODBC could not introspect the key.
            primary_key: pk.include?(name.to_s.downcase)
          }
        end
        stmt.drop
        result
      rescue => e
        stmt&.drop rescue nil
        raise e
      end

      # The table's primary-key columns from the ODBC catalog (SQLPrimaryKeys),
      # down-cased for case-insensitive matching. Empty on any target that does
      # not report them - the write-guard then requires an explicit filter.
      def primary_key_columns(table_name)
        stmt = @connection.primary_keys(table_name.to_s)
        cols = []
        while (row = stmt.fetch_hash)
          col = row["COLUMN_NAME"] || row[:COLUMN_NAME]
          cols << col.to_s.downcase if col
        end
        stmt.drop
        cols
      rescue StandardError
        stmt&.drop rescue nil
        []
      end

      private

      # (No symbolize_keys here: execute_query already hydrates by zipping a
      # once-computed symbol column list against each array row, so there is no
      # per-cell symbolize to hoist. A leftover unused symbolize_keys was removed.)
    end
  end
end
