# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class PostgresDriver
      # Postgres, MySQL, MSSQL and ODBC all REQUIRE a name for a derived
      # table, so the COUNT probe in Database#count_probe wraps as
      # `FROM (sql) AS _count_query`. SQLite and Firebird do not define
      # this and get no alias - Firebird rejects `AS` in that position.
      def count_subquery_alias
        "_count_query"
      end

      include Tina4::DatabaseAdapter
      include SchemaSplit
      attr_reader :connection

      def connect(connection_string, username: nil, password: nil)
        begin
          require "pg"
        rescue LoadError
          raise LoadError,
                "The 'pg' gem is required for PostgreSQL connections. Install one of:\n" \
                "    bundle add pg     # if your project uses Bundler\n" \
                "    gem install pg    # bare driver"
        end
        url = connection_string
        if username || password
          uri = URI.parse(url)
          uri.user = username if username
          uri.password = password if password
          url = uri.to_s
        end
        # libpq's OWN connect_timeout, in whole seconds. MEASURED: it bounds the
        # entire connect INCLUDING the startup handshake - 3.01s against a
        # TCPServer that accepts and never replies, where the same connect with
        # no bound sat past 20s and needed SIGKILL. An operator who spelled
        # connect_timeout in the URL themselves keeps their value.
        seconds = Tina4::DatabaseAdapter.connect_timeout_whole_seconds
        seconds = nil if url.include?("connect_timeout=")
        # Host/port for the timeout message only. A libpq keyword/value conninfo
        # string is not a URL and simply yields nil here, which is fine.
        target = begin
          URI.parse(url)
        rescue URI::Error
          nil
        end
        Tina4::DatabaseAdapter.bounding_connect(target&.host, target&.port || 5432) do
          @connection = seconds ? PG.connect(url, connect_timeout: seconds) : PG.connect(url)
        end
        apply_result_type_map(@connection)
        @connection
      end

      def close
        @connection&.close
      end

      def execute_query(sql, params = [])
        converted_sql = convert_placeholders(sql)
        result = if params.empty?
                   @connection.exec(converted_sql)
                 else
                   @connection.exec_params(converted_sql, params)
                 end
        track_affected(result)
        symbolize_result(result)
      end

      def execute(sql, params = [])
        # Issue #256: a bare INSERT run through execute() (not #insert, so no
        # RETURNING captured) must NOT let a previously-captured RETURNING id
        # leak into a later last_insert_id() — that would surface a stale id
        # (e.g. a UUID string from an earlier db.insert) for this new write.
        # Clear the cache so last_insert_id falls back to the lastval() probe,
        # which is the correct source for a sequence-backed bare INSERT.
        @last_returning_id = nil if sql.lstrip[0, 6].upcase == "INSERT"
        converted_sql = convert_placeholders(sql)
        result = if params.empty?
                   @connection.exec(converted_sql)
                 else
                   @connection.exec_params(converted_sql, params)
                 end
        track_affected(result)
        result
      end

      # Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
      #
      # Feeds Database#update/delete's DatabaseResult.affected_rows. The driver
      # exposed NO such method, so write_affected fell through to its default of
      # 0 and an UPDATE that really changed a row reported affected_rows = 0 —
      # indistinguishable from "matched nothing". Parity with SQLite
      # (connection.changes), MySQL (stmt.affected_rows) and the Python master
      # (cursor.rowcount).
      def affected_rows
        @affected_rows.to_i
      end

      # Issue #256: surface the ACTUAL primary key value an INSERT wrote —
      # including a server-generated UUID — instead of guessing it from a
      # session sequence after the fact.
      #
      # Before this, Database#insert ran a bare INSERT and then probed
      # ``last_insert_id`` (``SELECT lastval()``). For a UUID PK
      # (``id uuid PRIMARY KEY DEFAULT gen_random_uuid()``) there is no
      # session sequence, so the probe returned nil — or, worse, a STALE
      # integer left over from an unrelated SERIAL table's nextval() earlier
      # in the same session (a silently WRONG id). The SERIAL integer path was
      # correct only by luck of lastval() pointing at the right sequence.
      #
      # Fix (mirrors the Python master's ``INSERT ... RETURNING *`` and the
      # Node adapter): append ``RETURNING *`` and read the generated ``id``
      # back from the returned row. The value is normalised so the SERIAL path
      # keeps returning an Integer while a UUID PK surfaces its real 36-char
      # string. No lastval() probe, so the issue-#38 transaction-abort can't
      # happen on this path at all.
      #
      # Returns { success: true, last_id: <id-or-nil> }. last_id is nil only
      # when the table truly has no ``id`` column.
      def insert(table, data)
        columns = data.keys.map(&:to_s)
        placeholders = placeholders(columns.length)
        sql = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders}) RETURNING *"
        result = execute_query(sql, data.values)
        row = result.is_a?(Array) ? result.first : nil
        id = normalize_returned_id(row)
        # Remember the real id so a follow-up #last_insert_id / db.get_last_id
        # surfaces THIS value (incl. a UUID string) instead of re-probing
        # lastval(), which has no sequence for a UUID PK and would return a
        # stale wrong integer from an unrelated table.
        @last_returning_id = id
        { success: true, last_id: id }
      end

      def last_insert_id
        # Issue #256: if the most recent write surfaced its real primary key
        # through ``RETURNING *`` (the #insert path), return that — it is the
        # actual id written (a UUID string stays a string, a SERIAL stays an
        # integer), not a guess. Only fall back to the lastval() probe below
        # when nothing has been captured yet (e.g. a bare
        # ``execute("INSERT ...")`` with no RETURNING).
        return @last_returning_id unless @last_returning_id.nil?

        # Issue #38: ``SELECT lastval()`` raises on tables with no sequence
        # (UUID, ULID, hash PKs etc.). The exception itself isn't fatal,
        # but the pg gem marks the whole transaction as aborted, so every
        # subsequent statement on this connection fails with
        # ``PG::InFailedSqlTransaction`` — far away from the real cause.
        #
        # Fix: wrap the probe in a SAVEPOINT. If ``lastval()`` raises, we
        # ROLLBACK TO SAVEPOINT and the outer transaction stays usable;
        # ``last_insert_id`` just returns ``nil`` (same as before for
        # tables without a sequence). On success we RELEASE SAVEPOINT.
        begin
          @connection.exec("SAVEPOINT _t4_lastval_probe")
        rescue PG::Error
          # No active transaction (autocommit/idle) — fall back to a plain
          # probe; psycopg2-style transaction abort can't happen here.
          begin
            result = @connection.exec("SELECT lastval()")
            return result.first["lastval"].to_i
          rescue PG::Error
            return nil
          end
        end

        begin
          result = @connection.exec("SELECT lastval()")
          @connection.exec("RELEASE SAVEPOINT _t4_lastval_probe")
          result.first["lastval"].to_i
        rescue PG::Error
          begin
            @connection.exec("ROLLBACK TO SAVEPOINT _t4_lastval_probe")
            @connection.exec("RELEASE SAVEPOINT _t4_lastval_probe")
          rescue PG::Error
            # If even the rollback fails, there's nothing we can do — the
            # connection is in a state we can't recover. Surface nil so
            # callers don't get a half-set last_id.
          end
          nil
        end
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (1..count).map { |i| "$#{i}" }.join(", ")
      end

      # NEW LINE, not a space — appended inline the clause lands inside a
      # trailing `-- comment` and the engine ignores it (see the note on
      # Drivers::SqliteDriver#apply_limit).
      def apply_limit(sql, limit, offset = 0)
        "#{sql}\nLIMIT #{limit} OFFSET #{offset}"
      end

      def begin_transaction
        @connection.exec("BEGIN")
      end

      def commit
        @connection.exec("COMMIT")
      end

      def rollback
        @connection.exec("ROLLBACK")
      end

      # v3.13.14 (#48): to_regclass resolves a (possibly schema-qualified)
      # relation name and search_path like a FROM clause; nil if absent.
      def table_exists?(name)
        rows = execute_query("SELECT to_regclass($1) AS oid", [name.to_s])
        !rows.empty? && !rows[0][:oid].nil?
      end

      # ADR-0044 required adapter capability.
      def get_database_type
        "postgres"
      end

      def tables
        # v3.13.14 (#48): list every user schema; public tables stay bare,
        # others are returned schema-qualified.
        sql = "SELECT schemaname, tablename FROM pg_tables " \
              "WHERE schemaname NOT IN ('pg_catalog', 'information_schema') " \
              "ORDER BY schemaname, tablename"
        rows = execute_query(sql)
        rows.map { |r| r[:schemaname] == "public" ? r[:tablename] : "#{r[:schemaname]}.#{r[:tablename]}" }
      end

      def columns(table_name)
        # v3.13.14 (#48): honour a schema-qualified name; default to public.
        schema, tbl = split_schema(table_name)
        schema ||= "public"
        # :primary_key was hardcoded false, so Database#primary_key introspected
        # NOTHING on PostgreSQL. The filterless-write guard (feature 4) reads it,
        # so `update(table, data)` keyed on the primary key in `data` raised
        # "update requires a filter or the complete primary key in the data"
        # against every PostgreSQL table. Port the Python master's LEFT JOIN so
        # the cross-engine columns() contract (#48) actually holds here — the
        # subquery yields every column of the PK, so a COMPOSITE key reports
        # true on each of its columns, not just the first.
        sql = <<~SQL
          SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
                 CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END AS is_primary
          FROM information_schema.columns c
          LEFT JOIN (
            SELECT ku.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage ku
              ON tc.constraint_name = ku.constraint_name
             AND tc.table_schema = ku.table_schema
            WHERE tc.table_name = $1 AND tc.table_schema = $2
              AND tc.constraint_type = 'PRIMARY KEY'
          ) pk ON c.column_name = pk.column_name
          WHERE c.table_name = $3 AND c.table_schema = $4
          ORDER BY c.ordinal_position
        SQL
        rows = execute_query(sql, [tbl, schema, tbl, schema])
        rows.map do |r|
          {
            name: r[:column_name],
            type: r[:data_type],
            nullable: r[:is_nullable] == "YES",
            default: r[:column_default],
            # The result type map decodes bool to true/false, but stay tolerant
            # of the raw "t"/"f" text form if the map could not be built.
            primary_key: r[:is_primary] == true || r[:is_primary] == "t"
          }
        end
      end

      private

      # Record the row count of a WRITE so #affected_rows can report it.
      #
      # Gated on the command tag rather than recorded for every statement: a
      # SELECT's cmd_tuples is its ROW COUNT, so tracking it unconditionally
      # would let an ordinary read overwrite the count of the write before it.
      # SQLite's connection.changes has exactly this "last write wins, reads
      # don't touch it" semantic, and Database#write_affected reads the count
      # immediately after the write, so the two agree.
      def track_affected(result)
        tag = result.cmd_status.to_s
        return unless tag.start_with?("INSERT", "UPDATE", "DELETE", "MERGE")

        @affected_rows = result.cmd_tuples.to_i
      rescue PG::Error, NoMethodError
        # A result that cannot report its status leaves the previous count
        # alone rather than zeroing a real one.
        nil
      end

      # Issue #256: normalise the ``id`` of an ``INSERT ... RETURNING *`` row.
      #
      # The result-type map already decodes a SERIAL/int8 ``id`` to an Integer
      # and a ``uuid`` ``id`` to a String, so the value usually arrives in the
      # right shape. We still coerce defensively (mirrors the Node adapter's
      # ``normalizeId``): a numeric String becomes an Integer so the SERIAL path
      # always returns the integer id, while a non-numeric String — the UUID PK
      # case — is preserved verbatim. A row with no ``id`` column (or a
      # blank/nil id) yields nil.
      def normalize_returned_id(row)
        return nil unless row

        value = row_id_value(row)
        case value
        when Integer
          value
        when Numeric
          value
        when String
          stripped = value.strip
          return nil if stripped.empty?
          # A purely numeric string is a SERIAL id surfaced as text — coerce
          # to Integer. Anything else (a UUID, a ULID, a composite key) stays
          # the string it is.
          stripped.match?(/\A-?\d+\z/) ? stripped.to_i : value
        else
          value.nil? ? nil : value
        end
      end

      # Read the ``id`` column from a RETURNING row regardless of key style
      # (symbol/string, any case) — execute_query symbolizes keys, but stay
      # tolerant.
      def row_id_value(row)
        return nil unless row.is_a?(Hash)

        row[:id] || row["id"] || row[:ID] || row["ID"]
      end

      # Decode result columns to native Ruby types (parity with SQLite, and
      # with Python psycopg2 / Node node-postgres which both return native
      # types). Without this the pg gem hands back EVERY column as a String —
      # ``id: "1"``, ``active: "t"``, timestamps as strings — so an app
      # written on SQLite silently changes behaviour on PostgreSQL.
      #
      # PG::BasicTypeMapForResults decodes by column OID:
      #   int2/int4/int8/serial -> Integer
      #   bool                  -> true / false
      #   float4/float8         -> Float
      #   numeric               -> BigDecimal
      #   timestamp/timestamptz -> Time
      #   date                  -> Date
      #   text/varchar          -> String (unchanged)
      #
      # The map is set on the *connection*, so it applies uniformly to both
      # ``exec`` and ``exec_params`` and therefore to every fetch / fetch_one /
      # columns path that flows through execute_query.
      #
      # uuid / json / jsonb / regclass have no built-in coder; left alone the
      # map prints a noisy "no type cast defined" warning to stderr and falls
      # back to a raw string anyway. We register explicit text decoders for them
      # so they stay plain strings (the documented behaviour) without the
      # warning — regclass matters because table_exists? selects to_regclass().
      # bytea is already handled by the map as an ASCII-8BIT binary string,
      # which is what decode_blobs expects.
      def apply_result_type_map(conn)
        type_map = PG::BasicTypeMapForResults.new(conn)
        register_text_decoders(conn, type_map, %w[uuid json jsonb regclass])
        conn.type_map_for_results = type_map
      rescue PG::Error, NameError
        # If the type map can't be built (e.g. a minimal pg build without
        # BasicTypeMapForResults, or a connection that can't resolve OIDs),
        # leave results as strings rather than breaking the connection.
        nil
      end

      # Register a plain-text decoder for each named PostgreSQL type so the
      # result map returns it unchanged as a String instead of warning that no
      # cast is defined. Unknown type names are skipped silently.
      def register_text_decoders(conn, type_map, type_names)
        type_names.each do |name|
          oid = conn.exec_params("SELECT $1::regtype::oid", [name]).getvalue(0, 0).to_i
          type_map.add_coder(PG::TextDecoder::String.new(oid: oid, name: name, format: 0))
        rescue PG::Error
          next
        end
      end

      def convert_placeholders(sql)
        counter = 0
        sql.gsub("?") { counter += 1; "$#{counter}" }
      end

      # Hydrate a PG::Result into an array of symbol-keyed row hashes.
      #
      # The old path did `result.map { |row| decode_blobs(symbolize_keys(row)) }`,
      # which made the pg gem build a string-keyed Hash PER ROW and then rebuilt
      # each as symbol-keyed with a per-cell `k.to_sym` -- two hashes per row plus
      # N symbol conversions per row. This reads directly from `each_row` (the gem
      # yields positional String arrays, no per-row Hash) against the field names
      # symbolised ONCE for the whole result. Measured on real PostgreSQL 16.14,
      # a 5,000-row x 7-column fetch went 13.84ms -> 7.55ms (-45%) with
      # byte-identical output (values are the same String forms `map` produced,
      # e.g. "t" for a boolean, nil for NULL). Duplicate column names from a JOIN
      # collapse last-wins, exactly as the gem's own row Hash did.
      #
      # decode_blobs stays per-row: it inspects values, not keys, so it cannot be
      # hoisted. It is currently a documented no-op (pg returns bytea as raw
      # ASCII-8BIT strings); keeping the call preserves the seam.
      def symbolize_result(result)
        fields = result.fields.map(&:to_sym)
        count = fields.length
        rows = []
        result.each_row do |values|
          row = {}
          i = 0
          while i < count
            row[fields[i]] = values[i]
            i += 1
          end
          rows << decode_blobs(row)
        end
        rows
      end

      # Ensure binary (bytea) columns are proper byte strings.
      # PostgreSQL's pg gem returns bytea as ASCII-8BIT encoded strings —
      # they're already raw bytes, just tag them so Ruby treats them right.
      def decode_blobs(row)
        # No conversion needed — pg gem returns bytea as ASCII-8BIT strings
        # which are raw bytes. Users can .force_encoding("UTF-8") for text
        # BLOBs or use the bytes directly for binary data.
        row
      end
    end
  end
end
