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
          # Pluralization is OFF by default (canonical, matching the Python
          # master): the table name is the bare class name lowercased. Opt in by
          # setting TINA4_ORM_PLURAL_TABLE_NAMES to a truthy value (true/1/yes/on)
          # to append "s".
          if ENV.fetch("TINA4_ORM_PLURAL_TABLE_NAMES", "").match?(/\A(true|1|yes|on)\z/i)
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
      #   - Calls has_many on the referenced class. The accessor name is the
      #     declaring class name lowercased + "s" (e.g. Post → posts), matching
      #     Python; override with related_name:. Works whether the referenced
      #     class loaded before OR after this one, including the string form
      #     (references: "Author") for forward references — resolution is
      #     deferred via Tina4::ORM.inherited until the target class exists.
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

        # If the referenced model is ALREADY loaded (string form whose target
        # is defined, or any forward reference that has since resolved), wire
        # the deferred entry right now. The inherited hook on Tina4::ORM only
        # fires when a NEW class is defined, so a string reference to a class
        # that loaded BEFORE this one would otherwise never wire its has_many
        # side. resolve_referenced_class returns the live class for either the
        # Class or the string form.
        resolved = resolve_referenced_class(references)
        resolved.apply_fk_registry! if resolved && resolved.respond_to?(:apply_fk_registry!, true)
      end

      # Resolve a ForeignKeyField `references:` argument to a live Tina4::ORM
      # subclass, or nil if it is not (yet) loaded. Accepts either a Class or a
      # class-name String (with or without a namespace). The string form is the
      # documented deferred-safe path: a bare constant used before its class is
      # defined raises NameError (plain Ruby), so forward references must be
      # written as strings.
      def resolve_referenced_class(references)
        return references if references.is_a?(Class)
        return nil unless defined?(Tina4::ORM) && Tina4::ORM.respond_to?(:model_subclasses)

        simple = references.to_s.split("::").last
        Tina4::ORM.model_subclasses.find do |klass|
          klass.name && klass.name.split("::").last == simple
        end
      rescue StandardError
        nil
      end

      # Apply any deferred FK-registry has_many wiring for this class.
      # Called automatically when a class that is referenced by a ForeignKeyField is defined.
      def apply_fk_registry!
        # Anonymous classes (Class.new(Tina4::ORM), common in specs) have a nil
        # name and can never be a string-form ForeignKeyField target, so there
        # is nothing to wire — bail out instead of raising on nil.split.
        return if name.nil?

        class_simple_name = name.split("::").last
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

        # Getter (plain reader) + an assignment-tracking setter.
        #
        # #165: save() must tell a column the caller EXPLICITLY set to nil
        # (write it — an explicit nil becomes SQL NULL) from one left UNSET
        # (omit it from the INSERT so a NOT NULL DEFAULT column gets its DB
        # default instead of an explicit NULL). The setter records the field
        # name in @assigned_fields on every caller assignment — via the
        # constructor's attribute application, a from_hash/load populate, or a
        # direct `model.field = x`. Field DEFAULTS are seeded in #initialize
        # with instance_variable_set (bypassing this setter), so a default is
        # never counted as a caller assignment. Mirrors the Python master's
        # __setattr__ + object.__setattr__ default-seeding.
        attr_reader name
        define_method("#{name}=") do |value|
          fields = (@assigned_fields ||= [])
          fields << name unless fields.include?(name)
          instance_variable_set("@#{name}", value)
        end
      end
    end
  end
end
