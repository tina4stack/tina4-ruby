# frozen_string_literal: true

module Tina4
  module Drivers
    class PostgresDriver
      attr_reader :connection

      def connect(connection_string, username: nil, password: nil)
        require "pg"
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
        result.map { |row| symbolize_keys(row) }
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
        result = @connection.exec("SELECT lastval()")
        result.first["lastval"].to_i
      rescue PG::Error
        nil
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

      def tables
        sql = "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
        rows = execute_query(sql)
        rows.map { |r| r[:tablename] }
      end

      def columns(table_name)
        sql = "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = $1"
        rows = execute_query(sql, [table_name])
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
    end
  end
end
