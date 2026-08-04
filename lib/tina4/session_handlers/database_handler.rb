# frozen_string_literal: true

require "json"

module Tina4
  module SessionHandlers
    class DatabaseHandler
      TABLE_NAME = "tina4_session"

      # CREATE TABLE per engine. This is the ONLY genuinely per-engine SQL in
      # this file - every other statement is written once with `?` placeholders
      # and rewritten for the driver by the Database layer.
      #
      # The COLUMNS are identical on every engine (session_id, data,
      # expires_at) because the table is a CROSS-FRAMEWORK CONTRACT: a
      # tina4_session table written by tina4-python must be readable by
      # tina4-ruby. Only the type spellings and the "create it only if absent"
      # idiom differ. Ported from the Node reference under ADR-0004
      # (tina4-nodejs/packages/core/src/sessionHandlers/databaseHandler.ts).
      #
      # WHAT WAS WRONG. This used to be ONE generic string for every engine,
      # opening with CREATE TABLE IF NOT EXISTS. That clause is not T-SQL, so
      # the whole statement was a SYNTAX ERROR on SQL Server and the database
      # session backend did not work on MSSQL AT ALL - the identical defect
      # measured and fixed in PHP. Firebird rejected the same string twice
      # over: it has no IF NOT EXISTS clause AND no TEXT type.
      CREATE_TABLE_SQL = {
        # Behaviour-identical to the generic DDL this replaces, so an EXISTING
        # deployment is untouched. IF NOT EXISTS makes the statement a no-op
        # against a table that is already there, so a live tina4_session keeps
        # exactly the columns it was created with; and on a FRESH database the
        # storage classes are the same ones the old spelling produced, because
        # SQLite resolves VARCHAR(255) to TEXT affinity and DOUBLE PRECISION to
        # REAL affinity. Only the declared type string in sqlite_master
        # changes, and nothing reads that.
        "sqlite" => <<~SQL,
          CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
              session_id TEXT PRIMARY KEY,
              data TEXT NOT NULL,
              expires_at REAL NOT NULL
          )
        SQL
        "postgres" => <<~SQL,
          CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
              session_id VARCHAR(255) PRIMARY KEY,
              data TEXT NOT NULL,
              expires_at DOUBLE PRECISION NOT NULL
          )
        SQL
        "mysql" => <<~SQL,
          CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
              session_id VARCHAR(255) PRIMARY KEY,
              data TEXT NOT NULL,
              expires_at DOUBLE NOT NULL
          )
        SQL
        # T-SQL has no CREATE TABLE IF NOT EXISTS. Node guards this statement
        # with `IF OBJECT_ID(N'tina4_session', N'U') IS NULL`; that guard is
        # deliberately NOT carried over, because it is CHECK-THEN-ACT and has a
        # window - two connections can both see NULL and both CREATE, and the
        # loser gets `Msg 2714: There is already an object named
        # 'tina4_session'`, measured on live SQL Server. This takes Node's
        # TYPES and pairs them with PHP's RESCUE in ensure_table below, which
        # is strictly better than either alone: Node's types make the statement
        # legal on this engine, and PHP's rescue closes the window Node's
        # catalog check leaves open.
        "mssql" => <<~SQL,
          CREATE TABLE #{TABLE_NAME} (
              session_id NVARCHAR(255) NOT NULL PRIMARY KEY,
              data NVARCHAR(MAX) NOT NULL,
              expires_at FLOAT NOT NULL
          )
        SQL
        # Firebird has neither IF NOT EXISTS nor a TEXT type, so the catalog
        # check goes in an EXECUTE BLOCK and the payload is a VARCHAR. That
        # caps a session payload at 8191 characters ON THIS ENGINE ALONE, which
        # is the deliberate price of not using BLOB SUB_TYPE TEXT: a driver
        # hands a blob back as a reader rather than a string, which the read
        # path here would not understand.
        #
        # VERIFIED AT THE SQL LEVEL ONLY (Firebird 5.0.4, via isql, measured on
        # the lab container): CREATE TABLE IF NOT EXISTS fails -104 "Token
        # unknown ... NOT", a TEXT column fails -607 "Specified domain or
        # source column TEXT does not exist", DOUBLE PRECISION is accepted, and
        # this EXECUTE BLOCK creates the table and is idempotent on a second
        # run. That idempotence is check-then-act inside one block, so it is
        # NOT a race guard - a bare CREATE with the table present gives
        # SQLSTATE 42S01, so the rescue below is required here exactly as on
        # mssql.
        "firebird" => <<~SQL
          EXECUTE BLOCK AS BEGIN
            IF (NOT EXISTS(SELECT 1 FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = '#{TABLE_NAME.upcase}')) THEN
              EXECUTE STATEMENT 'CREATE TABLE #{TABLE_NAME.upcase} (SESSION_ID VARCHAR(255) NOT NULL PRIMARY KEY, DATA VARCHAR(8191) NOT NULL, EXPIRES_AT DOUBLE PRECISION NOT NULL)';
          END
        SQL
      }.freeze

      # NO NETWORK I/O IN A CONSTRUCTOR (ADR-0021, session_contract.json #4).
      # Both lines this constructor used to run were real traffic:
      #
      #   Tina4::Database.new(...)  - #initialize ends in `connect` for a
      #     single-connection database (database.rb:405), so the driver DIALS.
      #     MEASURED against a real counting TCP listener: 1 accepted connection.
      #   ensure_table              - a CREATE TABLE IF NOT EXISTS, real DDL on
      #     that connection.
      #
      # And because the request path builds a Session per request, that ran on
      # EVERY request. Both sat OUTSIDE the log-loud-and-degrade policy, so an
      # unreachable database took the app down at construction instead of
      # degrading per request as designed. Connection and table are now resolved
      # on FIRST USE, inside that policy.
      def initialize(options = {})
        # TINA4_SESSION_TTL reaches every backend (ADR-0024); was a hard-coded
        # 86400. 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @db_option = options[:db]
        @db = nil
        @table_ready = false
      end

      def read(session_id)
        ensure_table
        row = db.fetch_one("SELECT data, expires_at FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
        return nil unless row

        expires_at = (row[:expires_at] || row["expires_at"]).to_f
        if expires_at > 0 && expires_at < Time.now.to_f
          destroy(session_id)
          return nil
        end

        JSON.parse(row[:data] || row["data"])
      rescue JSON::ParserError
        nil
      end

      # Write session data. A per-call +ttl+ WINS over the handler default; 0 means
      # never expires and is stored as the 0 that read guards out.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        ensure_table
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        expires_at = effective_ttl.positive? ? Time.now.to_f + effective_ttl : 0.0
        json_data = JSON.generate(data)

        existing = db.fetch_one("SELECT session_id FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
        if existing
          db.execute("UPDATE #{TABLE_NAME} SET data = ?, expires_at = ? WHERE session_id = ?", [json_data, expires_at, session_id])
        else
          db.execute("INSERT INTO #{TABLE_NAME} (session_id, data, expires_at) VALUES (?, ?, ?)", [session_id, json_data, expires_at])
        end
      end

      def destroy(session_id)
        ensure_table
        db.execute("DELETE FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
      end

      def cleanup
        ensure_table
        db.execute("DELETE FROM #{TABLE_NAME} WHERE expires_at > 0 AND expires_at < ?", [Time.now.to_f])
      end

      # Garbage-collect expired sessions. Matches the Python interface.
      # @param max_age [Integer] maximum session age in seconds (unused — expiry is absolute)
      def gc(max_age)
        ensure_table
        db.execute("DELETE FROM #{TABLE_NAME} WHERE expires_at > 0 AND expires_at < ?", [Time.now.to_f])
      end

      private

      # The database connection, resolved on FIRST USE. An explicit :db option
      # still wins; only the env-derived fallback has to be built, and building
      # it CONNECTS (see #initialize), which is why it cannot happen earlier.
      def db
        @db ||= (@db_option || Tina4::Database.new(ENV["TINA4_DATABASE_URL"]))
      end

      # The CREATE TABLE this connection's engine understands.
      #
      # Tina4::Database#driver_name is the public accessor and it already holds
      # the ALIAS-NORMALISED engine key ("postgres", not "postgresql"), the same
      # value used to pick the driver class, so nothing here re-parses the
      # connection string. An injected :db is an application-supplied object and
      # therefore a trust boundary: one that cannot name its engine falls back
      # to the generic ANSI shape, which is byte-for-byte what every engine used
      # to get, so an app that duck-types a database is no worse off than before.
      def create_table_sql
        engine = db.respond_to?(:driver_name) ? db.driver_name.to_s : ""
        CREATE_TABLE_SQL.fetch(engine, CREATE_TABLE_SQL["postgres"])
      end

      # Create the session table once, on first use rather than at construction.
      # The flag is set BEFORE the DDL so an unreachable database is not
      # re-probed on every call - the same ordering the Python master uses for
      # _table_ready.
      #
      # THE CONCURRENT FIRST-USE RACE. Two workers booting together both reach
      # this line and both issue the CREATE; one of them loses. IF NOT EXISTS
      # settles that ENGINE-SIDE on sqlite, postgres and mysql, but T-SQL has no
      # such clause and Firebird has none either, so on those two the loser
      # raises and would take down the subsystem that decides whether anyone is
      # logged in.
      #
      # The rescue below is the guard, ported from PHP. It RE-CHECKS whether the
      # table exists rather than parsing the error message, because every engine
      # spells "already exists" differently ("There is already an object named",
      # "already exists", SQLSTATE 42S01) and a string match would rot the first
      # time an engine reworded itself or ran under another locale.
      def ensure_table
        return if @table_ready

        @table_ready = true
        begin
          db.execute(create_table_sql)
        rescue StandardError
          # A failed statement leaves PostgreSQL's transaction ABORTED, so
          # without this the re-check would fail for the wrong reason and report
          # a missing table that is right there. Best effort: an engine with no
          # open transaction is entitled to object to being rolled back.
          begin
            db.rollback
          rescue StandardError
            nil
          end
          # Somebody else created it - that is the race, and it is a success.
          # Anything else is a real failure and is re-raised untouched.
          raise unless db.table_exists?(TABLE_NAME)
        end
      end
    end
  end
end
