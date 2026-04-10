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

  class ORM
    include Tina4::FieldTypes

    class << self
      def db
        @db || Tina4.database || auto_discover_db
      end

      # Per-model database binding
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

      # Auto-map flag (no-op in Ruby since snake_case is native)
      def auto_map
        @auto_map || false
      end

      def auto_map=(val)
        @auto_map = val
      end

      # Auto-CRUD flag: when set to true, registers this model for CRUD route generation
      def auto_crud
        @auto_crud || false
      end

      def auto_crud=(val)
        @auto_crud = val
        if val
          Tina4::AutoCrud.register(self) if defined?(Tina4::AutoCrud)
        end
      end

      # Relationship definitions
      def relationship_definitions
        @relationship_definitions ||= {}
      end

      # has_one :profile, class_name: "Profile", foreign_key: "user_id"
      def has_one(name, class_name: nil, foreign_key: nil) # -> nil
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
      def has_many(name, class_name: nil, foreign_key: nil) # -> nil
        relationship_definitions[name] = {
          type: :has_many,
          class_name: class_name || name.to_s.sub(/s$/, "").split("_").map(&:capitalize).join,
          foreign_key: foreign_key
        }

        define_method(name) do
          load_has_many(name)
        end
      end

      # belongs_to :user, class_name: "User", foreign_key: "user_id"
      def belongs_to(name, class_name: nil, foreign_key: nil) # -> nil
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
      def query # -> QueryBuilder
        QueryBuilder.from_table(table_name, db: db)
      end

      # Find records by filter dict. Always returns an array.
      #
      # Usage:
      #   User.find(name: "Alice")                  → [User, ...]
      #   User.find({age: 18}, limit: 10)           → [User, ...]
      #   User.find(order_by: "name ASC")            → [User, ...]
      #   User.find                                  → all records
      #
      # Use find_by_id(id) for single-record primary key lookup.
      def find(filter = {}, limit: 100, offset: 0, order_by: nil, include: nil, **extra_filter) # -> list[Self]
        # Integer or string-digit argument → primary key lookup (returns single record or nil)
        return find_by_id(filter) if filter.is_a?(Integer)

        # Merge keyword-style filters: find(name: "Alice") and find({name: "Alice"}) both work
        filter = filter.merge(extra_filter) unless extra_filter.empty?
        conditions = []
        params = []

        filter.each do |key, value|
          col = field_mapping[key.to_s] || key
          conditions << "#{col} = ?"
          params << value
        end

        if soft_delete
          conditions << "(#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0)"
        end

        sql = "SELECT * FROM #{table_name}"
        sql += " WHERE #{conditions.join(' AND ')}" unless conditions.empty?
        sql += " ORDER BY #{order_by}" if order_by

        results = db.fetch(sql, params, limit: limit, offset: offset)
        instances = results.map { |row| from_hash(row) }
        eager_load(instances, include) if include
        instances
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

      def where(conditions, params = [], limit: 20, offset: 0, include: nil) # -> list[Self]
        sql = "SELECT * FROM #{table_name}"
        if soft_delete
          sql += " WHERE (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0) AND (#{conditions})"
        else
          sql += " WHERE #{conditions}"
        end
        results = db.fetch(sql, params, limit: limit, offset: offset)
        instances = results.map { |row| from_hash(row) }
        eager_load(instances, include) if include
        instances
      end

      def all(limit: nil, offset: nil, order_by: nil, include: nil) # -> list[Self]
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

      def select(sql, params = [], limit: nil, offset: nil, include: nil) # -> list[Self]
        results = db.fetch(sql, params, limit: limit, offset: offset)
        instances = results.map { |row| from_hash(row) }
        eager_load(instances, include) if include
        instances
      end

      def select_one(sql, params = [], include: nil) # -> Self | nil
        results = select(sql, params, limit: 1, include: include)
        results.first
      end

      def count(conditions = nil, params = []) # -> int
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

      def create(attributes = {}) # -> Self
        instance = new(attributes)
        instance.save
        instance
      end

      def find_or_fail(id) # -> Self
        result = find(id)
        raise "#{name} with #{primary_key_field || :id}=#{id} not found" if result.nil?
        result
      end

      # Return true if a record with the given primary key exists.
      def exists(pk_value) # -> bool
        find(pk_value) != nil
      end

      # SQL query with in-memory result caching.
      # Results are cached by (class, sql, params, limit, offset) for +ttl+ seconds.
      def cached(sql, params = [], ttl: 60, limit: 20, offset: 0, include: nil) # -> list[Self]
        @_query_cache ||= Tina4::QueryCache.new(default_ttl: ttl, max_size: 500)
        cache_key = Tina4::QueryCache.query_key("#{name}:#{sql}", params + [limit, offset])
        hit = @_query_cache.get(cache_key)
        return hit unless hit.nil?

        results = select(sql, params, limit: limit, offset: offset, include: include)
        @_query_cache.set(cache_key, results, ttl: ttl, tags: [name])
        results
      end

      # Clear all cached query results for this model.
      def clear_cache # -> nil
        @_query_cache&.clear_tag(name)
      end

      def with_trashed(conditions = "1=1", params = [], limit: 20, offset: 0) # -> list[Self]
        sql = "SELECT * FROM #{table_name} WHERE #{conditions}"
        results = db.fetch(sql, params, limit: limit, offset: offset)
        results.map { |row| from_hash(row) }
      end

      def create_table # -> bool
        return true if db.table_exists?(table_name)

        type_map = {
          integer: "INTEGER",
          string: "VARCHAR(255)",
          text: "TEXT",
          float: "REAL",
          decimal: "REAL",
          boolean: "INTEGER",
          date: "DATE",
          datetime: "DATETIME",
          timestamp: "TIMESTAMP",
          blob: "BLOB",
          json: "TEXT"
        }

        col_defs = []
        field_definitions.each do |name, opts|
          sql_type = type_map[opts[:type]] || "TEXT"
          if opts[:type] == :string && opts[:length]
            sql_type = "VARCHAR(#{opts[:length]})"
          end

          parts = ["#{name} #{sql_type}"]
          parts << "PRIMARY KEY" if opts[:primary_key]
          parts << "AUTOINCREMENT" if opts[:auto_increment]
          parts << "NOT NULL" if !opts[:nullable] && !opts[:primary_key]
          if opts[:default] && !opts[:auto_increment]
            default_val = opts[:default].is_a?(String) ? "'#{opts[:default]}'" : opts[:default]
            parts << "DEFAULT #{default_val}"
          end
          col_defs << parts.join(" ")
        end

        sql = "CREATE TABLE IF NOT EXISTS #{table_name} (#{col_defs.join(', ')})"
        db.execute(sql)
        db.commit
        true
      end

      def scope(name, filter_sql, params = []) # -> nil
        define_singleton_method(name) do |limit: 20, offset: 0|
          where(filter_sql, params)
        end
      end

      def from_hash(hash)
        instance = new
        mapping_reverse = field_mapping.invert
        hash.each do |key, value|
          # Apply field mapping (db_col => ruby_attr)
          attr_name = mapping_reverse[key.to_s] || key
          setter = "#{attr_name}="
          instance.__send__(setter, value) if instance.respond_to?(setter)
        end
        instance.instance_variable_set(:@persisted, true)
        instance
      end

      # Find a single record by primary key. Returns instance or nil.
      def find_by_id(id, include: nil) # -> Self | nil
        pk = primary_key_field || :id
        sql = "SELECT * FROM #{table_name} WHERE #{pk} = ?"
        if soft_delete
          sql += " AND (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0)"
        end
        select_one(sql, [id], include: include)
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
        url = ENV["DATABASE_URL"]
        return nil unless url
        Tina4.database = Tina4::Database.new(url, username: ENV.fetch("DATABASE_USERNAME", ""), password: ENV.fetch("DATABASE_PASSWORD", ""))
        Tina4.database
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
    end

    def initialize(attributes = {})
      @persisted = false
      @errors = []
      @relationship_cache = {}
      attributes.each do |key, value|
        setter = "#{key}="
        __send__(setter, value) if respond_to?(setter)
      end
      # Set defaults
      self.class.field_definitions.each do |name, opts|
        if __send__(name).nil? && opts[:default]
          __send__("#{name}=", opts[:default])
        end
      end
    end

    def save # -> Self | bool
      @errors = []
      @relationship_cache = {} # Clear relationship cache on save
      validate_fields
      return false unless @errors.empty?

      data = to_db_hash(exclude_nil: true)
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)

      self.class.db.transaction do |db|
        if @persisted && pk_value
          filter = { pk => pk_value }
          data.delete(pk)
          # Remove mapped primary key too
          mapped_pk = self.class.field_mapping[pk.to_s]
          data.delete(mapped_pk.to_sym) if mapped_pk
          db.update(self.class.table_name, data, filter)
        else
          result = db.insert(self.class.table_name, data)
          if result[:last_id] && respond_to?("#{pk}=")
            __send__("#{pk}=", result[:last_id])
          end
          @persisted = true
        end
      end
      true
    rescue => e
      @errors << e.message
      false
    end

    def delete # -> bool
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      return false unless pk_value

      self.class.db.transaction do |db|
        if self.class.soft_delete
          db.update(
            self.class.table_name,
            { self.class.soft_delete_field => 1 },
            { pk => pk_value }
          )
        else
          db.delete(self.class.table_name, { pk => pk_value })
        end
      end
      @persisted = false
      true
    end

    def force_delete # -> bool
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot delete: no primary key value" unless pk_value

      self.class.db.transaction do |db|
        db.delete(self.class.table_name, { pk => pk_value })
      end
      @persisted = false
      true
    end

    def restore # -> bool
      raise "Model does not support soft delete" unless self.class.soft_delete

      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot restore: no primary key value" unless pk_value

      self.class.db.transaction do |db|
        db.update(
          self.class.table_name,
          { self.class.soft_delete_field => 0 },
          { pk => pk_value }
        )
      end
      __send__("#{self.class.soft_delete_field}=", 0) if respond_to?("#{self.class.soft_delete_field}=")
      true
    end

    def validate # -> list[str]
      errors = []
      self.class.field_definitions.each do |name, opts|
        value = __send__(name)
        if !opts[:nullable] && value.nil? && !opts[:auto_increment] && !opts[:default]
          errors << "#{name} cannot be null"
        end
      end
      errors
    end

    # Load a record into this instance via select_one.
    # Returns true if found and loaded, false otherwise.
    # Load a record into this instance.
    #
    # Usage:
    #   orm.id = 1; orm.load          — uses PK already set
    #   orm.load("id = ?", [1])       — filter with params
    #   orm.load("id = 1")            — filter string
    #
    # Returns true if a record was found, false otherwise.
    def load(filter = nil, params = [], include: nil) # -> bool
      @relationship_cache = {}
      table = self.class.table_name

      if filter.nil?
        pk = self.class.primary_key
        pk_col = self.class.field_mapping[pk.to_s] || pk
        pk_value = __send__(pk)
        return false if pk_value.nil?
        sql = "SELECT * FROM #{table} WHERE #{pk_col} = ?"
        params = [pk_value]
      else
        sql = "SELECT * FROM #{table} WHERE #{filter}"
      end

      result = self.class.select_one(sql, params, include: include)
      return false unless result

      mapping_reverse = self.class.field_mapping.invert
      result.to_h.each do |key, value|
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

    # Convert to hash using Ruby attribute names.
    # Optionally include relationships via the include keyword.
    def to_h(include: nil) # -> dict
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

      hash
    end

    alias to_hash to_h
    alias to_dict to_h
    alias to_assoc to_h
    alias to_object to_h

    def to_array # -> list
      to_h.values
    end

    alias to_list to_array

    def to_json(include: nil, **_args) # -> str
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

    # Convert to hash using DB column names (with field_mapping applied)
    def to_db_hash(exclude_nil: false)
      hash = {}
      mapping = self.class.field_mapping
      self.class.field_definitions.each_key do |name|
        value = __send__(name)
        next if exclude_nil && value.nil?
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

      @relationship_cache[name] = klass.find_by_id(fk_value)
    end

    public

    # ── Imperative relationship methods (ad-hoc, like Python/PHP/Node) ──

    def query_has_one(related_class, foreign_key: nil)
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      return nil unless pk_value

      fk = foreign_key || "#{self.class.name.split('::').last.downcase}_id"
      result = related_class.db.fetch_one(
        "SELECT * FROM #{related_class.table_name} WHERE #{fk} = ?", [pk_value]
      )
      result ? related_class.from_hash(result) : nil
    end

    def query_has_many(related_class, foreign_key: nil, limit: 100, offset: 0)
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      return [] unless pk_value

      fk = foreign_key || "#{self.class.name.split('::').last.downcase}_id"
      results = related_class.db.fetch(
        "SELECT * FROM #{related_class.table_name} WHERE #{fk} = ?",
        [pk_value], limit: limit, offset: offset
      )
      results.map { |row| related_class.from_hash(row) }
    end

    def query_belongs_to(related_class, foreign_key: nil)
      fk = foreign_key || "#{related_class.name.split('::').last.downcase}_id"
      fk_value = respond_to?(fk.to_sym) ? __send__(fk.to_sym) : nil
      return nil unless fk_value

      related_class.find_by_id(fk_value)
    end

    # Instance-level aliases matching Python/PHP/Node.js naming
    # These are imperative relationship queries (not class-level declarations)
    alias imperative_has_one query_has_one
    alias imperative_has_many query_has_many
    alias imperative_belongs_to query_belongs_to
  end
end
