# frozen_string_literal: true

module Tina4
  module Drivers
    class FirebirdDriver
      attr_reader :connection

      def connect(connection_string)
        require "fb"
        db_path = connection_string.sub(/^firebird:\/\//, "")
        @connection = Fb::Database.new(database: db_path).connect
      rescue LoadError
        raise "Firebird driver requires the 'fb' gem. Install it with: gem install fb"
      end

      def close
        @connection&.close
      end

      def execute_query(sql, params = [])
        if params.empty?
          @connection.query(:hash, sql)
        else
          @connection.query(:hash, sql, *params)
        end.map { |row| stringify_keys(row) }
      end

      def execute(sql, params = [])
        if params.empty?
          @connection.execute(sql)
        else
          @connection.execute(sql, *params)
        end
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

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end
  end
end
