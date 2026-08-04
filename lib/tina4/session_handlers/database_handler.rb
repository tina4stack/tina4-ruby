# frozen_string_literal: true

require "json"

module Tina4
  module SessionHandlers
    class DatabaseHandler
      TABLE_NAME = "tina4_session"

      CREATE_TABLE_SQL = <<~SQL
        CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
            session_id VARCHAR(255) PRIMARY KEY,
            data TEXT NOT NULL,
            expires_at DOUBLE PRECISION NOT NULL
        )
      SQL

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

      # Create the session table once, on first use rather than at construction.
      # The flag is set BEFORE the DDL so an unreachable database is not
      # re-probed on every call - the same ordering the Python master uses for
      # _table_ready.
      def ensure_table
        return if @table_ready

        @table_ready = true
        db.execute(CREATE_TABLE_SQL)
      end
    end
  end
end
