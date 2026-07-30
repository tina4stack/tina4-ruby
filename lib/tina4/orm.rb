# frozen_string_literal: true
require "json"

module Tina4
  # Convert a snake_case name to camelCase.
  def self.snake_to_camel(name)
    parts = name.to_s.split("_")
    parts[0] + parts[1..].map(&:capitalize).join
  end

  # Convert a camelCase name to snake_case.
  def self.camel_to_snake(name)
    name.to_s.gsub(/([A-Z])/) { "_#{$1.downcase}" }.sub(/^_/, "")
  end

  # Singularize a plural relationship name to derive a class name.
  #
  # has_many :posts → "Post", has_many :categories → "Category". The old
  # derivation was a naive sub(/s$/) that turned "categories" into
  # "Categorie" — a NameError waiting to happen. This handles the common
  # English plural endings before falling back to stripping a trailing "s".
  # (When class_name: is passed explicitly, this is never consulted.)
  def self.singularize(word)
    s = word.to_s
    if s =~ /ies\z/i
      s.sub(/ies\z/i, "y")
    elsif s =~ /(ss|sh|ch|x|z)es\z/i
      s.sub(/es\z/i, "")
    elsif s =~ /s\z/i && s !~ /ss\z/i
      s.sub(/s\z/i, "")
    else
      s
    end
  end

  class ORM
    include Tina4::FieldTypes

    # When a new model class is defined, resolve any deferred ForeignKeyField
    # wiring that targets it. The string / forward-reference form of
    # `foreign_key_field` (e.g. `references: "Author"`) records the has_many
    # side in @@_fk_registry but cannot wire it until the referenced class
    # actually loads — which is now. Without this hook apply_fk_registry! was
    # never called, so the has_many side silently never wired. The class body
    # (where the model's own foreign_key_field declarations run, populating the
    # registry) executes AFTER inherited returns, so entries keyed on THIS
    # class were already recorded by earlier-loaded models. Chain through super
    # so we never clobber a future inherited hook.
    def self.inherited(subclass)
      super
      (@_model_subclasses ||= []) << subclass
      subclass.apply_fk_registry! if subclass.respond_to?(:apply_fk_registry!, true)
    end

    # Every Tina4::ORM subclass that has been loaded, in definition order.
    # Mirrors Python's ORM.__subclasses__() — used to resolve string-form
    # ForeignKeyField references to a live class.
    def self.model_subclasses
      @_model_subclasses ||= []
    end

    class << self
      def db
        # Resolution order:
        #   1. @db is a Symbol/String → named connection from Tina4.databases
        #      (bound via Tina4.bind_database(db, name:)). Raises a clear
        #      error if that named connection was never registered.
        #   2. @db is a Database/driver instance → use it directly.
        #   3. Otherwise → global Tina4.database, else env-derived
        #      auto-discovery (TINA4_DATABASE_URL). v3.13.12 wired this
        #      fallback; before that auto_discover_db was never called.
        case @db
        when Symbol, String
          name = @db.to_sym
          Tina4.databases[name] || raise(
            "Tina4 named database connection '#{@db}' is not registered for #{name}. " \
            "Call Tina4.bind_database(db, name: #{@db.inspect}) before using this model."
          )
        when nil
          Tina4.database || auto_discover_db
        else
          @db
        end
      end

      # Per-model database binding.
      #   self.db = some_database_instance   → use that connection
      #   self.db = :analytics               → resolve a named connection
      #                                         from Tina4.databases at access time
      def db=(database)
        @db = database
      end

      # Soft delete configuration
      def soft_delete
        @soft_delete || false
      end

      def soft_delete=(val)
        @soft_delete = val
      end

      def soft_delete_field
        @soft_delete_field || :is_deleted
      end

      def soft_delete_field=(val)
        @soft_delete_field = val
      end

      # Field mapping: { 'db_column' => 'ruby_attribute' }
      def field_mapping
        @field_mapping || {}
      end

      def field_mapping=(map)
        @field_mapping = map
      end

      # Auto-map flag — defaults to TRUE for cross-framework parity (Python's
      # ORM has auto_map=True by default). The instance variable is treated
      # as "unset" when nil; only an explicit `false` disables it.
      #
      # INERT IN RUBY, DELIBERATELY. Nothing reads this flag: Ruby is
      # snake_case-native, so the attribute name a developer writes IS the
      # column name and there is nothing for a case mapping to do. It exists
      # only so a model ported from PHP (where `autoMap` really does map a
      # camelCase property onto a snake_case column) does not blow up on an
      # unknown setter. Setting it either way changes NOTHING.
      #
      # This is not an oversight to "fix" by adding conversion: the owner's
      # naming rule (2026-07-29) is that the column name must mirror the
      # DATABASE, and a language-specific case mapping may only ever be an
      # OPT-IN. Adding camel->snake here by default would be that mapping, on
      # by default, which is the opposite. Use `field_mapping` to point an
      # attribute at a differently-named column — that is the supported
      # mechanism, and spec/orm_column_case_spec.rb pins all of this so the
      # flag cannot quietly grow behaviour later.
      def auto_map
        defined?(@auto_map) && !@auto_map.nil? ? @auto_map : true
      end

      def auto_map=(val)
        @auto_map = val
      end

      # auto_crud flag — when set to true, the class registers itself with
      # Tina4::AutoCrud which auto-generates REST endpoints from the model.
      # Defaults to false. Cross-framework parity with Python's autoCrud.
      def auto_crud
        defined?(@auto_crud) && !@auto_crud.nil? ? @auto_crud : false
      end

      def auto_crud=(val)
        @auto_crud = val
        if val && defined?(::Tina4::AutoCrud)
          ::Tina4::AutoCrud.models << self unless ::Tina4::AutoCrud.models.include?(self)
        end
      end

      # Relationship definitions
      def relationship_definitions
        @relationship_definitions ||= {}
      end

      # has_one :profile, class_name: "Profile", foreign_key: "user_id"
      def has_one(name, class_name: nil, foreign_key: nil)
        relationship_definitions[name] = {
          type: :has_one,
          class_name: class_name || name.to_s.split("_").map(&:capitalize).join,
          foreign_key: foreign_key
        }

        define_method(name) do
          load_has_one(name)
        end
      end

      # has_many :posts, class_name: "Post", foreign_key: "user_id"
      def has_many(name, class_name: nil, foreign_key: nil)
        relationship_definitions[name] = {
          type: :has_many,
          # Derive the target class from the (plural) relationship name via a
          # proper singularizer — "posts" → "Post", "categories" → "Category"
          # — instead of the naive sub(/s$/) that produced "Categorie". The FK
          # auto-wire path (foreign_key_field) always passes class_name:
          # explicitly, so this default only applies to a hand-written has_many.
          class_name: class_name || Tina4.singularize(name).split("_").map(&:capitalize).join,
          foreign_key: foreign_key
        }

        define_method(name) do
          load_has_many(name)
        end
      end

      # belongs_to :user, class_name: "User", foreign_key: "user_id"
      def belongs_to(name, class_name: nil, foreign_key: nil)
        relationship_definitions[name] = {
          type: :belongs_to,
          class_name: class_name || name.to_s.split("_").map(&:capitalize).join,
          foreign_key: foreign_key || "#{name}_id"
        }

        define_method(name) do
          load_belongs_to(name)
        end
      end

      # Create a fluent QueryBuilder pre-configured for this model's table and database.
      #
      # Usage:
      #   results = User.query.where("active = ?", [1]).order_by("name").get
      #
      # @return [Tina4::QueryBuilder]
      def query
        QueryBuilder.from_table(table_name, db: db)
      end

      def find(id_or_filter = nil, filter = nil, **kwargs)
        include_list = kwargs.delete(:include)

        # find(id) — find by primary key
        # find(filter_hash) — find by criteria
        # find(name: "Alice") — keyword args as filter hash
        result = if id_or_filter.is_a?(Hash)
          find_by_filter(id_or_filter)
        elsif filter.is_a?(Hash)
          find_by_filter(filter)
        elsif !kwargs.empty?
          find_by_filter(kwargs)
        else
          find_by_id(id_or_filter)
        end

        if include_list && result
          instances = result.is_a?(Array) ? result : [result]
          eager_load(instances, include_list)
        end
        result
      end

      # Eager load relationships for a collection of instances (prevents N+1).
      # include is an array of relationship names, supporting dot notation for nesting.
      def eager_load(instances, include_list)
        return if instances.nil? || instances.empty?

        # Group includes: top-level and nested
        top_level = {}
        include_list.each do |inc|
          parts = inc.to_s.split(".", 2)
          rel_name = parts[0].to_sym
          top_level[rel_name] ||= []
          top_level[rel_name] << parts[1] if parts.length > 1
        end

        top_level.each do |rel_name, nested|
          rel = relationship_definitions[rel_name]
          next unless rel

          klass = Object.const_get(rel[:class_name])
          pk = primary_key_field || :id

          case rel[:type]
          when :has_one, :has_many
            fk = rel[:foreign_key] || "#{name.split('::').last.downcase}_id"
            pk_values = instances.map { |inst| inst.__send__(pk) }.compact.uniq
            next if pk_values.empty?

            placeholders = pk_values.map { "?" }.join(",")
            sql = "SELECT * FROM #{klass.table_name} WHERE #{fk} IN (#{placeholders})"
            results = klass.db.fetch(sql, pk_values)
            related_records = results.map { |row| klass.from_hash(row) }

            # Eager load nested
            klass.eager_load(related_records, nested) unless nested.empty?

            # Group by FK
            grouped = {}
            related_records.each do |record|
              fk_val = record.__send__(fk.to_sym) if record.respond_to?(fk.to_sym)
              (grouped[fk_val] ||= []) << record
            end

            instances.each do |inst|
              pk_val = inst.__send__(pk)
              records = grouped[pk_val] || []
              if rel[:type] == :has_one
                inst.instance_variable_get(:@relationship_cache)[rel_name] = records.first
              else
                inst.instance_variable_get(:@relationship_cache)[rel_name] = records
              end
            end

          when :belongs_to
            fk = rel[:foreign_key] || "#{rel_name}_id"
            fk_values = instances.map { |inst|
              inst.respond_to?(fk.to_sym) ? inst.__send__(fk.to_sym) : nil
            }.compact.uniq
            next if fk_values.empty?

            related_pk = klass.primary_key_field || :id
            placeholders = fk_values.map { "?" }.join(",")
            sql = "SELECT * FROM #{klass.table_name} WHERE #{related_pk} IN (#{placeholders})"
            results = klass.db.fetch(sql, fk_values)
            related_records = results.map { |row| klass.from_hash(row) }

            klass.eager_load(related_records, nested) unless nested.empty?

            lookup = {}
            related_records.each { |r| lookup[r.__send__(related_pk)] = r }

            instances.each do |inst|
              fk_val = inst.respond_to?(fk.to_sym) ? inst.__send__(fk.to_sym) : nil
              inst.instance_variable_get(:@relationship_cache)[rel_name] = lookup[fk_val]
            end
          end
        end
      end

      def where(conditions, params = [], limit: 100, offset: nil, order_by: nil, include: nil)
        sql = "SELECT * FROM #{table_name}"
        if soft_delete
          sql += " WHERE (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0) AND (#{conditions})"
        else
          sql += " WHERE #{conditions}"
        end
        sql += " ORDER BY #{order_by}" if order_by
        results = db.fetch(sql, params, limit: limit, offset: offset)
        instances = results.map { |row| from_hash(row) }
        eager_load(instances, include) if include
        instances
      end

      def all(limit: 100, offset: nil, order_by: nil, include: nil)
        sql = "SELECT * FROM #{table_name}"
        if soft_delete
          sql += " WHERE #{soft_delete_field} IS NULL OR #{soft_delete_field} = 0"
        end
        sql += " ORDER BY #{order_by}" if order_by
        results = db.fetch(sql, [], limit: limit, offset: offset)
        instances = results.map { |row| from_hash(row) }
        eager_load(instances, include) if include
        instances
      end

      def select(sql, params = [], limit: 100, offset: nil, include: nil)
        results = db.fetch(sql, params, limit: limit, offset: offset)
        instances = results.map { |row| from_hash(row) }
        eager_load(instances, include) if include
        instances
      end

      def select_one(sql, params = [], include: nil)
        results = select(sql, params, limit: 1, include: include)
        results.first
      end

      # The ONE process-wide query cache, shared by every model.
      #
      # The Python master holds this as a module-level `_query_cache =
      # Cache(default_ttl=0, max_size=500)` in orm/model.py, so every model shares
      # a single store. A plain `@query_cache ||=` here would NOT be that
      # contract: `class << self` ivars are per-class, so each subclass would get
      # its own cache and User.clear_cache would silently leave Order's entries
      # alone. Anchoring the ivar on ORM itself keeps one store for all models,
      # however deep the subclass.
      def query_cache
        ORM.instance_variable_get(:@query_cache) ||
          ORM.instance_variable_set(:@query_cache, QueryCache.new(default_ttl: 0, max_size: 500))
      end

      # SQL query with result caching. Returns an array of ORM instances.
      #
      # Parity with the Python master's `cached` (orm/model.py:1077): same key
      # shape, same tag, and a miss delegates to `select` so eager loading and the
      # row cap behave identically to an uncached read.
      #
      # Entries are tagged with the model name so #clear_cache invalidates only
      # this model's queries and leaves every other model's cached reads intact.
      def cached(sql, params = [], ttl: 60, limit: 100, offset: nil, include: nil)
        key = "#{name}:#{QueryCache.query_key(sql, params)}:#{limit}:#{offset || 0}"

        # nil-check, NOT a truthiness check: a query that legitimately returns no
        # rows caches an empty array, and that is a HIT. Treating it as a miss
        # would re-run the query on every call for exactly the queries where
        # caching pays off most.
        hit = query_cache.get(key)
        return hit unless hit.nil?

        result = select(sql, params, limit: limit, offset: offset, include: include)
        query_cache.set(key, result, ttl: ttl, tags: [name])
        result
      end

      # Invalidate every cached query for THIS model. Tag-scoped, so it never
      # flushes another model's entries. Mirrors the master's
      # `_query_cache.clear_tag(cls.__name__)`.
      def clear_cache
        query_cache.clear_tag(name)
        nil
      end

      def count(conditions = nil, params = [])
        sql = "SELECT COUNT(*) as cnt FROM #{table_name}"
        where_parts = []
        if soft_delete
          where_parts << "(#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0)"
        end
        where_parts << "(#{conditions})" if conditions
        sql += " WHERE #{where_parts.join(' AND ')}" unless where_parts.empty?
        result = db.fetch_one(sql, params)
        result[:cnt].to_i
      end

      # Create a new instance, save it, and return it.
      #
      # Returns the saved instance on success. v3.13.39: if the underlying #save
      # fails (validation errors or a driver error), create returns false — it
      # does NOT hand back a possibly-unsaved instance, so a failed insert can
      # never masquerade as a success. The failure cause is logged and available
      # on the (discarded) instance's #get_error via the same path save uses.
      # Parity with the Python master.
      def create(attributes = {})
        instance = new(attributes)
        return false if instance.save == false
        instance
      end

      def find_or_fail(id)
        result = find(id)
        raise "#{name} with #{primary_key_field || :id}=#{id} not found" if result.nil?
        result
      end

      def with_trashed(conditions = "1=1", params = [], limit: 100, offset: 0)
        sql = "SELECT * FROM #{table_name} WHERE #{conditions}"
        results = db.fetch(sql, params, limit: limit, offset: offset)
        results.map { |row| from_hash(row) }
      end

      def create_table
        return true if db.table_exists?(table_name)

        # v3.13.16: engine-aware DDL. Ruby used to emit SQLite-only DDL on
        # every driver — INTEGER for booleans, DATETIME for datetimes, and a
        # raw AUTOINCREMENT keyword — then ignore db.execute()'s return value
        # and report success. On PostgreSQL the CREATE blew up
        # ("syntax error at or near AUTOINCREMENT"), db.execute() swallowed it
        # into get_error() and returned false, yet create_table still returned
        # true with no table created — a silent, misleading pass.
        #
        # The fix mirrors the Python reference (tina4_python.orm.model):
        #   • get_database_type() now exists on Database (it didn't before, so
        #     the v3.13.11 BooleanField check never actually fired on Ruby).
        #   • BooleanField → native BOOLEAN (PG/MySQL) / BIT (MSSQL) /
        #     INTEGER (sqlite, firebird) — both PG aliases are matched.
        #   • DateTimeField → TIMESTAMP on PG/Firebird (neither has a DATETIME
        #     type), DATETIME elsewhere.
        #   • boolean DEFAULT is engine-aware: TRUE/FALSE for a native BOOLEAN,
        #     1/0 for INTEGER/BIT-backed bools.
        #   • AUTOINCREMENT is translated per engine via SQLTranslator
        #     (SERIAL on PG, AUTO_INCREMENT on MySQL, IDENTITY on MSSQL, dropped
        #     on Firebird) instead of being emitted raw.
        #   • return false (not true) when the DDL fails.
        engine = (db.respond_to?(:get_database_type) ? db.get_database_type : "").to_s.downcase

        bool_sql = case engine
                   when "postgres", "postgresql" then "BOOLEAN"
                   when "mysql" then "BOOLEAN" # alias for TINYINT(1)
                   when "mssql", "sqlserver" then "BIT"
                   else "INTEGER" # sqlite, firebird, odbc, anything else
                   end

        # PostgreSQL and Firebird have no DATETIME type — CREATE TABLE fails
        # with `type "datetime" does not exist`. Emit each engine's real
        # timestamp type. (MySQL/MSSQL/SQLite keep DATETIME: valid there, and
        # on MySQL it avoids TIMESTAMP's auto-update + 2038 surprises.)
        datetime_sql = case engine
                       when "postgres", "postgresql", "firebird" then "TIMESTAMP"
                       else "DATETIME"
                       end

        # Engine-aware JSON column type (parity with the Python master's
        # JSONField DDL). PostgreSQL gets native JSONB (indexable, canonical);
        # MySQL native JSON; MSSQL stores JSON as NVARCHAR(MAX) (its JSON
        # functions read that); Firebird has no TEXT type so it uses a text
        # BLOB; SQLite and everything else store the JSON text in TEXT
        # (queryable via json1).
        json_sql = case engine
                   when "postgres", "postgresql" then "JSONB"
                   when "mysql" then "JSON"
                   when "mssql", "sqlserver" then "NVARCHAR(MAX)"
                   when "firebird" then "BLOB SUB_TYPE TEXT"
                   else "TEXT"
                   end

        type_map = {
          integer: "INTEGER",
          string: "VARCHAR(255)",
          text: "TEXT",
          float: "REAL",
          decimal: "REAL",
          boolean: bool_sql,
          date: "DATE",
          datetime: datetime_sql,
          timestamp: "TIMESTAMP",
          blob: "BLOB",
          json: json_sql
        }

        col_defs = []
        field_definitions.each do |name, opts|
          sql_type = type_map[opts[:type]] || "TEXT"
          if opts[:type] == :string && opts[:length]
            sql_type = "VARCHAR(#{opts[:length]})"
          end

          parts = ["#{name} #{sql_type}"]
          # A COMPOSITE key is declared ONCE, at table level (below). An inline
          # PRIMARY KEY per column is invalid DDL - SQLite, PostgreSQL and MySQL
          # all reject two of them in one table, so a composite-key model could
          # not create its own table at all.
          parts << "PRIMARY KEY" if opts[:primary_key] && primary_key_fields.length == 1
          parts << "AUTOINCREMENT" if opts[:auto_increment]
          parts << "NOT NULL" if !opts[:nullable] && !opts[:primary_key]
          # A JSON column carries no DDL DEFAULT (parity with the Python master):
          # a dict/list default is an application-level concern, applied per
          # instance, not a portable SQL literal (PG needs a ::jsonb cast, MySQL
          # an expression default). The instance still gets its default at new.
          # A callable default (e.g. `datetime_field :created_at, default: -> { Time.now }`)
          # is resolved per-row at instance creation; it must NOT reach the DDL, where
          # default_literal would stringify the Proc to `DEFAULT #<Proc:...>` — invalid
          # SQL that silently fails table creation (parity with the Python master, #61).
          callable_default = opts[:default].respond_to?(:call) && !opts[:default].is_a?(Class)
          if opts[:default] && !opts[:auto_increment] && opts[:type] != :json && !callable_default
            parts << "DEFAULT #{default_literal(opts[:default], opts[:type], bool_sql)}"
          end
          col_defs << parts.join(" ")
        end

        # A COMPOSITE key is declared ONCE, at table level; the per-column inline
        # form above is suppressed for it.
        if primary_key_fields.length > 1
          col_defs << "PRIMARY KEY (#{primary_key_fields.join(', ')})"
        end

        sql = "CREATE TABLE IF NOT EXISTS #{table_name} (#{col_defs.join(', ')})"

        # Translate AUTOINCREMENT to the engine's auto-increment syntax
        # (INTEGER PRIMARY KEY AUTOINCREMENT -> SERIAL PRIMARY KEY on PG, etc.).
        # SQLTranslator keys off the -ql spelling for postgres.
        translator_engine = %w[postgres postgresql].include?(engine) ? "postgresql" : engine
        sql = SQLTranslator.auto_increment_syntax(sql, translator_engine)

        # Don't claim success when the DDL failed. db.execute() now RAISES on a
        # SQL error (it no longer swallows it into get_error() and returns
        # false), so a bad type (or any DDL error) surfaces here as an
        # exception. create_table keeps its documented bool contract: catch the
        # raise, log the cause, and return false so callers that test the return
        # still see a clean failure instead of a thrown error.
        begin
          db.execute(sql)
          db.commit
          true
        rescue => e
          Tina4::Log.error("create_table failed for #{table_name}: #{db.get_error || e.message}", { sql: sql })
          false
        end
      end

      def scope(name, filter_sql, params = [])
        define_singleton_method(name) do |limit: 100, offset: 0|
          where(filter_sql, params, limit: limit, offset: offset)
        end
      end

      def from_hash(hash)
        instance = new
        mapping_reverse = field_mapping.invert
        hash.each do |key, value|
          # Apply field mapping (db_col => ruby_attr)
          attr_name = mapping_reverse[key.to_s] || key
          # A JSON column comes back from the driver as a JSON string (SQLite
          # TEXT, MySQL JSON, PostgreSQL JSONB via the text protocol, MSSQL
          # NVARCHAR). Decode it to the Hash/Array the attribute expects
          # (parity with the Python master's JSONField parse-on-read). A value
          # already a Hash/Array is left untouched; nil stays nil; a
          # non-decodable string keeps its raw form rather than crashing a
          # normal read.
          fdef = field_definitions[attr_name.to_sym]
          if fdef && fdef[:type] == :json && value.is_a?(String)
            begin
              value = JSON.parse(value)
            rescue JSON::ParserError
              # leave the raw string in place
            end
          end
          setter = "#{attr_name}="
          instance.__send__(setter, value) if instance.respond_to?(setter)
        end
        instance.instance_variable_set(:@persisted, true)
        instance
      end

      # find_by_id is PUBLIC — cross-framework parity with Python's
      # MyModel.find_by_id(pk_value) and PHP's User::find($id). Spec at
      # spec/orm_spec.rb:78 verifies public access. find_by_filter stays
      # public for the same reason; both are part of the documented API.
      def find_by_id(id)
        pk = primary_key_field || :id
        sql = "SELECT * FROM #{table_name} WHERE #{pk} = ?"
        if soft_delete
          sql += " AND (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0)"
        end
        select_one(sql, [id])
      end

      # Return true if a record with the given primary key exists.
      #
      # Cross-framework parity with Python's MyModel.exists(pk_value),
      # PHP's Model::exists($id), and Node's Model.exists(pk). Honours the
      # soft-delete filter the same way find_by_id does (it routes through it).
      # Used by #save to decide INSERT vs UPDATE for natural (non-auto-increment)
      # primary keys — see the note on #save.
      def exists(id)
        !find_by_id(id).nil?
      end

      # Clear the relationship cache on all loaded instances (class-level helper).
      # Useful after bulk operations when you want to force relationship re-loads.
      def clear_rel_cache # -> nil
        @_rel_cache = {}
        nil
      end

      # Return the database connection used by this model.
      def get_db # -> Database
        db
      end

      # Map a Ruby property name to its database column name using field_mapping.
      # Returns the column name as a symbol.
      def get_db_column(property) # -> Symbol
        col = field_mapping[property.to_s] || property
        col.to_sym
      end

      private

      def auto_discover_db
        url = ENV["TINA4_DATABASE_URL"]
        return nil unless url
        Tina4.bind_database(Tina4::Database.new(url, username: ENV.fetch("TINA4_DATABASE_USERNAME", ""), password: ENV.fetch("TINA4_DATABASE_PASSWORD", "")))
      end

      def find_by_filter(filter)
        where_parts = filter.keys.map { |k| "#{k} = ?" }
        sql = "SELECT * FROM #{table_name} WHERE #{where_parts.join(' AND ')}"
        if soft_delete
          sql += " AND (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0)"
        end
        results = db.fetch(sql, filter.values)
        results.map { |row| from_hash(row) }
      end

      # Render a column DEFAULT literal for create_table.
      #
      # Strings are quoted. Booleans are engine-aware: a native BOOLEAN
      # column (PG/MySQL) needs TRUE/FALSE, while INTEGER- and BIT-backed
      # bools (SQLite, Firebird, MSSQL) need 1/0 — `DEFAULT 0` on a PG
      # BOOLEAN raises "default expression is of type integer". Everything
      # else is emitted as-is.
      def default_literal(value, type, bool_sql)
        if value.is_a?(String)
          "'#{value}'"
        elsif value == true || value == false || type == :boolean
          truthy = value == true || value == 1 || value == "1"
          if bool_sql == "BOOLEAN"
            truthy ? "TRUE" : "FALSE"
          else
            truthy ? "1" : "0"
          end
        else
          value.to_s
        end
      end
    end

    def initialize(attributes = {})
      @persisted = false
      @errors = []
      # Cause of the most recent failed #save (validation message or DB error).
      # nil when the most recent save succeeded. Mirrors db.get_error so a caller
      # that checks `return false unless model.save` can still recover the real
      # cause via #get_error / #last_error — the failure never vanishes silently.
      @last_error = nil
      @relationship_cache = {}
      # #165: field names the caller EXPLICITLY assigned (via the attribute loop
      # below, a from_hash/load populate, or a later `model.field = x`). save()
      # reads this to OMIT an unset column from an INSERT (so a NOT NULL DEFAULT
      # column gets its DB default) while still writing NULL for a field the
      # caller set to nil. The defaults seeded below use instance_variable_set,
      # bypassing the tracking setter so they are NOT counted as assignments.
      @assigned_fields = []
      # Accept a JSON object string (parity with Python/PHP/Node):
      #   Widget.new('{"id":1,"name":"alpha"}')
      attributes = JSON.parse(attributes) if attributes.is_a?(String)
      # A single model is one record — reject an Array with a clear message.
      if attributes.is_a?(Array)
        raise ArgumentError,
              "#{self.class}.new expects a Hash, keyword args, or a JSON object string " \
              "for one record — got an Array. Map over the list to build many records."
      end
      attributes.each do |key, value|
        setter = "#{key}="
        __send__(setter, value) if respond_to?(setter)
      end
      # Set defaults.
      # v3.13.11 (issue #50.1): when the default is a Proc/lambda
      # (``default: -> { Time.now }``), call it per-instance so
      # per-row timestamps actually differ. Class objects are
      # excluded — ``default: Integer`` is almost never intended
      # to mean ``Integer.new`` (and Integer has no zero-arg
      # constructor anyway).
      self.class.field_definitions.each do |name, opts|
        if __send__(name).nil? && opts[:default]
          d = opts[:default]
          d = d.call if d.respond_to?(:call) && !d.is_a?(Class)
          # Deep-copy a mutable Hash/Array default so two instances never alias
          # the same object (e.g. `json_field :meta, default: {}` — mutating
          # a.meta must not leak into b.meta). Parity with the Python master,
          # which deepcopies a JSONField's dict/list default per instance.
          d = Marshal.load(Marshal.dump(d)) if d.is_a?(Hash) || d.is_a?(Array)
          # #165: seed the default straight into the ivar, BYPASSING the
          # tracking setter, so a default is not recorded as a caller
          # assignment (mirrors the Python master's object.__setattr__).
          instance_variable_set("@#{name}", d)
        end
      end
    end

    # Insert or update. Returns self on success (fluent), false on failure.
    #
    # Fails loud, never silent (the same principle db.execute already follows
    # by raising). On *any* failure path save returns false — keeping the
    # contract callers rely on (`return false unless model.save`) — but it also
    # (a) logs the real cause via Tina4::Log.error with model/table context and
    # (b) records the cause on a retrievable per-model error (#last_error /
    # #get_error, mirroring db.get_error) plus #errors, so a caller can recover
    # it after the fact. It never raises and never changes the self/false
    # return shape. On success it returns self (was `true` pre-v3.13.39 — Ruby
    # was the sole framework returning a bare boolean here) and clears the
    # error.
    #
    # Two distinct failure paths, both loud:
    #
    #   * Validation (v3.13.39): #validate runs FIRST. If it returns errors,
    #     save records them on @errors + @last_error, logs them, and returns
    #     false WITHOUT touching the database — an invalid model never reaches
    #     the driver. (Ruby already enforced validate-on-save; this adds the
    #     loud log + recoverable last_error to the failure path.)
    #   * Database (v3.13.39): a driver error (NOT NULL, duplicate PK, missing
    #     table, …) is rolled back by db.transaction, then captured (db.get_error
    #     falling back to the exception text) onto @last_error, logged with
    #     model/table context, and returns false — the cause is no longer
    #     swallowed silently.
    #
    # INSERT vs UPDATE (bug B, parity with the Python master): for a NATURAL
    # (non-auto-increment) primary key that is set, the decision is made on
    # whether the ROW EXISTS (via self.class.exists), not on @persisted alone.
    # Pre-v3.13.39 a re-save of a manually-PK'd record that had @persisted set
    # would UPDATE — but a freshly built (not-yet-persisted) natural-key record
    # whose row already existed could double-INSERT, or a `new`-then-`save` of a
    # natural key would INSERT then a second save UPDATE a phantom. Probing
    # existence makes the choice correct regardless of @persisted. Auto-increment
    # PKs keep the legacy @persisted-based decision (a nil PK means "new row,
    # let the engine assign an id").
    # A filter hash naming EVERY primary-key column.
    #
    # Addressing a row by one column of a composite key matches every row
    # sharing that value. Feature 4 removed that from the raw write path; this
    # is the same rule for the ORM above it.
    def pk_filter
      self.class.primary_key_fields.each_with_object({}) do |name, acc|
        acc[name] = __send__(name) if respond_to?(name)
      end
    end

    def save
      @errors = []
      @relationship_cache = {} # Clear relationship cache on save

      # ── validate() is ENFORCED. An invalid model never reaches the driver —
      # fail loud (record + log), return false. ──
      validation_errors = validate
      unless validation_errors.empty?
        @errors = validation_errors
        @last_error = validation_errors.join("; ")
        Tina4::Log.error(
          "#{self.class.name}.save refused: validation failed — #{@last_error}"
        )
        return false
      end

      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      pk_opts = self.class.field_definitions[pk] || {}
      auto_increment = pk_opts[:auto_increment]

      # Decide INSERT vs UPDATE.
      is_update =
        if pk_value.nil?
          false
        elsif auto_increment
          # Auto-increment: legacy behaviour — a set PK on a persisted instance
          # means UPDATE.
          @persisted ? true : false
        else
          # Natural key: probe row existence so a re-save never double-inserts
          # and a first save of a never-seen key still inserts. If the probe
          # itself fails (e.g. table missing), fall back to INSERT so the caller
          # sees the real driver error rather than a silent no-op UPDATE.
          begin
            # This asked exists(pk_value), which tests only ONE key column. On a
            # composite key that is true for any row sharing it, so inserting a
            # genuinely NEW row was decided to be an UPDATE and silently
            # OVERWROTE a different row: saving (acme, a2) rewrote (acme, a1).
            # The probe has to name the whole key, like the write that follows.
            if self.class.primary_key_fields.length > 1
              self.class.where(
                pk_filter.keys.map { |k| "#{k} = ?" }.join(" AND "),
                pk_filter.values,
                limit: 1
              ).any?
            else
              self.class.exists(pk_value)
            end
          rescue StandardError
            false
          end
        end

      begin
        # The column hashes are built INSIDE this begin (via the transaction
        # block below) so a JSON column that can't be serialised (to_db_hash /
        # insert_db_hash raises JSON::GeneratorError) fails loud through the
        # same path as a driver error — rolled back, false, cause recorded.
        self.class.db.transaction do |db|
          if is_update
            # UPDATE is unchanged (#165 targets INSERT only): keep excluding nil
            # so a save never nulls a column the caller didn't touch.
            data = to_db_hash(exclude_nil: true)
            filter = pk_filter
            # Never SET a key column - it is what addresses the row.
            self.class.primary_key_fields.each do |k|
              data.delete(k)
              mapped = self.class.field_mapping[k.to_s]
              data.delete(mapped.to_sym) if mapped
            end
            db.update(self.class.table_name, data, filter)
          else
            # #165: OMIT a column the caller left unset (value nil, never
            # assigned) so a NOT NULL DEFAULT column gets its DB default rather
            # than an explicit NULL; a column the caller set to nil is KEPT and
            # written as NULL (see #insert_db_hash).
            insert_data = insert_db_hash
            if insert_data.empty?
              # Every insertable column is unset — let the engine apply ALL its
              # column defaults instead of emitting explicit NULLs. DEFAULT
              # VALUES is valid on SQLite / PostgreSQL / MSSQL / Firebird; MySQL
              # spells the all-defaults insert () VALUES ().
              table = self.class.table_name
              engine = (self.class.db.respond_to?(:get_database_type) ? self.class.db.get_database_type : "").to_s.downcase
              db.execute(engine == "mysql" ? "INSERT INTO #{table} () VALUES ()" : "INSERT INTO #{table} DEFAULT VALUES")
              if auto_increment && respond_to?("#{pk}=")
                last = db.get_last_id
                __send__("#{pk}=", last) if last
              end
            else
              result = db.insert(self.class.table_name, insert_data)
              # Only adopt the engine-assigned id for an auto-increment PK. A
              # natural-key PK was set by the caller; don't overwrite it with the
              # driver's last_insert_id (which may be a sequence value that
              # doesn't apply here). db.insert returns a DatabaseResult (.last_id).
              if auto_increment && result.last_id && respond_to?("#{pk}=")
                __send__("#{pk}=", result.last_id)
              end
            end
          end
        end
      rescue => e
        # ── Fail loud, never silent. db.transaction already rolled back and
        # re-raised. Keep the false return contract, but capture the REAL cause
        # (prefer db.get_error, which insert/update/execute populate, falling
        # back to the exception text) on @last_error + @errors so it survives,
        # and log it with model/table context. ──
        cause = (self.class.db.get_error rescue nil) || e.message
        # ── DX hint (parity with the Python master's save(), v3.13.60): turn a
        # bare driver error into an actionable fix for the two commonest ORM
        # write footguns. Match case-insensitively (SQLite: "no such table" /
        # "no such column: is_deleted" / "has no column named is_deleted";
        # Postgres/MySQL: "does not exist" / "doesn't exist" / "unknown
        # column"). Any OTHER error keeps its raw cause untouched so an
        # unrelated failure (NOT NULL, duplicate PK) is never masked. ──
        low = cause.to_s.downcase
        sd_field = self.class.soft_delete_field.to_s
        if self.class.soft_delete && low.include?(sd_field) && (
             low.include?("no such column") || low.include?("has no column") ||
             low.include?("does not exist") || low.include?("doesn't exist") ||
             low.include?("unknown column")
           )
          cause += " — soft_delete is on but the '#{sd_field}' column is missing; " \
                   "declare it (integer_field :#{sd_field}, default: 0) or add a migration"
        elsif low.include?("no such table") || (
                (low.include?("does not exist") || low.include?("doesn't exist")) &&
                !low.include?("column")
              )
          cause += " — table '#{self.class.table_name}' does not exist; " \
                   "call #{self.class.name}.create_table or run a migration"
        end
        @last_error = cause
        @errors = [cause]
        Tina4::Log.error(
          "#{self.class.name}.save failed for table " \
          "'#{self.class.table_name}': #{cause}"
        )
        return false
      end

      @persisted = true
      @last_error = nil
      self
    end

    # Delete this record (soft or hard).
    #
    # v3.13.39 (bug D): RAISES on a missing primary key, matching #force_delete
    # (which already raised). Previously delete returned false on a nil PK while
    # force_delete raised — an inconsistent contract where "couldn't delete" and
    # "deleted nothing" were indistinguishable on one path but loud on the other.
    # Both now fail loud: deleting a record with no PK is a programmer error, not
    # a quiet no-op. Returns true on a successful delete.
    def delete
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot delete: no primary key value" unless pk_value

      self.class.db.transaction do |db|
        if self.class.soft_delete
          db.update(
            self.class.table_name,
            { self.class.soft_delete_field => 1 },
            pk_filter
          )
        else
          db.delete(self.class.table_name, pk_filter)
        end
      end
      @persisted = false
      true
    end

    def force_delete
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot delete: no primary key value" unless pk_value

      self.class.db.transaction do |db|
        db.delete(self.class.table_name, pk_filter)
      end
      @persisted = false
      true
    end

    def restore
      raise "Model does not support soft delete" unless self.class.soft_delete

      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot restore: no primary key value" unless pk_value

      self.class.db.transaction do |db|
        db.update(
          self.class.table_name,
          { self.class.soft_delete_field => 0 },
          pk_filter
        )
      end
      __send__("#{self.class.soft_delete_field}=", 0) if respond_to?("#{self.class.soft_delete_field}=")
      true
    end

    def validate
      errors = []
      self.class.field_definitions.each do |name, opts|
        value = __send__(name)
        if !opts[:nullable] && value.nil? && !opts[:auto_increment] && !opts[:default]
          errors << "#{name} cannot be null"
        end
      end
      errors
    end

    # load — populate this instance from the database.
    #
    # Three forms (parity with Python's model.load(sql, params, include)):
    #   user.load                                   # reload by primary key from instance
    #   user.load(123)                              # load by primary key value
    #   user.load("email = ?", ["a@b.c"])           # load by filter SQL + params (selectOne)
    #
    # Returns true on hit, false on miss. Always clears the relationship cache.
    def load(arg = nil, params = nil)
      @relationship_cache = {} # Clear relationship cache on reload
      pk = self.class.primary_key_field || :id

      if arg.is_a?(String)
        # Filter-SQL form: user.load("email = ?", ["a@b.c"])
        sql = "SELECT * FROM #{self.class.table_name} WHERE #{arg} LIMIT 1"
        result = self.class.db.fetch_one(sql, params || [])
      else
        # Primary-key form: user.load OR user.load(123)
        id = arg || __send__(pk)
        return false unless id
        result = self.class.db.fetch_one(
          "SELECT * FROM #{self.class.table_name} WHERE #{pk} = ?", [id]
        )
      end
      return false unless result

      mapping_reverse = self.class.field_mapping.invert
      result.each do |key, value|
        attr_name = mapping_reverse[key.to_s] || key
        setter = "#{attr_name}="
        __send__(setter, value) if respond_to?(setter)
      end
      @persisted = true
      true
    end

    def persisted?
      @persisted
    end

    def errors
      @errors
    end

    # Cause of the most recent failed #save (validation message or DB error),
    # or nil when the last save succeeded.
    def last_error
      @last_error
    end

    # Return the cause of the most recent failed #save, or nil.
    #
    # Mirrors db.get_error. After save returns false — whether from validation
    # or a driver error — the real cause is retrievable here (and on
    # #last_error) so a caller using the `return false unless model.save`
    # contract can still surface it. Cleared to nil on a successful save.
    # Cross-framework parity with Python/PHP/Node get_error().
    def get_error
      @last_error
    end

    # Convert to hash using Ruby attribute names.
    # Optionally include relationships via the include keyword.
    # case: "camel" converts snake_case keys to camelCase (parity with
    # Python's to_dict(case='camel')). Default keeps native snake_case.
    def to_h(include: nil, case: nil)
      key_case = binding.local_variable_get(:case)  # :case is a reserved word
      hash = {}
      self.class.field_definitions.each_key do |name|
        hash[name] = __send__(name)
      end

      if include
        # Group includes: top-level and nested
        top_level = {}
        include.each do |inc|
          parts = inc.to_s.split(".", 2)
          rel_name = parts[0].to_sym
          top_level[rel_name] ||= []
          top_level[rel_name] << parts[1] if parts.length > 1
        end

        top_level.each do |rel_name, nested|
          next unless self.class.relationship_definitions.key?(rel_name)
          related = __send__(rel_name)
          if related.nil?
            hash[rel_name] = nil
          elsif related.is_a?(Array)
            hash[rel_name] = related.map { |r| r.to_h(include: nested.empty? ? nil : nested) }
          else
            hash[rel_name] = related.to_h(include: nested.empty? ? nil : nested)
          end
        end
      end

      if key_case == "camel" || key_case == :camel
        # snake_case → camelCase: split on _, capitalize all but the first
        hash = hash.each_with_object({}) do |(k, v), out|
          parts = k.to_s.split("_")
          camel = parts[0] + parts[1..].map(&:capitalize).join
          out[camel.to_sym] = v
        end
      end

      hash
    end

    alias to_hash to_h
    alias to_dict to_h
    alias to_object to_h

    def to_array
      to_h.values
    end

    alias to_list to_array

    def to_json(include: nil, **_args)
      JSON.generate(to_h(include: include))
    end

    def to_s
      "#<#{self.class.name} #{to_h}>"
    end

    def select(*fields)
      fields_str = fields.map(&:to_s).join(", ")
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      self.class.db.fetch_one("SELECT #{fields_str} FROM #{self.class.table_name} WHERE #{pk} = ?", [pk_value])
    end

    private

    # Build the column=>value hash for an INSERT (#165).
    #
    # Distinguishes a column the caller left UNSET from one the caller
    # explicitly set to nil (tracked in @assigned_fields, populated by the field
    # setters):
    #
    #   * value nil AND field NOT assigned  -> OMITTED (a DB DEFAULT applies, so
    #       a NOT NULL DEFAULT column succeeds instead of taking an explicit NULL)
    #   * value nil AND field assigned       -> KEPT as nil (written as SQL NULL;
    #       a NOT NULL column rightly rejects it, so an explicit nil fails loud)
    #   * any non-nil value (incl. a resolved ORM default) -> KEPT
    #
    # An unset auto-increment PK is skipped so the engine assigns the id. JSON
    # columns serialise their Hash/Array exactly as #to_db_hash does. An empty
    # result signals save() to emit the engine's all-defaults INSERT. Mirrors
    # the Python master's INSERT omission (tina4_python.orm.model.save).
    def insert_db_hash
      hash = {}
      mapping = self.class.field_mapping
      assigned = @assigned_fields || []
      self.class.field_definitions.each do |name, opts|
        value = __send__(name)
        # Skip an unset auto-increment PK — let the engine assign it.
        next if opts[:auto_increment] && value.nil?
        # Omit an unset-nil column so the DB DEFAULT applies.
        next if value.nil? && !assigned.include?(name)
        if opts[:type] == :json && !value.nil? && !value.is_a?(String)
          value = JSON.generate(value)
        end
        db_col = mapping[name.to_s] || name
        hash[db_col.to_sym] = value
      end
      hash
    end

    # Convert to hash using DB column names (with field_mapping applied)
    def to_db_hash(exclude_nil: false)
      hash = {}
      mapping = self.class.field_mapping
      self.class.field_definitions.each do |name, opts|
        value = __send__(name)
        next if exclude_nil && value.nil?
        # A JSON column serialises its Hash/Array to a JSON string for the
        # driver (parity with the Python master's JSONField.to_db). A value
        # that can't be encoded (e.g. Float::NAN) raises JSON::GeneratorError;
        # save() computes this hash inside its rescue, so it fails loud —
        # rolls back, returns false, records the cause. A value already a
        # String is left as-is (a caller who pre-encoded stays in control);
        # nil passes through untouched.
        if opts[:type] == :json && !value.nil? && !value.is_a?(String)
          value = JSON.generate(value)
        end
        db_col = mapping[name.to_s] || name
        hash[db_col.to_sym] = value
      end
      hash
    end

    def validate_fields
      self.class.field_definitions.each do |name, opts|
        value = __send__(name)
        if !opts[:nullable] && value.nil? && !opts[:auto_increment] && !opts[:default]
          @errors << "#{name} cannot be null"
        end
      end
    end

    def load_has_one(name)
      return @relationship_cache[name] if @relationship_cache.key?(name)
      rel = self.class.relationship_definitions[name]
      return nil unless rel

      klass = Object.const_get(rel[:class_name])
      pk = self.class.primary_key_field || :id
      fk = rel[:foreign_key] || "#{self.class.name.split('::').last.downcase}_id"
      pk_value = __send__(pk)
      return nil unless pk_value

      result = klass.db.fetch_one(
        "SELECT * FROM #{klass.table_name} WHERE #{fk} = ?", [pk_value]
      )
      @relationship_cache[name] = result ? klass.from_hash(result) : nil
    end

    def load_has_many(name)
      return @relationship_cache[name] if @relationship_cache.key?(name)
      rel = self.class.relationship_definitions[name]
      return [] unless rel

      klass = Object.const_get(rel[:class_name])
      pk = self.class.primary_key_field || :id
      fk = rel[:foreign_key] || "#{self.class.name.split('::').last.downcase}_id"
      pk_value = __send__(pk)
      return [] unless pk_value

      results = klass.db.fetch(
        "SELECT * FROM #{klass.table_name} WHERE #{fk} = ?", [pk_value]
      )
      @relationship_cache[name] = results.map { |row| klass.from_hash(row) }
    end

    def load_belongs_to(name)
      return @relationship_cache[name] if @relationship_cache.key?(name)
      rel = self.class.relationship_definitions[name]
      return nil unless rel

      klass = Object.const_get(rel[:class_name])
      fk = rel[:foreign_key] || "#{name}_id"
      fk_value = __send__(fk.to_sym) if respond_to?(fk.to_sym)
      return nil unless fk_value

      @relationship_cache[name] = klass.find(fk_value)
    end
  end
end
