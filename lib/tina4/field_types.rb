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
          unless ENV.fetch("ORM_PLURAL_TABLE_NAMES", "").match?(/\A(false|0|no)\z/i)
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
