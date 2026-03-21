# frozen_string_literal: true
require "json"

module Tina4
  class ORM
    include Tina4::FieldTypes

    class << self
      def db
        @db || Tina4.database
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
          class_name: class_name || name.to_s.sub(/s$/, "").split("_").map(&:capitalize).join,
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

      def find(id_or_filter = nil, filter = nil)
        # find(id) — find by primary key
        # find(filter_hash) — find by criteria
        if id_or_filter.is_a?(Hash)
          find_by_filter(id_or_filter)
        elsif filter.is_a?(Hash)
          find_by_filter(filter)
        else
          find_by_id(id_or_filter)
        end
      end

      def where(conditions, params = [])
        sql = "SELECT * FROM #{table_name}"
        if soft_delete
          sql += " WHERE (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0) AND (#{conditions})"
        else
          sql += " WHERE #{conditions}"
        end
        results = db.fetch(sql, params)
        results.map { |row| from_hash(row) }
      end

      def all(limit: nil, offset: nil, skip: nil, order_by: nil)
        sql = "SELECT * FROM #{table_name}"
        if soft_delete
          sql += " WHERE #{soft_delete_field} IS NULL OR #{soft_delete_field} = 0"
        end
        sql += " ORDER BY #{order_by}" if order_by
        effective_offset = offset || skip
        results = db.fetch(sql, [], limit: limit, skip: effective_offset)
        results.map { |row| from_hash(row) }
      end

      def select(sql, params = [], limit: nil, skip: nil)
        results = db.fetch(sql, params, limit: limit, skip: skip)
        results.map { |row| from_hash(row) }
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

      def create(attributes = {})
        instance = new(attributes)
        instance.save
        instance
      end

      def find_or_fail(id)
        result = find(id)
        raise "#{name} with #{primary_key_field || :id}=#{id} not found" if result.nil?
        result
      end

      def with_trashed(conditions = "1=1", params = [], limit: 20, skip: 0)
        sql = "SELECT * FROM #{table_name} WHERE #{conditions}"
        results = db.fetch(sql, params, limit: limit, skip: skip)
        results.map { |row| from_hash(row) }
      end

      def create_table
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
        true
      end

      def scope(name, filter_sql, params = [])
        define_singleton_method(name) do |limit: 20, skip: 0|
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

      private

      def find_by_id(id)
        pk = primary_key_field || :id
        sql = "SELECT * FROM #{table_name} WHERE #{pk} = ?"
        if soft_delete
          sql += " AND (#{soft_delete_field} IS NULL OR #{soft_delete_field} = 0)"
        end
        result = db.fetch_one(sql, [id])
        return nil unless result
        from_hash(result)
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

    def save
      @errors = []
      validate_fields
      return false unless @errors.empty?

      data = to_db_hash(exclude_nil: true)
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)

      if @persisted && pk_value
        filter = { pk => pk_value }
        data.delete(pk)
        # Remove mapped primary key too
        mapped_pk = self.class.field_mapping[pk.to_s]
        data.delete(mapped_pk.to_sym) if mapped_pk
        self.class.db.update(self.class.table_name, data, filter)
      else
        result = self.class.db.insert(self.class.table_name, data)
        if result[:last_id] && respond_to?("#{pk}=")
          __send__("#{pk}=", result[:last_id])
        end
        @persisted = true
      end
      true
    rescue => e
      @errors << e.message
      false
    end

    def delete
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      return false unless pk_value

      if self.class.soft_delete
        # Soft delete: set the flag
        self.class.db.update(
          self.class.table_name,
          { self.class.soft_delete_field => 1 },
          { pk => pk_value }
        )
      else
        self.class.db.delete(self.class.table_name, { pk => pk_value })
      end
      @persisted = false
      true
    end

    def force_delete
      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot delete: no primary key value" unless pk_value

      self.class.db.delete(self.class.table_name, { pk => pk_value })
      @persisted = false
      true
    end

    def restore
      raise "Model does not support soft delete" unless self.class.soft_delete

      pk = self.class.primary_key_field || :id
      pk_value = __send__(pk)
      raise "Cannot restore: no primary key value" unless pk_value

      self.class.db.update(
        self.class.table_name,
        { self.class.soft_delete_field => 0 },
        { pk => pk_value }
      )
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

    def load(id = nil)
      pk = self.class.primary_key_field || :id
      id ||= __send__(pk)
      return false unless id

      result = self.class.db.fetch_one(
        "SELECT * FROM #{self.class.table_name} WHERE #{pk} = ?", [id]
      )
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

    # Convert to hash using Ruby attribute names
    def to_h
      hash = {}
      self.class.field_definitions.each_key do |name|
        hash[name] = __send__(name)
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

    def to_json(*_args)
      JSON.generate(to_h)
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

      @relationship_cache[name] = klass.find(fk_value)
    end
  end
end
