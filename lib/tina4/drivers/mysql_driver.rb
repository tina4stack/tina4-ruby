# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class MysqlDriver
      include SchemaSplit
      attr_reader :connection

      def connect(connection_string, username: nil, password: nil)
        begin
          require "mysql2"
        rescue LoadError
          raise LoadError,
                "The 'mysql2' gem is required for MySQL connections. Install one of:\n" \
                "    bundle add mysql2     # if your project uses Bundler\n" \
                "    gem install mysql2    # bare driver"
        end
        uri = URI.parse(connection_string)
        @connection = Mysql2::Client.new(
          host: uri.host || "localhost",
          port: uri.port || 3306,
          username: username || uri.user,
          password: password || uri.password,
          database: uri.path&.sub("/", "")
        )
      end

      def close
        @connection&.close
      end

      def execute_query(sql, params = [])
        if params.empty?
          results = @connection.query(sql, symbolize_keys: true)
        else
          stmt = @connection.prepare(sql)
          results = stmt.execute(*params, symbolize_keys: true)
        end
        results.to_a
      end

      def execute(sql, params = [])
        if params.empty?
          @connection.query(sql)
        else
          stmt = @connection.prepare(sql)
          stmt.execute(*params)
        end
      end

      def last_insert_id
        @connection.last_id
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
        @connection.query("START TRANSACTION")
      end

      def commit
        @connection.query("COMMIT")
      end

      def rollback
        @connection.query("ROLLBACK")
      end

      # v3.13.14 (#48): MySQL's "schema" is the database. A qualified name
      # ("otherdb.table") checks that catalog; a bare name defaults to the
      # connection's current database via DATABASE().
      def table_exists?(name)
        schema, tbl = split_schema(name)
        rows = execute_query(
          "SELECT 1 FROM information_schema.tables " \
          "WHERE table_schema = COALESCE(?, DATABASE()) AND table_name = ?",
          [schema, tbl]
        )
        !rows.empty?
      end

      def tables
        rows = execute_query("SHOW TABLES")
        rows.map { |r| r.values.first }
      end

      def columns(table_name)
        rows = execute_query("DESCRIBE #{table_name}")
        rows.map do |r|
          {
            name: r[:Field],
            type: r[:Type],
            nullable: r[:Null] == "YES",
            default: r[:Default],
            primary_key: r[:Key] == "PRI"
          }
        end
      end
    end
  end
end
