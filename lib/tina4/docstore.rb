# frozen_string_literal: true

# Tina4 DocStore - pymongo-style document storage with a zero-config SQLite fallback.
#
# A document store with the everyday Mongo collection API, backed by SQLite's
# JSON1 extension when no MongoDB server is configured.
#
#     require "tina4"
#
#     orders = Tina4::DocStore.get_collection("orders")  # SqliteCollection when no Mongo
#     oid = orders.insert_one({ "customer_id" => 1, "total" => 9.99 }).inserted_id
#     orders.find({ "customer_id" => { "$in" => [1, 2] } }).sort("created_at", -1).limit(10).each do |o|
#       # ...
#     end
#     orders.update_one({ "_id" => oid }, { "$set" => { "status" => "shipped" } })
#
# get_collection(name) returns a real Mongo driver collection when a Mongo URI
# is configured (TINA4_MONGO_URI, else TINA4_SESSION_MONGO_URI - the same env
# vars the queue/session Mongo backends read), and otherwise a SqliteCollection
# backed by a local SQLite file. This mirrors the file-based fallbacks the
# queue, cache, and session subsystems already provide: an app that talks to
# Mongo in production runs serverless in local dev with no code change - only
# the backend differs.
#
# Design (the SQLite backend):
#   - Each collection is a table (_id TEXT PRIMARY KEY, doc TEXT); doc is JSON.
#   - Query filters are pushed down to SQL over json_extract(doc, '$.field')
#     (indexed + lazy, not a full in-memory scan), supporting equality, $in/$nin,
#     $gt/$gte/$lt/$lte, $ne, $exists, $regex, and implicit-AND / $or / $and.
#   - Updates: $set, $unset, $inc, and full-document replace.
#   - Cursors: sort / limit / skip / projection.
#   - IDs are a built-in 12-byte ObjectId (zero-dependency; interchangeable with
#     a Mongo ObjectId as a 24-hex string).
#
# Type round-trip is by value, not by wrapper object, so json_extract stays
# queryable and sortable: a Time is stored as an ISO-8601 UTC string and an
# ObjectId as its 24-hex string, and reads rehydrate a strict-ISO string back to
# Time and a 24-hex string back to ObjectId. That keeps range queries and sorts
# working on date and id fields - the trade-off (a plain 24-hex / ISO string
# becomes an ObjectId / Time on read) is acceptable for the local dev store.
#
# Deliberate non-goals: aggregation pipeline, $elemMatch, geo. This is the
# everyday CRUD + filter subset, not full Mongo parity. The operator set matches
# the Python master exactly.

require "json"
require "time"
require "securerandom"

