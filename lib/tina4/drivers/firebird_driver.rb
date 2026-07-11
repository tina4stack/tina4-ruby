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

      # Detects a Windows drive-letter prefix like "C:/" or "C:\". The leading-slash
      # variant ("/C:/...") shows up after URI.parse strips one slash off
      # "firebird://host:port/C:/...".
      WIN_DRIVE_RE = %r{\A/?[A-Za-z]:[/\\]}.freeze

      # Turn the URL path component into a Firebird database identifier.
      #
      # Firebird is the awkward one — it needs either an absolute file path
      # on the server, a Windows drive-letter path, or an alias name. The
      # classic URI form uses a double-slash to keep the leading "/" of an
      # absolute path through URI.parse:
      #
      #     firebird://host:port//firebird/data/app.fdb   →  /firebird/data/app.fdb
      #
      # But that double slash is unintuitive to anyone used to the way
      # postgres / mysql / mssql encode the database name. We accept five
      # equivalent forms and normalise all of them:
      #
      # * "//abs/path/db.fdb"    → "/abs/path/db.fdb"    (classic double-slash)
      # * "/abs/path/db.fdb"     → "/abs/path/db.fdb"    (single-slash, what most people type)
      # * "/C:/Data/db.fdb"      → "C:/Data/db.fdb"      (Windows, leading URL slash dropped)
      # * "/C%3A/Data/db.fdb"    → "C:/Data/db.fdb"      (Windows with URL-encoded colon)
      # * "/employee"            → "employee"            (alias — single token)
      #
      # Aliases are detected as the leftover case: a single token with no
      # slashes. Anything path-like is kept as a path.
      def self.normalize_db_identifier(raw_path)
        require "uri"
        return "" if raw_path.nil? || raw_path.empty?

        decoded = URI.decode_www_form_component(raw_path)

        # Classic double-slash form: //abs/path → /abs/path
        decoded = decoded[1..] if decoded.start_with?("//")

        # Windows drive-letter — drop the URL-introduced leading slash.
        # /C:/Data/db.fdb → C:/Data/db.fdb
        if WIN_DRIVE_RE.match?(decoded)
          decoded = decoded[1..] if decoded.start_with?("/")
          return decoded
        end

        # Look at the content after stripping the leading slash. If it's a
        # single token with no separators, it's a Firebird alias — return
        # WITHOUT the leading slash (the alias name itself is the identifier).
        body = decoded.start_with?("/") ? decoded[1..] : decoded
        if !body.empty? && !body.include?("/") && !body.include?("\\")
          return body
        end

        # Otherwise it's a file path. If it already has a leading slash,
        # keep it. If it's a relative-looking path (slash-separated but no
        # leading "/") promote it to absolute — Firebird needs absolute paths
        # and we don't know the server's CWD anyway.
        decoded.start_with?("/") ? decoded : "/#{decoded}"
      end

      # Resolve the Firebird connection charset (#160, mirrors php #160 /
      # the Python master's _resolve_firebird_charset).
      #
      # The driver used to pass NO charset to the `fb` gem, leaving it to the
      # gem's own (non-UTF8) default — which double-encodes UTF-8 bytes stored
      # under a legacy NONE database and diverges from the other frameworks.
      # The charset is now resolved from, in precedence order:
      #
      #   1. the connection URL query — firebird://host:port/path?charset=NONE
      #   2. an explicit charset: kwarg passed to #connect
      #   3. the TINA4_DATABASE_CHARSET environment variable
      #   4. the UTF8 default (canonical across all four frameworks)
      #
      # Pure config resolution over its inputs (URL string, kwarg, env) — it
      # opens NO connection, so it is unit-testable without a live server. A
      # blank value at any level is treated as absent (matching the Python
      # master's falsy-string semantics) so `?charset=` / an empty env var falls
      # through rather than connecting with an empty charset.
      def self.resolve_charset(connection_string, kwarg_charset = nil)
        require "uri"
        url_charset = nil
        query = begin
          URI.parse(connection_string.to_s).query
        rescue URI::InvalidURIError
          nil
        end
        if query && !query.empty?
          pair = URI.decode_www_form(query).find { |k, _| k == "charset" }
          url_charset = pair[1] if pair && !pair[1].to_s.empty?
        end
        kwarg = kwarg_charset.to_s.empty? ? nil : kwarg_charset
        env = ENV["TINA4_DATABASE_CHARSET"].to_s.empty? ? nil : ENV["TINA4_DATABASE_CHARSET"]
        url_charset || kwarg || env || "UTF8"
      end

      def connect(connection_string, username: nil, password: nil, charset: nil)
        require "fb"
        require "uri"
        uri = URI.parse(connection_string)
        host = uri.host
        port = uri.port || 3050
        db_user = username || uri.user
        db_pass = password || uri.password

        # Firebird database identifier resolution — two layers:
        #
        # 1. TINA4_DATABASE_FIREBIRD_PATH env override wins if set.
        #    Useful for Windows users with raw backslash paths (no URL
        #    encoding required) and for ops setups that keep server URL
        #    and DB location in separate config layers.
        # 2. Otherwise normalise the URL path component — accepts every
        #    sensible variant (single/double slash, drive letter, alias).
        env_override = ENV["TINA4_DATABASE_FIREBIRD_PATH"].to_s
        db_path = if !env_override.empty?
                    env_override
                  else
                    self.class.normalize_db_identifier(uri.path.to_s)
                  end

        database = if host
                     "#{host}/#{port}:#{db_path}"
                   else
                     # No host → fall back to the raw identifier (or, for
                     # totally non-URL inputs, strip the scheme prefix).
                     return_path = db_path
                     return_path = connection_string.sub(/^firebird:\/\//, "") if return_path.empty?
                     return_path
                   end

        # Cache for transparent reconnect — never logged, lives only in
        # driver memory alongside the connection it owns.
        @connect_opts = { database: database }
        @connect_opts[:username] = db_user if db_user
        @connect_opts[:password] = db_pass if db_pass
        # #160: honour ?charset= in the URL, an explicit charset: kwarg, and
        # TINA4_DATABASE_CHARSET so a legacy NONE database isn't force-connected
        # with the gem's default charset (double-encoding). Defaults to UTF8.
        @connect_opts[:charset] = self.class.resolve_charset(connection_string, charset)

        open_connection
      rescue LoadError
        raise LoadError,
              "The 'fb' gem is required for Firebird connections. Install one of:\n" \
              "    bundle add fb     # if your project uses Bundler\n" \
              "    gem install fb    # bare driver"
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
