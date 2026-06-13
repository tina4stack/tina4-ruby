# frozen_string_literal: true

require_relative "schema_split"

module Tina4
  module Drivers
    class PostgresDriver
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
        @connection = PG.connect(url)
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
        result.map { |row| decode_blobs(symbolize_keys(row)) }
      end

      def execute(sql, params = [])
        converted_sql = convert_placeholders(sql)
        if params.empty?
          @connection.exec(converted_sql)
        else
          @connection.exec_params(converted_sql, params)
        end
      end

      def last_insert_id
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

      def apply_limit(sql, limit, offset = 0)
        "#{sql} LIMIT #{limit} OFFSET #{offset}"
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
        sql = "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = $1 AND table_schema = $2"
        rows = execute_query(sql, [tbl, schema])
        rows.map do |r|
          {
            name: r[:column_name],
            type: r[:data_type],
            nullable: r[:is_nullable] == "YES",
            default: r[:column_default],
            primary_key: false
          }
        end
      end

      private

      def convert_placeholders(sql)
        counter = 0
        sql.gsub("?") { counter += 1; "$#{counter}" }
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
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
