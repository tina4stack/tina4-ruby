# frozen_string_literal: true
require "json"

module Tina4
  module Localization
    LOCALE_DIRS = %w[locales translations i18n src/locales].freeze

    class << self
      def translations
        @translations ||= {}
      end

      # Flat alias map: { locale => { leaf_key => value } }
      # First-wins on conflict — later duplicates are ignored.
      def flat_aliases
        @flat_aliases ||= {}
      end

      def current_locale
        @current_locale || ENV["TINA4_LOCALE"] || "en"
      end

      def current_locale=(locale)
        @current_locale = locale.to_s
      end

      def load(root_dir = Dir.pwd)
        locale_dir_override = ENV["TINA4_LOCALE_DIR"]
        search_dirs = locale_dir_override && !locale_dir_override.empty? ? [locale_dir_override] : LOCALE_DIRS

        search_dirs.each do |dir|
          locale_dir = File.expand_path(dir, root_dir)
          next unless Dir.exist?(locale_dir)

          Dir.glob(File.join(locale_dir, "*.json")).each do |file|
            locale = File.basename(file, ".json")
            data = JSON.parse(File.read(file))
            translations[locale] ||= {}
            translations[locale].merge!(data)
            # Build leaf-key aliases from the loaded data
            build_leaf_aliases(locale, data)
            Tina4::Log.debug("Loaded locale: #{locale} from #{file}")
          end

          # Also support YAML
          Dir.glob(File.join(locale_dir, "*.{yml,yaml}")).each do |file|
            begin
              require "yaml"
              locale = File.basename(file, File.extname(file))
              data = YAML.safe_load(File.read(file))
              if data.is_a?(Hash)
                translations[locale] ||= {}
                translations[locale].merge!(data)
                build_leaf_aliases(locale, data)
              end
            rescue LoadError
              Tina4::Log.warning("YAML support requires the 'yaml' gem")
            end
          end
        end
      end

      def t(key, locale: nil, default: nil, **interpolations)
        lang = locale || current_locale
        value = lookup(lang, key)

        if value.nil? && lang != "en"
          value = lookup("en", key)
        end

        value = default || key if value.nil?

        # Interpolation: "Hello %{name}" => "Hello World"
        interpolations.each do |k, v|
          value = value.gsub("%{#{k}}", v.to_s)
        end

        value
      end

      def set_locale(locale)
        self.current_locale = locale.to_s
      end

      def get_locale
        current_locale
      end

      def translate(key, params: nil, locale: nil)
        t(key, locale: locale, **(params || {}))
      end

      def load_translations(locale)
        load(Dir.pwd) if translations.empty?
        translations[locale.to_s] || {}
      end

      def add_translation(locale, key, value)
        add(locale, key, value)
      end

      def add(locale, key, value)
        translations[locale.to_s] ||= {}
        keys = key.to_s.split(".")
        hash = translations[locale.to_s]
        keys[0..-2].each do |k|
          hash[k] ||= {}
          hash = hash[k]
        end
        hash[keys.last] = value

        # Register leaf-key alias (first-wins)
        leaf = keys.last
        if value.is_a?(String)
          flat_aliases[locale.to_s] ||= {}
          flat_aliases[locale.to_s][leaf] ||= value
        end
      end

      def available_locales
        translations.keys
      end

      private

      # Recursively walk a nested hash and register leaf-key aliases.
      # First-wins: if a leaf key already exists, it is NOT overwritten.
      def build_leaf_aliases(locale, hash, prefix = nil)
        flat_aliases[locale.to_s] ||= {}
        hash.each do |key, value|
          full_key = prefix ? "#{prefix}.#{key}" : key.to_s
          if value.is_a?(Hash)
            build_leaf_aliases(locale, value, full_key)
          else
            # Store the leaf key as an alias (first-wins)
            flat_aliases[locale.to_s][key.to_s] ||= value
          end
        end
      end

      def lookup(locale, key)
        keys = key.to_s.split(".")
        result = translations[locale]
        return nil unless result

        # Try dot-path traversal first
        dot_result = result
        keys.each do |k|
          if dot_result.is_a?(Hash)
            dot_result = dot_result[k] || dot_result[k.to_sym]
          else
            dot_result = nil
            break
          end
        end
        return dot_result if dot_result.is_a?(String)

        # Fall back to leaf-key alias (only for simple keys without dots)
        if flat_aliases[locale]
          alias_val = flat_aliases[locale][key.to_s]
          return alias_val if alias_val.is_a?(String)
        end

        nil
      end
    end
  end
end
