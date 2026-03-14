# frozen_string_literal: true
require "json"

module Tina4
  class ORM
    include Tina4::FieldTypes

    class << self
      def db
        Tina4.database
      end

      def find(id)
        pk = primary_key_field || :id
        result = db.fetch_one("SELECT * FROM #{table_name} WHERE #{pk} = ?", [id])
        return nil unless result
        from_hash(result)
      end

      def where(conditions, params = [])
        sql = "SELECT * FROM #{table_name} WHERE #{conditions}"
        results = db.fetch(sql, params)
        results.map { |row| from_hash(row) }
      end

      def all(limit: nil, skip: nil, order_by: nil)
        sql = "SELECT * FROM #{table_name}"
        sql += " ORDER BY #{order_by}" if order_by
        results = db.fetch(sql, [], limit: limit, skip: skip)
        results.map { |row| from_hash(row) }
      end

      def count(conditions = nil, params = [])
        sql = "SELECT COUNT(*) as cnt FROM #{table_name}"
        sql += " WHERE #{conditions}" if conditions
        result = db.fetch_one(sql, params)
        result[:cnt].to_i
      end

      def create(attributes = {})
        instance = new(attributes)
        instance.save
        instance
      end

      def from_hash(hash)
        instance = new
        hash.each do |key, value|
          setter = "#{key}="
          instance.send(setter, value) if instance.respond_to?(setter)
        end
        instance.instance_variable_set(:@persisted, true)
        instance
      end
    end

    def initialize(attributes = {})
      @persisted = false
      @errors = []
      attributes.each do |key, value|
        setter = "#{key}="
        send(setter, value) if respond_to?(setter)
      end
      # Set defaults
      self.class.field_definitions.each do |name, opts|
        if send(name).nil? && opts[:default]
          send("#{name}=", opts[:default])
        end
      end
    end

    def save
      @errors = []
      validate_fields
      return false unless @errors.empty?

      data = to_hash(exclude_nil: true)
      pk = self.class.primary_key_field || :id
      pk_value = send(pk)

      if @persisted && pk_value
        filter = { pk => pk_value }
        data.delete(pk)
        self.class.db.update(self.class.table_name, data, filter)
      else
        result = self.class.db.insert(self.class.table_name, data)
        if result[:last_id] && respond_to?("#{pk}=")
          send("#{pk}=", result[:last_id])
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
      pk_value = send(pk)
      return false unless pk_value

      self.class.db.delete(self.class.table_name, { pk => pk_value })
      @persisted = false
      true
    end

    def load(id = nil)
      pk = self.class.primary_key_field || :id
      id ||= send(pk)
      return false unless id

      result = self.class.db.fetch_one("SELECT * FROM #{self.class.table_name} WHERE #{pk} = ?", [id])
      return false unless result

      result.each do |key, value|
        setter = "#{key}="
        send(setter, value) if respond_to?(setter)
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

    def to_hash(exclude_nil: false)
      hash = {}
      self.class.field_definitions.each_key do |name|
        value = send(name)
        next if exclude_nil && value.nil?
        hash[name] = value
      end
      hash
    end

    def to_json(*_args)
      JSON.generate(to_hash)
    end

    def to_s
      "#<#{self.class.name} #{to_hash}>"
    end

    def select(*fields)
      fields_str = fields.map(&:to_s).join(", ")
      pk = self.class.primary_key_field || :id
      pk_value = send(pk)
      self.class.db.fetch_one("SELECT #{fields_str} FROM #{self.class.table_name} WHERE #{pk} = ?", [pk_value])
    end

    private

    def validate_fields
      self.class.field_definitions.each do |name, opts|
        value = send(name)
        if !opts[:nullable] && value.nil? && !opts[:auto_increment] && !opts[:default]
          @errors << "#{name} cannot be null"
        end
      end
    end
  end
end
