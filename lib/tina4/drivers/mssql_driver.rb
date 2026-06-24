# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class MssqlDriver
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
        @connection = TinyTds::Client.new(
          host: uri[:host],
          port: uri[:port] || 1433,
          username: username || uri[:username],
          password: password || uri[:password],
          database: uri[:database]
        )
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
          result = @connection.execute("#{effective_sql}; SELECT SCOPE_IDENTITY() AS id")
          rows = result.each(symbolize_keys: true).to_a
          result.cancel if result.respond_to?(:cancel)
          row = rows.last
          @last_insert_id = row && row[:id] ? row[:id].to_i : nil
          return true
        end

        result = @connection.execute(effective_sql)
        result.do
      end

      def last_insert_id
        @last_insert_id
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      def apply_limit(sql, limit, offset = 0)
        "#{sql} OFFSET #{offset} ROWS FETCH NEXT #{limit} ROWS ONLY"
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

      def tables
        rows = execute_query("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'")
        rows.map { |r| r[:TABLE_NAME] || r[:table_name] }
      end

      def columns(table_name)
        # v3.13.14 (#48): honour a schema-qualified name; bare names match any schema.
        schema, tbl = split_schema(table_name)
        sql = "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS " \
              "WHERE TABLE_NAME = ? AND (? IS NULL OR TABLE_SCHEMA = ?)"
        rows = execute_query(sql, [tbl, schema, schema])
        rows.map do |r|
          {
            name: r[:COLUMN_NAME] || r[:column_name],
            type: r[:DATA_TYPE] || r[:data_type],
            nullable: (r[:IS_NULLABLE] || r[:is_nullable]) == "YES",
            default: r[:COLUMN_DEFAULT] || r[:column_default],
            primary_key: false
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
              "'#{param.gsub("'", "''")}'"
            else
              param.to_s
            end
          result = result.sub("?", escaped)
        end
        result
      end
    end
  end
end
