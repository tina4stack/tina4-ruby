# frozen_string_literal: true

module Tina4
  module Drivers
    class MongodbDriver
      include Tina4::DatabaseAdapter
      attr_reader :connection, :db

      def connect(connection_string, username: nil, password: nil)
        begin
          require "mongo"
        rescue LoadError
          raise LoadError,
                "The 'mongo' gem is required for MongoDB connections. Install one of:\n" \
                "    bundle add mongo     # if your project uses Bundler\n" \
                "    gem install mongo    # bare driver"
        end

        uri = build_uri(connection_string, username, password)
        @db_name = extract_db_name(connection_string)
        # The mongo driver's OWN connect_timeout, in seconds. It already bounds
        # itself - MEASURED: Mongo::Client.new against a TCPServer that accepts
        # and never replies returns after 10.02s, the gem's hard-coded default -
        # so this makes it honour the Tina4 variable instead. A URI that spells
        # connectTimeoutMS itself keeps that value. No bounding_connect wrapper:
        # Client.new does NOT raise on an unreachable server (server selection
        # happens later, on the first operation), so there is no expiry to name.
        seconds = Tina4::DatabaseAdapter.connect_timeout_seconds
        options = {}
        options[:connect_timeout] = seconds if seconds && !uri.include?("connectTimeoutMS")
        @client = Mongo::Client.new(uri, options)
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
          # parse_update guarantees a scoped filter (or it raised) — no || {} fallback.
          collection.update_many(parsed[:filter], { "$set" => parsed[:updates] })
        when :delete
          # parse_delete guarantees a scoped filter (or it raised) — no || {} fallback.
          collection.delete_many(parsed[:filter])
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

      # Atomic, monotonic, concurrency-safe next id — feature 16. A
      # findOneAndUpdate($inc) on the tina4_sequences collection, keyed by _id
      # (its built-in unique index makes concurrent first-use upserts race-safe:
      # two callers can never create two counters for one table). Seeds from
      # MAX(pk_column) the FIRST time only ($setOnInsert). Raises on an
      # impossible empty result rather than returning a fixed id that could
      # collide with an existing row.
      def get_next_id(table, pk_column = "id")
        sequences = @db["tina4_sequences"]
        seq_name = "#{table}.#{pk_column}"

        if sequences.find("_id" => seq_name).first.nil?
          seed = 0
          begin
            max_doc = @db[table.to_s].find.sort(pk_column => -1).limit(1).first
            seed = max_doc[pk_column].to_i if max_doc && max_doc[pk_column]
          rescue StandardError
            # Collection may not exist yet — seed 0.
          end
          begin
            sequences.update_one(
              { "_id" => seq_name },
              { "$setOnInsert" => { "current_value" => seed } },
              upsert: true
            )
          rescue StandardError
            # Race — another caller seeded first; the atomic $inc below still holds.
          end
        end

        doc = sequences.find_one_and_update(
          { "_id" => seq_name },
          { "$inc" => { "current_value" => 1 } },
          return_document: :after,
          upsert: true
        )
        if doc.nil? || doc["current_value"].nil?
          raise "get_next_id: MongoDB counter '#{seq_name}' produced no value"
        end

        doc["current_value"].to_i
      end

      def placeholder
        "?"
      end

      def placeholders(count)
        (["?"] * count).join(", ")
      end

      # MongoDB has no LIMIT clause — ignore; already handled in execute_query
      # Uses the SAME detector as Database#fetch (scrubbed + anchored to the end)
      # instead of its own naive `sql.upcase.include?("LIMIT")`, which mistook a
      # column named rate_limit or a `'LIMIT'` literal for a real clause and
      # returned the statement uncapped. Appends on a NEW LINE so a trailing
      # `-- comment` cannot swallow the clause.
      def apply_limit(sql, limit, offset = 0)
        return sql if Tina4::Database.has_trailing_limit?(sql)
        modified = sql.dup
        modified += "\nLIMIT #{limit}" if limit && limit > 0
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

      # ADR-0044 required adapter capability.
      def get_database_type
        'mongodb'
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

        # Explicit 1=1 tautology -- the WHERE clause truncate() passes -- means
        # MATCH-ALL: translate it to an empty {} filter so truncate() empties the
        # collection, exactly as PHP already does. Without this, "1 = 1" fell
        # through to the "=" comparison below and parsed as { "1" => 1 }, which
        # matches NOTHING, so a truncate() silently deleted 0 documents while the
        # caller believed the collection was emptied. This does NOT weaken the
        # fail-closed guard: 1=1 is an EXPLICIT tautology, distinct from an
        # unparseable WHERE (the raise at the end of this method still fires) and
        # from a blank/absent WHERE (which require_where_for_write still rejects).
        return {} if clause.match?(/\A1\s*=\s*1\z/)

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

        # Fail closed. An unrecognised condition must NEVER degrade to an empty
        # (match-all) filter: on a DELETE/UPDATE that empty filter reaches
        # delete_many({})/update_many({}) and wipes or rewrites the WHOLE
        # collection. Raise so the caller sees the unsupported SQL instead of
        # silently losing data.
        raise ArgumentError,
              "Unsupported MongoDB WHERE condition: #{clause.inspect}. The MongoDB " \
              "SQL provider fails closed rather than matching every document. " \
              "Supported: = != <> > >= < <= LIKE, NOT LIKE, IN, NOT IN, " \
              "IS [NOT] NULL, AND, OR."
      end

      # Fail closed: a DELETE/UPDATE must carry a WHERE clause.
      #
      # A missing or blank WHERE translates to an empty MongoDB filter, which
      # matches EVERY document, so delete_many({})/update_many({}) would wipe or
      # rewrite the whole collection. Refuse it. The explicit whole-collection
      # spelling is truncate() (it passes WHERE 1 = 1); the native driver via
      # #connection is the escape hatch for anything the SQL subset cannot
      # express. Shared by both write paths so the guard cannot drift.
      def require_where_for_write(where_str, operation, collection)
        return unless where_str.nil? || where_str.strip.empty?

        raise ArgumentError,
              "Refusing to #{operation} every document in '#{collection}': the " \
              "statement has no WHERE clause, which would affect the whole " \
              "collection. Add a WHERE, or use truncate() to clear it explicitly."
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
          raise ArgumentError, "MongodbDriver: cannot parse UPDATE statement: #{sql}"
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

        # Parse WHERE — refuse a filterless UPDATE (would rewrite the whole collection).
        where_str = m[3]&.strip
        require_where_for_write(where_str, "UPDATE", result[:collection])
        result[:filter] = parse_where(where_str)

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
          raise ArgumentError, "MongodbDriver: cannot parse DELETE statement: #{sql}"
        end

        result[:collection] = m[1].to_sym
        # Refuse a filterless DELETE (would empty the whole collection).
        where_str = m[2]&.strip
        require_where_for_write(where_str, "DELETE", result[:collection])
        result[:filter] = parse_where(where_str)

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
