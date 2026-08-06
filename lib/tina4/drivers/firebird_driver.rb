require "set"
# frozen_string_literal: true

module Tina4
  module Drivers
    class FirebirdDriver
      include Tina4::DatabaseAdapter
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

      # Bound the REACH to a Firebird server before libfbclient is handed the
      # attach. Raises the shared connect-timeout error when the host does not
      # answer within TINA4_DATABASE_CONNECT_TIMEOUT.
      #
      # Why a socket probe and not a timeout around the attach - MEASURED on
      # Ruby 3.2.3 / Ubuntu 24.04.4 / fb 0.10.0 against a REAL TCPServer that
      # accepts the connection and then never replies:
      #
      #   fb attach, no bound          WEDGED past 20s, SIGKILL needed
      #   fb attach, Timeout.timeout(3) WEDGED past 20s - the timeout NEVER fired
      #   fb attach, Thread#join(3)     WEDGED past 20s - join never returned
      #
      # The gem calls isc_attach_database (fb.c:3002) WITHOUT releasing the GVL
      # and without an unblocking function, so no Ruby thread runs to deliver
      # the interrupt - `timeout`'s SIGTERM could not even be delivered. It also
      # builds its DPB from a fixed four-item set (user, password, lc_ctype,
      # role) with no connect-timeout item. There is therefore NO in-process way
      # to bound the attach itself, and a Timeout.timeout here would be WORSE
      # than nothing because it would look like protection and silently not fire.
      #
      # What IS boundable is reaching the host at all, which is the hang
      # operators actually hit: a dead or firewalled server swallows the SYN and
      # the process sits there. A plain stdlib socket bounds that exactly.
      #
      # RESIDUAL GAP, stated plainly so this is not mistaken for full cover: if
      # the TCP handshake SUCCEEDS and the server then never speaks the Firebird
      # protocol, the attach is still UNBOUNDED. Ruby cannot fix that from
      # inside this process - it needs a connect timeout in the fb gem itself.
      #
      # ONLY a timeout is converted. A refused connection, an unknown host or
      # any other socket error is swallowed so libfbclient still produces its
      # own (better) diagnosis: this probe adds a bound, it does not take over
      # error reporting.
      def self.bound_reachability!(host, port)
        seconds = Tina4::DatabaseAdapter.connect_timeout_seconds
        return if seconds.nil? || host.to_s.empty?

        require "socket"
        begin
          Tina4::DatabaseAdapter.bounding_connect(host, port) do
            Socket.tcp(host, port, connect_timeout: seconds, &:close)
          end
        rescue Tina4::DatabaseConnectionError
          raise
        rescue StandardError
          nil
        end
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

        self.class.bound_reachability!(host, port)
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

      # The closing paren goes on a NEW LINE. Inline, a trailing `-- comment` in
      # the caller's SQL comments the paren out and the whole wrapped statement
      # is a syntax error (the same class of bug as the LIMIT append site — see
      # the note on Drivers::SqliteDriver#apply_limit).
      def apply_limit(sql, limit, offset = 0)
        "SELECT FIRST #{limit} SKIP #{offset} * FROM (#{sql}\n)"
      end

      # Transaction handling — mirrors the Python master's connection-level
      # contract (tina4_python firebird.py: start_transaction sets a flag,
      # commit/rollback act on the connection).
      #
      # In the `fb` gem the transaction lives ON the connection:
      # `Fb::Connection#transaction` (no block) STARTS a transaction and returns
      # `true` (a boolean — NOT a transaction object), and
      # `Fb::Connection#commit` / `#rollback` end it. The old code stored that
      # boolean in `@transaction` and called `@transaction&.commit` /
      # `&.rollback`, i.e. `true.commit` / `true.rollback` — a NoMethodError that
      # broke every explicit-transaction commit AND rollback (a rolled-back write
      # was never undone). We now start the transaction on the connection and
      # commit/rollback the CONNECTION, tracking open-ness with an
      # `@in_transaction` boolean (parity with Python's `_in_transaction`).
      #
      # A standalone write auto-commits inside the gem's own `execute`, so the
      # framework's autocommit_standalone_write then calls #commit with no txn
      # open — `Fb::Connection#commit` is a harmless no-op there (returns nil, no
      # raise), so standalone-autocommit is preserved.
      def begin_transaction
        @connection.transaction
        @in_transaction = true
      end

      # Guarded on the CONNECTION only, deliberately - no active-transaction check
      # is needed here.
      #
      # Python's adapter has the same shape and it IS a bug there: firebird-driver
      # delegates Connection#commit to main_transaction, whose handle is nil until
      # a statement opens one, so committing with nothing open raises
      # "AttributeError: 'NoneType' object has no attribute 'commit'". Measured
      # 2026-08-04 against the lab's real Firebird 5.0.4, the `fb` gem does NOT
      # behave that way: both #commit and #rollback on a fresh connection with no
      # open transaction return cleanly, because the driver opens one implicitly.
      #
      # So do not "port" Python's is_active? guard here on the strength of the
      # shape matching - it would be dead code guarding a condition this driver
      # cannot reach.
      def commit
        @connection&.commit
        @in_transaction = false
      end

      def rollback
        @connection&.rollback
        @in_transaction = false
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

        # The primary key comes from the constraint catalogue. This used to be
        # hardcoded `false` for every column, so primary_key(table) always
        # answered [] on Firebird -- which silently breaks anything that
        # introspects the key, including the filterless-write guard that lifts
        # the PK out of `data`. Same bug the Python master carried.
        pk_sql = "SELECT SG.RDB\$FIELD_NAME FROM RDB\$INDEX_SEGMENTS SG " \
                 "JOIN RDB\$RELATION_CONSTRAINTS RC ON SG.RDB\$INDEX_NAME = RC.RDB\$INDEX_NAME " \
                 "WHERE RC.RDB\$CONSTRAINT_TYPE = 'PRIMARY KEY' AND RC.RDB\$RELATION_NAME = ? " \
                 "ORDER BY SG.RDB\$FIELD_POSITION"
        pk_names = begin
          execute_query(pk_sql, [table_name.upcase]).map do |r|
            (r["RDB\$FIELD_NAME"] || r["rdb\$field_name"] || "").strip.upcase
          end.reject(&:empty?).to_set
        rescue StandardError
          # A table with no primary key is not an error.
          Set.new
        end

        rows.map do |r|
          field_name = (r["RDB\$FIELD_NAME"] || r["rdb\$field_name"] || "").strip
          {
            name: field_name,
            type: r["RDB\$FIELD_TYPE"] || r["rdb\$field_type"],
            nullable: (r["RDB\$NULL_FLAG"] || r["rdb\$null_flag"]).nil?,
            default: r["RDB\$DEFAULT_SOURCE"] || r["rdb\$default_source"],
            primary_key: pk_names.include?(field_name.upcase)
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
        @in_transaction = false
        open_connection
      end

      # Run a block; if it raises with a dead-connection signature, reconnect
      # once and retry. Skipped inside an explicit transaction — atomicity
      # beats resilience there; the caller handles rollback.
      def with_reconnect
        yield
      rescue StandardError => e
        raise unless self.class.dead_connection?(e) && !@in_transaction
        reconnect!
        yield
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[column_name(k.to_s)] = v }
      end

      # Firebird's stored column name, folded back only when it was folded.
      #
      # Firebird's identifier folding is ASYMMETRIC. An unquoted `AS x` is
      # stored UPPERCASE, so the driver hands back "X" where every other engine
      # Tina4 supports gives "x" -- PostgreSQL folds to lower, and MySQL, SQLite
      # and MSSQL preserve what you wrote. Portable code reading row["x"] broke
      # on Firebird alone; the live URL examples in this repo asserted row["x"]
      # and could never have passed once they actually reached a server.
      #
      # A QUOTED `AS "MyCol"` is stored exactly as written, and that case is
      # deliberate -- the caller asked for it -- so it is left alone. Folding
      # unconditionally makes a mixed-case key unreachable, the same asymmetric
      # trap that made table_exists? miss quoted tables.
      #
      # So: fold back only a name carrying no lowercase letter, the only thing
      # unquoted folding can produce. A quoted ALL-CAPS name is genuinely
      # indistinguishable from a folded one and is lowercased too; that
      # ambiguity is Firebird's, and it is the one spelling this cannot
      # round-trip.
      def column_name(raw)
        name = raw.strip
        name == name.upcase ? name.downcase : name
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
