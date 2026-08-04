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

      def initialize(options = {})
        # TINA4_SESSION_TTL reaches every backend (ADR-0024); was a hard-coded
        # 86400. 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @db = options[:db] || Tina4::Database.new(ENV["TINA4_DATABASE_URL"])
        ensure_table
      end

      def read(session_id)
        row = @db.fetch_one("SELECT data, expires_at FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
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
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        expires_at = effective_ttl.positive? ? Time.now.to_f + effective_ttl : 0.0
        json_data = JSON.generate(data)

        existing = @db.fetch_one("SELECT session_id FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
        if existing
          @db.execute("UPDATE #{TABLE_NAME} SET data = ?, expires_at = ? WHERE session_id = ?", [json_data, expires_at, session_id])
        else
          @db.execute("INSERT INTO #{TABLE_NAME} (session_id, data, expires_at) VALUES (?, ?, ?)", [session_id, json_data, expires_at])
        end
      end

      def destroy(session_id)
        @db.execute("DELETE FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
      end

      def cleanup
        @db.execute("DELETE FROM #{TABLE_NAME} WHERE expires_at > 0 AND expires_at < ?", [Time.now.to_f])
      end

      # Garbage-collect expired sessions. Matches the Python interface.
      # @param max_age [Integer] maximum session age in seconds (unused — expiry is absolute)
      def gc(max_age)
        @db.execute("DELETE FROM #{TABLE_NAME} WHERE expires_at > 0 AND expires_at < ?", [Time.now.to_f])
      end

      private

      def ensure_table
        @db.execute(CREATE_TABLE_SQL)
      end
    end
  end
end
