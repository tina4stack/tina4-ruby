# frozen_string_literal: true

module Tina4
  module Drivers
    class MongodbDriver
      attr_reader :connection, :db

      def connect(connection_string, username: nil, password: nil)
        begin
          require "mongo"
        rescue LoadError
          raise LoadError,
            "The 'mongo' gem is required for MongoDB connections. " \
            "Install: gem install mongo"
        end

        uri = build_uri(connection_string, username, password)
        @db_name = extract_db_name(connection_string)
        @client = Mongo::Client.new(uri)
        @db = @client.use(@db_name)
        @connection = @db
        @last_insert_id = nil
      end

      def close
        @client&.close
        @client = nil
        @db = nil
        @connection = nil
      end

      # Execute a query (SELECT-like) and return array of symbol-keyed hashes
      def execute_query(sql, params = [])
        parsed = parse_sql(sql, params)
        collection = @db[parsed[:collection]]

        case parsed[:operation]
        when :find
          cursor = collection.find(parsed[:filter] || {})
          cursor = cursor.projection(parsed[:projection]) if parsed[:projection] && !parsed[:projection].empty?
          cursor = cursor.sort(parsed[:sort]) if parsed[:sort] && !parsed[:sort].empty?
          cursor = cursor.skip(parsed[:skip]) if parsed[:skip] && parsed[:skip] > 0
          cursor = cursor.limit(parsed[:limit]) if parsed[:limit] && parsed[:limit] > 0
          cursor.map { |doc| mongo_doc_to_hash(doc) }
        else
          []
        end
      end

      # Execute a DML statement (INSERT, UPDATE, DELETE, CREATE)
      def execute(sql, params = [])
        parsed = parse_sql(sql, params)
        collection = @db[parsed[:collection]]

        case parsed[:operation]
        when :insert
          result = collection.insert_one(parsed[:document])
          @last_insert_id = result.inserted_id.to_s
          result
        when :update
          collection.update_many(parsed[:filter] || {}, { "$set" => parsed[:updates] })
        when :delete
          collection.delete_many(parsed[:filter] || {})
        when :create_collection
          begin
            @db.command(create: parsed[:collection].to_s)
          rescue Mongo::Error::OperationFailure
            # Collection already exists — ignore
          end
          nil
        when :find
          execute_query(sql, params)
        else
          nil
        end
      end

      def last_insert_id
        @last_insert_id
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      # MongoDB has no LIMIT clause — ignore; already handled in execute_query
      def apply_limit(sql, limit, offset = 0)
        sql_up = sql.upcase
        return sql if sql_up.include?("LIMIT")
        modified = sql.dup
        modified += " LIMIT #{limit}" if limit && limit > 0
        modified += " OFFSET #{offset}" if offset && offset > 0
        modified
      end

      # MongoDB transactions require a replica set — wrap in session if available
      def begin_transaction
        # no-op for standalone; transaction support via session handled externally
      end

      def commit
        # no-op
      end

      def rollback
        # no-op
      end

      def tables
        @db.collection_names.reject { |n| n.start_with?("system.") }
      end

      def columns(table_name)
        collection = @db[table_name.to_s]
        sample = collection.find.limit(1).first
        return [] unless sample

        sample.keys.map do |key|
          {
            name: key,
            type: sample[key].class.name,
            nullable: true,
            default: nil,
            primary_key: key == "_id"
          }
        end
      end

      private

      def build_uri(connection_string, username, password)
        uri = connection_string.to_s
        # Normalise scheme: mongodb:// stays, mongo:// becomes mongodb://
        uri = uri.sub(/^mongo:\/\//, "mongodb://")

        if username || password
          # Inject credentials into the URI if not already present
          if uri =~ /^mongodb:\/\/([^@]+@)/
            # credentials already in URI — leave as-is
          else
            host_part = uri.sub(/^mongodb:\/\//, "")
            creds = [username, password ? ":#{password}" : nil].compact.join
            uri = "mongodb://#{creds}@#{host_part}"
          end
        end
        uri
      end

      def extract_db_name(connection_string)
        # mongodb://host:port/dbname  ->  dbname
        # Strip query string first
        path = connection_string.to_s.split("?").first
        db = path.split("/").last
        db && !db.empty? ? db : "tina4"
      end

      # ── SQL-to-MongoDB translator ──────────────────────────────────────

      def parse_sql(sql, params = [])
        sql_stripped = sql.strip
        upper = sql_stripped.upcase

        # Bind positional ? params
        bound_sql = bind_params(sql_stripped, params)

        if upper.start_with?("SELECT")
          parse_select(bound_sql)
        elsif upper.start_with?("INSERT INTO")
          parse_insert(bound_sql)
        elsif upper.start_with?("UPDATE")
          parse_update(bound_sql)
        elsif upper.start_with?("DELETE FROM")
          parse_delete(bound_sql)
        elsif upper.start_with?("CREATE TABLE") || upper.start_with?("CREATE COLLECTION")
          parse_create(bound_sql)
        else
          { operation: :unknown, collection: nil }
        end
      end

      def bind_params(sql, params)
        return sql if params.nil? || params.empty?

        idx = -1
        sql.gsub("?") do
          idx += 1
          v = params[idx]
          v.is_a?(String) ? "'#{v.gsub("'", "\\\\'")}'" : v.to_s
        end
      end

      # ── SELECT parsing ─────────────────────────────────────────────────

      def parse_select(sql)
        result = { operation: :find }

        # Extract table name (FROM clause)
        if (m = sql.match(/\bFROM\s+(\w+)/i))
          result[:collection] = m[1].to_sym
        else
          result[:collection] = :unknown
          return result
        end

        # Projection (columns)
        result[:projection] = parse_projection(sql)

        # WHERE clause
        where_clause = extract_clause(sql, "WHERE", %w[ORDER GROUP LIMIT OFFSET HAVING])
        result[:filter] = where_clause ? parse_where(where_clause) : {}

        # ORDER BY
        result[:sort] = parse_order_by(sql)

        # LIMIT / OFFSET
        result[:limit] = extract_limit(sql)
        result[:skip]  = extract_offset(sql)

        result
      end

      def parse_projection(sql)
        m = sql.match(/^SELECT\s+(.*?)\s+FROM\b/im)
        return {} unless m

        cols = m[1].strip
        return {} if cols == "*"

        proj = {}
        cols.split(",").each do |col|
          col = col.strip
          # Handle AS aliases — use the alias as field name
          field = col.split(/\s+AS\s+/i).first.strip
          proj[field] = 1
        end
        proj
      end

      def parse_order_by(sql)
        m = sql.match(/\bORDER\s+BY\s+(.*?)(?:\s+LIMIT|\s+OFFSET|\s*$)/im)
        return {} unless m

        sort = {}
        m[1].split(",").each do |part|
          part = part.strip
          if (pm = part.match(/^(\w+)\s+(ASC|DESC)$/i))
            sort[pm[1]] = pm[2].upcase == "DESC" ? -1 : 1
          else
            sort[part] = 1
          end
        end
        sort
      end

      def extract_limit(sql)
        m = sql.match(/\bLIMIT\s+(\d+)/i)
        m ? m[1].to_i : nil
      end

      def extract_offset(sql)
        m = sql.match(/\bOFFSET\s+(\d+)/i)
        m ? m[1].to_i : nil
      end

      # ── WHERE clause parser → Mongo filter hash ───────────────────────

      def parse_where(clause)
        clause = clause.strip
        return {} if clause.empty?

        # Handle OR at top level
        or_parts = split_top_level(clause, /\bOR\b/i)
        if or_parts.length > 1
          return { "$or" => or_parts.map { |p| parse_where(p) } }
        end

        # Handle AND at top level
        and_parts = split_top_level(clause, /\bAND\b/i)
        if and_parts.length > 1
          conditions = and_parts.map { |p| parse_where(p) }
          merged = {}
          conditions.each { |c| merged.merge!(c) }
          return merged
        end

        parse_condition(clause)
      end

      # Split a string on a regex delimiter only at top level (not inside parens)
      def split_top_level(str, delimiter_re)
        parts = []
        depth = 0
        current = ""
        tokens = str.split(/(\(|\)|\s+)/m)

        # Rebuild token stream and split on delimiter
        rebuilt = str
        # Simple approach: scan character by character
        parts = []
        current = ""
        i = 0
        while i < str.length
          ch = str[i]
          if ch == "("
            depth += 1
            current += ch
          elsif ch == ")"
            depth -= 1
            current += ch
          elsif depth == 0
            # Check for delimiter match at this position
            remaining = str[i..]
            m = remaining.match(/\A\s*#{delimiter_re.source}\s*/i)
            if m
              parts << current.strip
              current = ""
              i += m[0].length
              next
            else
              current += ch
            end
          else
            current += ch
          end
          i += 1
        end
        parts << current.strip unless current.strip.empty?
        parts.length > 1 ? parts : [str]
      end

      def parse_condition(clause)
        clause = clause.strip.gsub(/^\(+/, "").gsub(/\)+$/, "").strip

        # IS NULL / IS NOT NULL
        if (m = clause.match(/^(\w+)\s+IS\s+NOT\s+NULL$/i))
          return { m[1] => { "$ne" => nil } }
        end
        if (m = clause.match(/^(\w+)\s+IS\s+NULL$/i))
          return { m[1] => nil }
        end

        # IN (...)
        if (m = clause.match(/^(\w+)\s+IN\s*\((.+)\)$/i))
          values = m[2].split(",").map { |v| parse_value(v.strip) }
          return { m[1] => { "$in" => values } }
        end

        # NOT IN (...)
        if (m = clause.match(/^(\w+)\s+NOT\s+IN\s*\((.+)\)$/i))
          values = m[2].split(",").map { |v| parse_value(v.strip) }
          return { m[1] => { "$nin" => values } }
        end

        # LIKE → $regex
        if (m = clause.match(/^(\w+)\s+LIKE\s+'(.+)'$/i))
          pattern = m[2].gsub("%", ".*").gsub("_", ".")
          return { m[1] => { "$regex" => pattern, "$options" => "i" } }
        end

        # NOT LIKE → $not $regex
        if (m = clause.match(/^(\w+)\s+NOT\s+LIKE\s+'(.+)'$/i))
          pattern = m[2].gsub("%", ".*").gsub("_", ".")
          return { m[1] => { "$not" => /#{pattern}/i } }
        end

        # Comparison operators: !=, <>, >=, <=, >, <, =
        ops = [["!=", "$ne"], ["<>", "$ne"], [">=", "$gte"], ["<=", "$lte"],
               [">", "$gt"], ["<", "$lt"], ["=", "$eq"]]
        ops.each do |op, mongo_op|
          if (m = clause.match(/^(\w+)\s*#{Regexp.escape(op)}\s*(.+)$/i))
            field = m[1]
            value = parse_value(m[2].strip)
            if mongo_op == "$eq"
              return { field => value }
            else
              return { field => { mongo_op => value } }
            end
          end
        end

        # Fallback — return as a raw string comment (best-effort)
        {}
      end

      def parse_value(str)
        str = str.strip
        if str.start_with?("'") && str.end_with?("'")
          str[1..-2]
        elsif str =~ /\A-?\d+\z/
          str.to_i
        elsif str =~ /\A-?\d+\.\d+\z/
          str.to_f
        elsif str.upcase == "TRUE"
          true
        elsif str.upcase == "FALSE"
          false
        elsif str.upcase == "NULL"
          nil
        else
          str
        end
      end

      # ── INSERT parsing ─────────────────────────────────────────────────

      def parse_insert(sql)
        result = { operation: :insert }

        m = sql.match(/INSERT\s+INTO\s+(\w+)\s*\(([^)]+)\)\s*VALUES\s*\(([^)]+)\)/im)
        unless m
          result[:collection] = :unknown
          result[:document] = {}
          return result
        end

        result[:collection] = m[1].to_sym
        cols = m[2].split(",").map(&:strip)
        vals = parse_value_list(m[3])

        result[:document] = cols.each_with_object({}).with_index do |(col, doc), i|
          doc[col] = vals[i]
        end

        result
      end

      def parse_value_list(str)
        # Split on commas not inside quotes
        vals = []
        current = ""
        in_quote = false
        str.each_char do |ch|
          if ch == "'" && !in_quote
            in_quote = true
            current += ch
          elsif ch == "'" && in_quote
            in_quote = false
            current += ch
          elsif ch == "," && !in_quote
            vals << parse_value(current.strip)
            current = ""
          else
            current += ch
          end
        end
        vals << parse_value(current.strip) unless current.strip.empty?
        vals
      end

      # ── UPDATE parsing ─────────────────────────────────────────────────

      def parse_update(sql)
        result = { operation: :update }

        m = sql.match(/UPDATE\s+(\w+)\s+SET\s+(.+?)(?:\s+WHERE\s+(.+))?$/im)
        unless m
          result[:collection] = :unknown
          result[:updates] = {}
          result[:filter] = {}
          return result
        end

        result[:collection] = m[1].to_sym

        # Parse SET assignments
        updates = {}
        set_clause = m[2].strip
        # Split on comma, skip commas inside quotes
        assignments = split_assignments(set_clause)
        assignments.each do |assign|
          parts = assign.split("=", 2)
          next unless parts.length == 2

          key = parts[0].strip
          val = parse_value(parts[1].strip)
          updates[key] = val
        end
        result[:updates] = updates

        # Parse WHERE
        where_str = m[3]&.strip
        result[:filter] = where_str && !where_str.empty? ? parse_where(where_str) : {}

        result
      end

      def split_assignments(set_clause)
        parts = []
        current = ""
        in_quote = false
        set_clause.each_char do |ch|
          if ch == "'" && !in_quote
            in_quote = true
            current += ch
          elsif ch == "'" && in_quote
            in_quote = false
            current += ch
          elsif ch == "," && !in_quote
            parts << current.strip
            current = ""
          else
            current += ch
          end
        end
        parts << current.strip unless current.strip.empty?
        parts
      end

      # ── DELETE parsing ─────────────────────────────────────────────────

      def parse_delete(sql)
        result = { operation: :delete }

        m = sql.match(/DELETE\s+FROM\s+(\w+)(?:\s+WHERE\s+(.+))?$/im)
        unless m
          result[:collection] = :unknown
          result[:filter] = {}
          return result
        end

        result[:collection] = m[1].to_sym
        where_str = m[2]&.strip
        result[:filter] = where_str && !where_str.empty? ? parse_where(where_str) : {}

        result
      end

      # ── CREATE TABLE parsing ───────────────────────────────────────────

      def parse_create(sql)
        m = sql.match(/CREATE\s+(?:TABLE|COLLECTION)\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)/im)
        {
          operation: :create_collection,
          collection: m ? m[1].to_sym : :unknown
        }
      end

      # ── Extract a named clause from SQL ───────────────────────────────

      def extract_clause(sql, clause_keyword, stop_keywords = [])
        pattern_parts = stop_keywords.map { |kw| "\\b#{kw}\\b" }.join("|")
        stop_pattern = pattern_parts.empty? ? "$" : "(?:#{pattern_parts}|$)"
        m = sql.match(/\b#{clause_keyword}\s+(.*?)(?=\s*#{stop_pattern})/im)
        m ? m[1].strip : nil
      end

      # ── Document conversion ────────────────────────────────────────────

      def mongo_doc_to_hash(doc)
        doc.each_with_object({}) do |(k, v), h|
          key = k.to_s == "_id" ? :_id : k.to_s.to_sym
          h[key] = v.is_a?(BSON::ObjectId) ? v.to_s : v
        end
      end
    end
  end
end