module Tina4
  module DocStore
    # Raised when a value cannot be parsed as an ObjectId.
    class InvalidId < ArgumentError; end

    OID_RE = /\A[0-9a-fA-F]{24}\z/.freeze
    ISO_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\z/.freeze

    # A 12-byte MongoDB-style ObjectId, with no external dependency.
    #
    # Layout: 4-byte big-endian seconds since epoch, 5-byte per-process random,
    # 3-byte big-endian counter. Renders as a 24-char hex string, so it is
    # interchangeable with a Mongo ObjectId wherever the string form is used.
    class ObjectId
      @counter = SecureRandom.random_number(0xFFFFFF)
      @process = SecureRandom.random_bytes(5)
      @lock = Mutex.new

      class << self
        attr_reader :lock

        def next_counter
          @lock.synchronize { @counter = (@counter + 1) & 0xFFFFFF }
        end

        def process_bytes = @process

        def valid?(value)
          new(value)
          true
        rescue InvalidId, TypeError
          false
        end
      end

      attr_reader :bytes

      def initialize(oid = nil)
        case oid
        when nil
          @bytes = generate
        when ObjectId
          @bytes = oid.bytes
        when String
          if oid.bytesize == 12 && oid.encoding == Encoding::ASCII_8BIT && !oid.match?(OID_RE)
            @bytes = oid.dup
          elsif oid.match?(OID_RE)
            @bytes = [oid].pack("H*")
          else
            raise InvalidId, "#{oid.inspect} is not a valid 24-character hex ObjectId"
          end
        else
          raise InvalidId, "cannot make an ObjectId from #{oid.class}"
        end
      end

      # 4-byte time + 5-byte random + 3-byte counter.
      def generate
        ts = [Time.now.to_i].pack("N")               # 4-byte big-endian
        counter = [self.class.next_counter].pack("N")[1, 3]  # low 3 bytes big-endian
        ts + self.class.process_bytes + counter
      end

      def generation_time
        ts = @bytes[0, 4].unpack1("N")
        Time.at(ts).utc
      end

      def to_s = @bytes.unpack1("H*")

      def inspect = "ObjectId('#{self}')"

      def ==(other)
        other.is_a?(ObjectId) && other.bytes == @bytes
      end
      alias eql? ==

      def hash = @bytes.hash
    end

    module_function

    # -- Value encoding: keep scalars queryable, rehydrate types on read --------

    def iso(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%S") +
        (time.getutc.subsec.zero? ? "" : format(".%06d", time.getutc.usec)) + "Z"
    end

    # Ruby value -> JSON-serialisable, sortable scalar form (for storage/queries).
    def encode_value(value)
      case value
      when ObjectId then value.to_s
      when Time     then iso(value)
      when Hash     then value.each_with_object({}) { |(k, v), h| h[k.to_s] = encode_value(v) }
      when Array    then value.map { |v| encode_value(v) }
      else value
      end
    end

    # Stored JSON value -> Ruby, rehydrating ObjectId (24-hex) and Time (ISO).
    def decode_value(value)
      case value
      when String
        if value.match?(OID_RE)
          ObjectId.new(value)
        elsif value.match?(ISO_RE)
          begin
            Time.parse(value)
          rescue ArgumentError
            value
          end
        else
          value
        end
      when Hash  then value.each_with_object({}) { |(k, v), h| h[k] = decode_value(v) }
      when Array then value.map { |v| decode_value(v) }
      else value
      end
    end

    # Canonical string key for the _id column.
    def id_key(value)
      case value
      when ObjectId then value.to_s
      when Time     then iso(value)
      else value.to_s
      end
    end

    # -- Query translation: Mongo filter Hash -> SQL WHERE over json_extract ----

    COMPARATORS = { "$gt" => ">", "$gte" => ">=", "$lt" => "<", "$lte" => "<=" }.freeze

    # Field name -> a JSON path. Dotted names address nested keys.
    def json_path(field)
      segments = field.to_s.split(".").map do |s|
        s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? s : "\"#{s}\""
      end
      "$." + segments.join(".")
    end

    def extract(field) = "json_extract(doc, '#{json_path(field)}')"

    def json_type(field) = "json_type(doc, '#{json_path(field)}')"

    # A rowset over the field: one row per element of an array, one for a scalar.
    def json_each(field) = "json_each(doc, '#{json_path(field)}')"

    # True when the field is an ARRAY and any element satisfies +condition+.
    #
    # MongoDB's rule for an array-valued field is that a condition matches when
    # ANY ELEMENT matches it. json_each yields one row per element, so EXISTS is
    # the direct translation.
    #
    # The `= 'array'` guard is load-bearing: json_each over an OBJECT iterates
    # its VALUES, and Mongo never matches an object field against one of its
    # values - {"obj" => "x"} must NOT match {"obj" => {"city" => "x"}}.
    def any_element(field, condition)
      "(#{json_type(field)} = 'array' AND EXISTS (SELECT 1 FROM #{json_each(field)} WHERE #{condition}))"
    end

    # Compile `field == operand` under Mongo's array rule -> [sql, params].
    def equality(field, operand)
      ex = extract(field)
      return ["#{ex} IS NULL", []] if operand.nil?

      # An Array or Hash operand compares against the WHOLE value, never
      # element-wise: {"tags" => ["x","y"]} is exact-array equality.
      return ["#{ex} = ?", [bind(operand)]] if operand.is_a?(Array) || operand.is_a?(Hash)

      ["(#{ex} = ? OR #{any_element(field, "value = ?")})", [bind(operand), bind(operand)]]
    end

    # Compile `field OP operand` under Mongo's array rule -> [sql, params].
    #
    # The `<> 'array'` guard on the scalar branch removes a measured FALSE
    # POSITIVE: json_extract of an array returns its JSON TEXT, and SQLite sorts
    # any text above any number, so {"nums" => {"$gt" => 9}} matched [1,2,3].
    def compare(field, sql_op, operand)
      ex = extract(field)
      ["((#{json_type(field)} <> 'array' AND #{ex} #{sql_op} ?) OR #{any_element(field, "value #{sql_op} ?")})",
       [bind(operand), bind(operand)]]
    end

    # Compile a Mongo-style filter Hash into [sql_fragment, params].
    # Returns ["1=1", []] for an empty filter. Supports implicit AND across keys,
    # $or / $and, and the per-field operator set.
    def compile_filter(query)
      return ["1=1", []] if query.nil? || query.empty?

      clauses = []
      params = []
      query.each do |key, value|
        key = key.to_s
        if key == "$or" || key == "$and"
          joiner = key == "$or" ? " OR " : " AND "
          subs = []
          Array(value).each do |sub|
            frag, p = compile_filter(sub)
            subs << "(#{frag})"
            params.concat(p)
          end
          clauses << "(#{subs.join(joiner)})" unless subs.empty?
          next
        end

        if value.is_a?(Hash) && !value.empty? && value.keys.all? { |k| k.to_s.start_with?("$") }
          value.each do |op, operand|
            frag, p = compile_op(key, op.to_s, operand)
            clauses << frag
            params.concat(p)
          end
        else
          # equality - the same helper $eq uses, so the array rule applies
          # whether the filter reads {"tags" => "x"} or {"tags" => {"$eq" => "x"}}
          frag, p = equality(key, value)
          clauses << frag
          params.concat(p)
        end
      end

      [clauses.empty? ? "1=1" : clauses.join(" AND "), params]
    end

    def compile_op(field, op, operand)
      ex = extract(field)
      return compare(field, COMPARATORS[op], operand) if COMPARATORS.key?(op)

      case op
      when "$eq"
        equality(field, operand)
      when "$ne"
        return ["#{ex} IS NOT NULL", []] if operand.nil?

        sql, p = equality(field, operand)
        # A MISSING field satisfies $ne in Mongo, and SQL's NOT(NULL) is NULL
        # rather than true - so the IS NULL arm is required, not decoration.
        ["(NOT (#{sql}) OR #{ex} IS NULL)", p]
      when "$in"
        items = Array(operand)
        return ["0", []] if items.empty?

        placeholders = (["?"] * items.length).join(",")
        bound = items.map { |v| bind(v) }
        ["(#{ex} IN (#{placeholders}) OR #{any_element(field, "value IN (#{placeholders})")})", bound + bound]
      when "$nin"
        items = Array(operand)
        return ["1", []] if items.empty?

        placeholders = (["?"] * items.length).join(",")
        bound = items.map { |v| bind(v) }
        ["(NOT (#{ex} IN (#{placeholders}) OR #{any_element(field, "value IN (#{placeholders})")}) OR #{ex} IS NULL)",
         bound + bound]
      when "$exists"
        # json_type is NULL when the path is absent; present-but-null still has a type.
        [operand ? "#{json_type(field)} IS NOT NULL" : "#{json_type(field)} IS NULL", []]
      when "$regex"
        pattern = operand.is_a?(Hash) ? operand["$regex"].to_s : operand.to_s
        ["((#{json_type(field)} <> 'array' AND #{ex} REGEXP ?) OR #{any_element(field, "value REGEXP ?")})",
         [pattern, pattern]]
      else
        raise ArgumentError, "DocStore: unsupported query operator #{op.inspect}"
      end
    end

    # Bind a Ruby value for comparison against json_extract output.
    def bind(value)
      case value
      when true then 1
      when false then 0
      when ObjectId, Time then encode_value(value)
      when Integer, Float, String, nil then value
      else JSON.generate(encode_value(value))
      end
    end

    # REGEXP user function body, registered on the SQLite connection.
    def regexp_match(pattern, value)
      return 0 if value.nil?

      begin
        Regexp.new(pattern.to_s).match?(value.to_s) ? 1 : 0
      rescue RegexpError
        0
      end
    end

    # -- Projection / update helpers --------------------------------------------

    def project(doc, projection)
      return doc if projection.nil? || projection.empty?

      proj = projection.transform_keys(&:to_s)
      include_keys = proj.select { |k, v| truthy?(v) && k != "_id" }.keys
      exclude_keys = proj.reject { |_k, v| truthy?(v) }.keys

      unless include_keys.empty?
        out = {}
        include_keys.each { |k| out[k] = doc[k] if doc.key?(k) }
        out["_id"] = doc["_id"] if proj.fetch("_id", 1) && doc.key?("_id") && truthy?(proj.fetch("_id", 1))
        return out
      end

      doc.reject { |k, _v| exclude_keys.include?(k) }
    end

    def truthy?(value)
      !(value.nil? || value == false || value == 0)
    end

    def apply_update(doc, update)
      update = update.transform_keys(&:to_s)
      unless update.keys.any? { |k| k.start_with?("$") }
        # Full-document replace (keep the existing _id).
        new_doc = deep_string_keys(update)
        new_doc["_id"] = doc["_id"] unless new_doc.key?("_id")
        return new_doc
      end

      new_doc = doc.dup
      update.each do |op, fields|
        case op
        when "$set"
          fields.each { |k, v| set_path(new_doc, k.to_s, v) }
        when "$unset"
          fields.each_key { |k| unset_path(new_doc, k.to_s) }
        when "$inc"
          fields.each { |k, v| set_path(new_doc, k.to_s, (get_path(new_doc, k.to_s) || 0) + v) }
        else
          raise ArgumentError, "DocStore: unsupported update operator #{op.inspect}"
        end
      end
      new_doc
    end

    def deep_string_keys(value)
      case value
      when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_string_keys(v) }
      when Array then value.map { |v| deep_string_keys(v) }
      else value
      end
    end

    def set_path(doc, dotted, value)
      parts = dotted.split(".")
      node = doc
      parts[0...-1].each do |p|
        node[p] = {} unless node[p].is_a?(Hash)
        node = node[p]
      end
      node[parts[-1]] = value
    end

    def unset_path(doc, dotted)
      parts = dotted.split(".")
      node = doc
      parts[0...-1].each do |p|
        node = node[p]
        return unless node.is_a?(Hash)
      end
      node.delete(parts[-1]) if node.is_a?(Hash)
    end

    def get_path(doc, dotted)
      parts = dotted.split(".")
      node = doc
      parts.each do |p|
        return nil unless node.is_a?(Hash)

        node = node[p]
      end
      node
    end

    # -- Result wrappers ---------------------------------------------------------

    InsertOneResult  = Struct.new(:inserted_id)
    InsertManyResult = Struct.new(:inserted_ids)
    UpdateResult     = Struct.new(:matched_count, :modified_count, :upserted_id)
    DeleteResult     = Struct.new(:deleted_count)

    # -- Cursor ----------------------------------------------------------------

    # Lazy result cursor. Builds and runs SQL only when iterated.
    class Cursor
      include Enumerable

      def initialize(collection, where, params, projection = nil)
        @collection = collection
        @where = where
        @params = params
        @projection = projection
        @sort = []
        @limit = nil
        @skip = 0
      end

      def sort(key_or_list, direction = 1)
        if key_or_list.is_a?(String) || key_or_list.is_a?(Symbol)
          @sort << [key_or_list.to_s, direction]
        else
          key_or_list.each { |k, d| @sort << [k.to_s, d] }
        end
        self
      end

      def limit(num)
        @limit = num.to_i
        self
      end

      def skip(num)
        @skip = num.to_i
        self
      end

      def build_sql
        sql = "SELECT doc FROM #{@collection.quoted_name} WHERE #{@where}"
        unless @sort.empty?
          order = @sort.map { |k, d| "#{DocStore.extract(k)} #{d.to_i.negative? ? 'DESC' : 'ASC'}" }.join(", ")
          sql += " ORDER BY #{order}"
        end
        if @limit
          sql += " LIMIT #{@limit.to_i}"
          sql += " OFFSET #{@skip.to_i}" if @skip.positive?
        elsif @skip.positive?
          sql += " LIMIT -1 OFFSET #{@skip.to_i}"
        end
        sql
      end

      def each
        return enum_for(:each) unless block_given?

        @collection.connection.execute(build_sql, @params).each do |row|
          doc_text = row.is_a?(Hash) ? (row["doc"] || row[:doc] || row.values.first) : row.first
          yield @collection.load_doc(doc_text, @projection)
        end
      end

      def to_a
        out = []
        each { |doc| out << doc }
        out
      end
      alias to_list to_a
    end

    # -- Collection -------------------------------------------------------------

    # A SQLite-backed collection exposing the everyday Mongo API.
    class SqliteCollection
      attr_reader :connection

      def initialize(conn, name)
        @connection = conn
        @name = name.to_s
        raise ArgumentError, "DocStore: invalid collection name #{name.inspect}" unless @name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        @quoted_name = "\"#{@name}\""
        @connection.execute(
          "CREATE TABLE IF NOT EXISTS #{@quoted_name} (_id TEXT PRIMARY KEY, doc TEXT NOT NULL)"
        )
      end

      def quoted_name = @quoted_name

      # -- helpers --
      def dump(document) = JSON.generate(DocStore.encode_value(document))

      def load_doc(doc_text, projection = nil)
        doc = DocStore.decode_value(JSON.parse(doc_text))
        projection ? DocStore.project(doc, projection) : doc
      end

      # -- writes --
      def insert_one(document)
        doc = stringify(document)
        doc["_id"] = ObjectId.new unless doc.key?("_id")
        @connection.execute(
          "INSERT INTO #{@quoted_name} (_id, doc) VALUES (?, ?)",
          [DocStore.id_key(doc["_id"]), dump(doc)]
        )
        InsertOneResult.new(doc["_id"])
      end

      def insert_many(documents)
        ids = []
        documents.each do |document|
          doc = stringify(document)
          doc["_id"] = ObjectId.new unless doc.key?("_id")
          ids << doc["_id"]
          @connection.execute(
            "INSERT INTO #{@quoted_name} (_id, doc) VALUES (?, ?)",
            [DocStore.id_key(doc["_id"]), dump(doc)]
          )
        end
        InsertManyResult.new(ids)
      end

      # -- reads --
      def find(filter = nil, projection = nil)
        where, params = DocStore.compile_filter(filter || {})
        Cursor.new(self, where, params, projection)
      end

      # NOTE: there is deliberately no find_one here. Mongo::Collection has no
      # such method, and ADR-0025 makes the driver the shape this fallback
      # imitates - a fallback-only accessor is how code comes to be written
      # against a spelling that vanishes the moment TINA4_MONGO_URI is set.
      # The spelling that works on BOTH providers is find(filter).first.

      def count_documents(filter = nil)
        where, params = DocStore.compile_filter(filter || {})
        row = @connection.execute("SELECT count(*) AS c FROM #{@quoted_name} WHERE #{where}", params).first
        scalar(row).to_i
      end

      def estimated_document_count
        row = @connection.execute("SELECT count(*) AS c FROM #{@quoted_name}").first
        scalar(row).to_i
      end

      def distinct(key, filter = nil)
        seen = []
        find(filter).each do |doc|
          v = doc[key.to_s]
          seen << v unless seen.include?(v)
        end
        seen
      end

      # -- updates (filter pushed to SQL; mutation applied per matched doc) --
      def update_one(filter, update, upsert: false)
        rows = matching_rows(filter, limit: 1)
        if rows.empty?
          return do_upsert(filter, update) if upsert

          return UpdateResult.new(0, 0, nil)
        end
        old_id, doc_text = rows.first
        doc = DocStore.decode_value(JSON.parse(doc_text))
        new_doc = DocStore.apply_update(doc, update)
        modified = write_back(old_id, new_doc)
        UpdateResult.new(1, modified ? 1 : 0, nil)
      end

      def update_many(filter, update, upsert: false)
        rows = matching_rows(filter)
        return do_upsert(filter, update) if rows.empty? && upsert

        matched = 0
        modified = 0
        rows.each do |old_id, doc_text|
          matched += 1
          doc = DocStore.decode_value(JSON.parse(doc_text))
          new_doc = DocStore.apply_update(doc, update)
          modified += 1 if write_back(old_id, new_doc)
        end
        UpdateResult.new(matched, modified, nil)
      end

      def replace_one(filter, replacement, upsert: false)
        rows = matching_rows(filter, limit: 1)
        if rows.empty?
          if upsert
            doc = stringify(replacement)
            doc["_id"] = ObjectId.new unless doc.key?("_id")
            insert_one(doc)
            return UpdateResult.new(0, 0, doc["_id"])
          end
          return UpdateResult.new(0, 0, nil)
        end
        old_id, doc_text = rows.first
        doc = stringify(replacement)
        doc["_id"] = DocStore.decode_value(JSON.parse(doc_text))["_id"] unless doc.key?("_id")
        write_back(old_id, doc)
        UpdateResult.new(1, 1, nil)
      end

      # -- deletes --
      def delete_one(filter)
        rows = matching_rows(filter, limit: 1)
        return DeleteResult.new(0) if rows.empty?

        @connection.execute("DELETE FROM #{@quoted_name} WHERE _id = ?", [rows.first.first])
        DeleteResult.new(1)
      end

      def delete_many(filter)
        where, params = DocStore.compile_filter(filter || {})
        before = count_documents(filter)
        @connection.execute("DELETE FROM #{@quoted_name} WHERE #{where}", params)
        DeleteResult.new(before)
      end

      def drop
        @connection.execute("DROP TABLE IF EXISTS #{@quoted_name}")
      end

      private

      def stringify(document)
        document.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end

      def matching_rows(filter, limit: nil)
        where, params = DocStore.compile_filter(filter || {})
        sql = "SELECT _id, doc FROM #{@quoted_name} WHERE #{where}"
        sql += " LIMIT #{limit.to_i}" if limit
        @connection.execute(sql, params).map do |row|
          if row.is_a?(Hash)
            [row["_id"] || row[:_id], row["doc"] || row[:doc]]
          else
            [row[0], row[1]]
          end
        end
      end

      def write_back(old_id, new_doc)
        new_key = DocStore.id_key(new_doc["_id"])
        @connection.execute(
          "UPDATE #{@quoted_name} SET _id = ?, doc = ? WHERE _id = ?",
          [new_key, dump(new_doc), old_id]
        )
        true
      end

      def do_upsert(filter, update)
        # Seed a document from the filter's equality terms, then apply the update.
        seed = {}
        (filter || {}).each do |k, v|
          k = k.to_s
          seed[k] = v unless k.start_with?("$") || v.is_a?(Hash)
        end
        doc = DocStore.apply_update(seed, update)
        doc["_id"] = ObjectId.new unless doc.key?("_id")
        insert_one(doc)
        UpdateResult.new(0, 0, doc["_id"])
      end

      def scalar(row)
        return 0 if row.nil?
        return (row["c"] || row[:c] || row.values.first) if row.is_a?(Hash)

        row.first
      end
    end

    # -- Database + selection -----------------------------------------------------

    # A SQLite-backed document database (a file of collection tables).
    class SqliteDatabase
      attr_reader :path

      def initialize(path = nil)
        @path = path || ENV["TINA4_DOC_STORE_PATH"] || "data/tina4_docstore.db"
        require "sqlite3"
        if @path != ":memory:"
          dir = File.dirname(@path)
          require "fileutils"
          FileUtils.mkdir_p(dir) unless dir.empty? || dir == "." || File.directory?(dir)
        end
        @conn = SQLite3::Database.new(@path)
        # Register the REGEXP user function for the $regex operator.
        @conn.create_function("regexp", 2) do |func, pattern, value|
          func.result = DocStore.regexp_match(pattern, value)
        end
        @collections = {}
      end

      def connection = @conn

      def get_collection(name)
        @collections[name.to_s] ||= SqliteCollection.new(@conn, name)
      end
      alias [] get_collection

      def list_collection_names
        @conn.execute(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ).map { |row| row.is_a?(Hash) ? (row["name"] || row[:name] || row.values.first) : row.first }
      end

      def close
        @conn.close
      end
    end

    module_function

    # The configured Mongo URI, reusing the app-wide queue/session env vars.
    # Canonical TINA4_SESSION_MONGO_URI; TINA4_SESSION_MONGO_URL is a legacy alias.
    def mongo_uri
      (ENV["TINA4_MONGO_URI"] ||
       ENV["TINA4_SESSION_MONGO_URI"] ||
       ENV["TINA4_SESSION_MONGO_URL"] ||
       "").strip
    end

    # True when no Mongo is configured, so the SQLite fallback is in effect.
    def serverless?
      return true if mongo_uri.empty?

      begin
        require "mongo"
        false
      rescue LoadError
        # A URI is set but the driver is absent: degrade to the local store
        # rather than crash.
        true
      end
    end

    @default_db = nil
    @default_lock = Mutex.new

    def default_db
      return @default_db if @default_db

      @default_lock.synchronize do
        @default_db ||= SqliteDatabase.new
      end
    end

    # Return a collection for `name`.
    #
    # A real Mongo driver Collection when a Mongo URI is configured (and the
    # mongo gem is installed); otherwise a SqliteCollection backed by the local
    # SQLite file. Same call sites either way - only the backend differs.
    def get_collection(name)
      return default_db.get_collection(name) if serverless?

      db_name = ENV["TINA4_MONGO_DB"] || ENV["TINA4_SESSION_MONGO_DB"] || "tina4"
      mongo_client(mongo_uri, db_name)[name]
    end

    @mongo_clients = {}

    # Return the shared Mongo client for this (uri, database), connecting once.
    #
    # MEASURED 2026-08-03 against a real MongoDB: get_collection used to build a
    # new Mongo::Client on EVERY call and never close it, so 20 calls left 60
    # server connections open and the count grew without bound. It was invisible
    # in development because the SQLite fallback has no connections at all - a
    # resource leak that only exists AFTER the swap to the real provider.
    #
    # A Mongo::Client is thread-safe and pools internally, so one per
    # (uri, database) is the shape the driver itself expects. The double-checked
    # lock matches default_db above: without it two threads racing the first call
    # both build a client and one is orphaned - the same leak, just rarer.
    def mongo_client(uri, db_name)
      require "mongo"
      key = [uri, db_name]
      client = @mongo_clients[key]
      return client if client

      @default_lock.synchronize do
        @mongo_clients[key] ||= Mongo::Client.new(uri, database: db_name)
      end
    end

    # Close every DocStore connection: the SQLite store and all Mongo clients.
    def close_doc_store
      @default_lock.synchronize do
        @mongo_clients.each_value do |client|
          client.close
        rescue StandardError
          nil # a close failure must not mask the caller's work
        end
        @mongo_clients.clear
        @default_db&.close
        @default_db = nil
      end
    end

    # Drop the cached default SQLite store (test helper).
    def reset_default_store
      @default_lock.synchronize do
        @default_db&.close
        @default_db = nil
      end
    end
  end
end
