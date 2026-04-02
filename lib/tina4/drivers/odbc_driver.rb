# frozen_string_literal: true

module Tina4
  module Drivers
    class OdbcDriver
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
      def connect(connection_string, username: nil, password: nil)
        begin
          require "odbc"
        rescue LoadError
          raise LoadError,
            "The 'ruby-odbc' gem is required for ODBC connections. " \
            "Install: gem install ruby-odbc"
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

        @connection = ODBC::Database.new(dsn_string)
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
      def apply_limit(sql, limit, offset = 0)
        offset ||= 0
        if offset > 0
          # SQL Server / ANSI syntax — requires ORDER BY; add a no-op if absent
          if sql.upcase.include?("ORDER BY")
            "#{sql} OFFSET #{offset} ROWS FETCH NEXT #{limit} ROWS ONLY"
          else
            # LIMIT/OFFSET fallback (MySQL, PostgreSQL via ODBC, SQLite via ODBC)
            "#{sql} LIMIT #{limit} OFFSET #{offset}"
          end
        else
          "#{sql} LIMIT #{limit}"
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
            primary_key: false  # ODBC metadata does not reliably expose PK flag here
          }
        end
        stmt.drop
        result
      rescue => e
        stmt&.drop rescue nil
        raise e
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
