# frozen_string_literal: true

module Tina4
  module Drivers
    class MssqlDriver
      attr_reader :connection

      def connect(connection_string, username: nil, password: nil)
        require "tiny_tds"
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
        result = @connection.execute(effective_sql)
        result.do
      end

      def last_insert_id
        result = @connection.execute("SELECT SCOPE_IDENTITY() AS id")
        row = result.first
        result.cancel if result.respond_to?(:cancel)
        row[:id]&.to_i
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

      def tables
        rows = execute_query("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'")
        rows.map { |r| r[:TABLE_NAME] || r[:table_name] }
      end

      def columns(table_name)
        sql = "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = ?"
        rows = execute_query(sql, [table_name])
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
          escaped = param.is_a?(String) ? "'#{param.gsub("'", "''")}'" : param.to_s
          result = result.sub("?", escaped)
        end
        result
      end
    end
  end
end
