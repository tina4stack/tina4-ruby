# frozen_string_literal: true

module Tina4
  module FieldTypes
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def field_definitions
        @field_definitions ||= {}
      end

      def primary_key_field
        @primary_key_field
      end

      def table_name(name = nil)
        if name
          @table_name = name
        else
          base = self.name.split("::").last.downcase
          # Pluralize by default (add "s") unless ORM_PLURAL_TABLE_NAMES is explicitly disabled
          unless ENV.fetch("TINA4_ORM_PLURAL_TABLE_NAMES", "").match?(/\A(false|0|no)\z/i)
            base += "s" unless base.end_with?("s")
          end
          @table_name || base
        end
      end

      def integer_field(name, primary_key: false, auto_increment: false, nullable: true, default: nil)
        register_field(name, :integer, primary_key: primary_key, auto_increment: auto_increment,
                       nullable: nullable, default: default)
      end

      def string_field(name, length: 255, primary_key: false, nullable: true, default: nil)
        register_field(name, :string, length: length, primary_key: primary_key,
                       nullable: nullable, default: default)
      end

      def text_field(name, nullable: true, default: nil)
        register_field(name, :text, nullable: nullable, default: default)
      end

      def float_field(name, nullable: true, default: nil)
        register_field(name, :float, nullable: nullable, default: default)
      end

      def decimal_field(name, precision: 10, scale: 2, nullable: true, default: nil)
        register_field(name, :decimal, precision: precision, scale: scale,
                       nullable: nullable, default: default)
      end

      def numeric_field(name, nullable: true, default: nil)
        register_field(name, :float, nullable: nullable, default: default)
      end

      def boolean_field(name, nullable: true, default: nil)
        register_field(name, :boolean, nullable: nullable, default: default)
      end

      def date_field(name, nullable: true, default: nil)
        register_field(name, :date, nullable: nullable, default: default)
      end

      def datetime_field(name, nullable: true, default: nil)
        register_field(name, :datetime, nullable: nullable, default: default)
      end

      def timestamp_field(name, nullable: true, default: nil)
        register_field(name, :timestamp, nullable: nullable, default: default)
      end

      def blob_field(name, nullable: true, default: nil)
        register_field(name, :blob, nullable: nullable, default: default)
      end

      def json_field(name, nullable: true, default: nil)
        register_field(name, :json, nullable: nullable, default: default)
      end

      # Declare a foreign key integer column and auto-wire relationships.
      #
      # Automatically:
      #   - Registers an integer field for the column
      #   - Calls belongs_to on this class (strip _id suffix for association name)
      #   - Calls has_many on the referenced class (if already loaded)
      #
      # @param name [Symbol]  Column name (e.g. :user_id)
      # @param references [Class, String]  Referenced model class or its name
      # @param related_name [Symbol, String, nil]  Override the has-many name on the referenced model
      #
      # Example:
      #   class Post < Tina4::ORM
      #     integer_field :id, primary_key: true
      #     foreign_key_field :user_id, references: User
      #   end
      #   # post.user  → belongs_to auto-wired
      #   # user.posts → has_many auto-wired
      def foreign_key_field(name, references:, related_name: nil, **options)
        register_field(name, :integer, **options)

        # Derive association name: strip _id suffix
        belongs_name = name.to_s.end_with?("_id") ? name.to_s[0..-4].to_sym : name.to_sym

        # Wire belongs_to on this class
        belongs_to(belongs_name, class_name: references.to_s.split("::").last, foreign_key: name.to_s) if respond_to?(:belongs_to, true)

        # Wire has_many on referenced class (if already a loaded Class)
        if references.is_a?(Class) && references.respond_to?(:has_many, true)
          hm_name = (related_name || "#{self.name.split("::").last.downcase}s").to_sym
          references.has_many(hm_name, class_name: self.name.split("::").last, foreign_key: name.to_s)
        end

        # Register for deferred wiring (resolves when referenced class is later loaded)
        @@_fk_registry ||= {}
        ref_name = references.is_a?(Class) ? references.name.split("::").last : references.to_s.split("::").last
        @@_fk_registry[ref_name] ||= []
        hm_key = (related_name || "#{self.name.split("::").last.downcase}s").to_s
        @@_fk_registry[ref_name] << {
          declaring_class: self,
          has_many_name: hm_key.to_sym,
          foreign_key: name.to_s
        }
      end

      # Apply any deferred FK-registry has_many wiring for this class.
      # Called automatically when a class that is referenced by a ForeignKeyField is defined.
      def apply_fk_registry!
        class_simple_name = self.name.split("::").last
        return unless defined?(@@_fk_registry) && @@_fk_registry.key?(class_simple_name)

        @@_fk_registry[class_simple_name].each do |entry|
          next if entry[:applied]

          has_many(entry[:has_many_name],
                   class_name: entry[:declaring_class].name.split("::").last,
                   foreign_key: entry[:foreign_key]) if respond_to?(:has_many, true)
          entry[:applied] = true
        end
      end

      private

      def register_field(name, type, **options)
        field_definitions[name] = { type: type }.merge(options)
        @primary_key_field = name if options[:primary_key]

        # Define getter/setter
        attr_accessor name
      end
    end
  end
end
