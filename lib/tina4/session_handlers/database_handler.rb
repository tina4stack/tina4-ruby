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
            expires_at REAL NOT NULL
        )
      SQL

      def initialize(options = {})
        @ttl = options[:ttl] || 86400
        @db = options[:db] || Tina4::Database.new(ENV["DATABASE_URL"])
        ensure_table
      end

      def read(session_id)
        row = @db.fetch_one("SELECT data, expires_at FROM #{TABLE_NAME} WHERE session_id = ?", [session_id])
        return nil unless row

        expires_at = row["expires_at"].to_f
        if expires_at > 0 && expires_at < Time.now.to_f
          destroy(session_id)
          return nil
        end

        JSON.parse(row["data"])
      rescue JSON::ParserError
        nil
      end

      def write(session_id, data)
        expires_at = @ttl > 0 ? Time.now.to_f + @ttl : 0.0
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

      private

      def ensure_table
        @db.execute(CREATE_TABLE_SQL)
      end
    end
  end
end
