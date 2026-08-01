# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class MysqlDriver
      # First SIX characters of the statements whose row count #affected_rows
      # reports. "REPLAC" is REPLACE truncated to the same width.
      WRITE_VERBS = %w[INSERT UPDATE DELETE REPLAC].freeze

      include Tina4::DatabaseAdapter
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
        stmt = nil
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
        # MySQL reports the FIRST generated id of a MULTI-ROW INSERT, not the
        # last (verified live: a 3-row insert into a fresh table reports 1 while
        # MAX(id) is 3). Every other engine reports the last, and callers -
        # get_last_id, ORM#save, the batch DatabaseResult - all expect the last.
        # The ids in one statement are consecutive, so normalise here, where both
        # the first id and the row count are known; doing it further up would
        # leave get_last_id disagreeing with the returned result.
        # The row count MUST come from the STATEMENT, not the connection.
        # mysql2's client.affected_rows is unreliable after a prepared
        # execute - measured live, it reported 3 (stale, from the previous
        # query) for a 1-row prepared insert, and 0 for a 3-row one. Using it
        # would shift last_id by a wrong offset. stmt.affected_rows is exact.
        #
        # Hoisted out of the INSERT branch: the count was computed for an INSERT
        # only, so the driver exposed no #affected_rows at all and
        # Database#write_affected fell through to its default of 0 - an UPDATE
        # that really changed a row reported affected_rows = 0, indistinguishable
        # from "matched nothing". Gated on the WRITE verbs because a SELECT's
        # count is its returned-row count, which would clobber the write before
        # it (SQLite's connection.changes has the same last-write-wins rule).
        if WRITE_VERBS.include?(sql.to_s.lstrip[0, 6].upcase)
          @affected_rows = stmt ? stmt.affected_rows.to_i : @connection.affected_rows.to_i
        end

        if sql.to_s.lstrip[0, 6].casecmp?("INSERT")
          first_id = @connection.last_id
          rows = @affected_rows.to_i
          @last_insert_id =
            if first_id.to_i.positive?
              first_id.to_i + [rows, 1].max - 1
            else
              first_id
            end
        end
        result
      end

      def last_insert_id
        @last_insert_id
      end

      # Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
      # Parity with SQLite (connection.changes), PostgreSQL (cmd_tuples), MSSQL
      # (TinyTds::Result#do) and the Python master (cursor.rowcount).
      def affected_rows
        @affected_rows.to_i
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      # NEW LINE, not a space — appended inline the clause lands inside a
      # trailing `-- comment` and the engine ignores it (see the note on
      # Drivers::SqliteDriver#apply_limit).
      def apply_limit(sql, limit, offset = 0)
        "#{sql}\nLIMIT #{limit} OFFSET #{offset}"
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
