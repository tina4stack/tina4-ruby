# frozen_string_literal: true

module Tina4
  module Drivers
    class FirebirdDriver
      attr_reader :connection

      # Substring markers (lowercased) that identify a dead-socket Firebird
      # error worth reconnecting for. Idle Firebird connections die silently
      # behind NAT timeouts, server-side ConnectionIdleTimeout, or Docker
      # network rotation; without this the next prepare crashes the request.
      DEAD_CONN_MARKERS = [
        "error writing data to the connection",
        "error reading data from the connection",
        "connection shutdown",
        "connection lost",
        "network error",
        "connection is not active",
        "broken pipe"
      ].freeze

      def connect(connection_string, username: nil, password: nil)
        require "fb"
        require "uri"
        uri = URI.parse(connection_string)
        host = uri.host
        port = uri.port || 3050
        db_path = uri.path&.sub(/^\//, "")
        db_user = username || uri.user
        db_pass = password || uri.password

        database = if host
                     "#{host}/#{port}:#{db_path}"
                   else
                     db_path || connection_string.sub(/^firebird:\/\//, "")
                   end

        # Cache for transparent reconnect — never logged, lives only in
        # driver memory alongside the connection it owns.
        @connect_opts = { database: database }
        @connect_opts[:username] = db_user if db_user
        @connect_opts[:password] = db_pass if db_pass

        open_connection
      rescue LoadError
        raise "Firebird driver requires the 'fb' gem. Install it with: gem install fb"
      end

      def close
        @connection&.close
      end

      def execute_query(sql, params = [])
        rows = with_reconnect do
          if params.empty?
            @connection.query(:hash, sql)
          else
            @connection.query(:hash, sql, *params)
          end
        end
        rows.map { |row| decode_blobs(stringify_keys(row)) }
      end

      def execute(sql, params = [])
        with_reconnect do
          if params.empty?
            @connection.execute(sql)
          else
            @connection.execute(sql, *params)
          end
        end
      end

      # Public so specs (and curious operators) can verify the matcher
      # behaviour without poking private methods.
      def self.dead_connection?(error_or_message)
        msg = error_or_message.respond_to?(:message) ? error_or_message.message : error_or_message.to_s
        return false if msg.nil? || msg.empty?
        lower = msg.downcase
        DEAD_CONN_MARKERS.any? { |m| lower.include?(m) }
      end

      def last_insert_id
        nil
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      def apply_limit(sql, limit, offset = 0)
        "SELECT FIRST #{limit} SKIP #{offset} * FROM (#{sql})"
      end

      def begin_transaction
        @transaction = @connection.transaction
      end

      def commit
        @transaction&.commit
      end

      def rollback
        @transaction&.rollback
      end

      def tables
        sql = "SELECT RDB\$RELATION_NAME FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG = 0 AND RDB\$VIEW_BLR IS NULL"
        rows = execute_query(sql)
        rows.map { |r| (r["RDB\$RELATION_NAME"] || r["rdb\$relation_name"] || "").strip }
      end

      def columns(table_name)
        sql = "SELECT RF.RDB\$FIELD_NAME, F.RDB\$FIELD_TYPE, RF.RDB\$NULL_FLAG, RF.RDB\$DEFAULT_SOURCE " \
              "FROM RDB\$RELATION_FIELDS RF " \
              "JOIN RDB\$FIELDS F ON RF.RDB\$FIELD_SOURCE = F.RDB\$FIELD_NAME " \
              "WHERE RF.RDB\$RELATION_NAME = ?"
        rows = execute_query(sql, [table_name.upcase])
        rows.map do |r|
          {
            name: (r["RDB\$FIELD_NAME"] || r["rdb\$field_name"] || "").strip,
            type: r["RDB\$FIELD_TYPE"] || r["rdb\$field_type"],
            nullable: (r["RDB\$NULL_FLAG"] || r["rdb\$null_flag"]).nil?,
            default: r["RDB\$DEFAULT_SOURCE"] || r["rdb\$default_source"],
            primary_key: false
          }
        end
      end

      private

      def open_connection
        @connection = Fb::Database.new(**@connect_opts).connect
      end

      # Force-close a stale handle and reopen using cached opts. Idempotent —
      # safe to call when the connection is already gone.
      def reconnect!
        begin
          @connection&.close
        rescue StandardError
          # connection already gone — nothing to clean up
        end
        @connection = nil
        @transaction = nil
        open_connection
      end

      # Run a block; if it raises with a dead-connection signature, reconnect
      # once and retry. Skipped inside an explicit transaction — atomicity
      # beats resilience there; the caller handles rollback.
      def with_reconnect
        yield
      rescue StandardError => e
        raise unless self.class.dead_connection?(e) && @transaction.nil?
        reconnect!
        yield
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end

      # Ensure Firebird BLOB columns are proper byte strings.
      # The Fb gem may return BLOBs as resource handles or IO objects —
      # read them into strings if needed.
      def decode_blobs(row)
        row.each do |key, value|
          if value.respond_to?(:read)
            row[key] = value.read
            value.close if value.respond_to?(:close)
          end
        end
        row
      end
    end
  end
end
