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
        # libmysqlclient connects over a UNIX socket whenever host is "localhost"
        # (its historical convention) and silently ignores the port. A URL that
        # names a port clearly intends TCP, so rewrite "localhost" to "127.0.0.1"
        # in that case to force the TCP path — without it a Docker/TCP-only MySQL
        # fails with "Can't connect ... through socket '/tmp/mysql.sock'". A
        # port-less "localhost" keeps the socket path so socket deployments still
        # work. Parity with PHP's MySQLAdapter::rewriteHostForTcp (mysqli has the
        # identical socket trap).
        host = uri.host || "127.0.0.1"
        host = "127.0.0.1" if host == "localhost" && uri.port
        @connection = Mysql2::Client.new(
          host: host,
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
        result =
          if params.empty?
            @connection.query(sql)
          else
            stmt = @connection.prepare(sql)
            stmt.execute(*params)
          end
        # Capture the generated id AT WRITE TIME — mirrors the Python master
        # (mysql.py execute(): `last_id = cursor.lastrowid` is read straight after
        # the statement, never re-read later). mysql2's @connection.last_id reflects
        # the LAST statement on this connection, so a follow-up autocommit COMMIT
        # (a separate query) clobbers it to 0 — that is exactly why db.get_last_id
        # returned 0 after an insert (issue #262). Snapshot it for every INSERT so
        # last_insert_id keeps the id of the last insert regardless of any
        # subsequent COMMIT / SELECT on the connection.
        @last_insert_id = @connection.last_id if sql.to_s.lstrip[0, 6].casecmp?("INSERT")
        result
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
