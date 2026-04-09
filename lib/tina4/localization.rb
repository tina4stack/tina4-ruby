# frozen_string_literal: true
require "json"

module Tina4
  module Localization
    LOCALE_DIRS = %w[locales translations i18n src/locales].freeze

    class << self
      def translations
        @translations ||= {}
      end

      def current_locale
        @current_locale || ENV["TINA4_LOCALE"] || "en"
      end

      def current_locale=(locale)
        @current_locale = locale.to_s
      end

      def load(root_dir = Dir.pwd)
        LOCALE_DIRS.each do |dir|
          locale_dir = File.join(root_dir, dir)
          next unless Dir.exist?(locale_dir)

          Dir.glob(File.join(locale_dir, "*.json")).each do |file|
            locale = File.basename(file, ".json")
            data = JSON.parse(File.read(file))
            translations[locale] ||= {}
            translations[locale].merge!(data)
            Tina4::Log.debug("Loaded locale: #{locale} from #{file}")
          end

          # Also support YAML
          Dir.glob(File.join(locale_dir, "*.{yml,yaml}")).each do |file|
            begin
              require "yaml"
              locale = File.basename(file, File.extname(file))
              data = YAML.safe_load(File.read(file))
              translations[locale] ||= {}
              translations[locale].merge!(data) if data.is_a?(Hash)
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
      end

      def available_locales
        translations.keys
      end

      private

      def lookup(locale, key)
        keys = key.to_s.split(".")
        result = translations[locale]
        return nil unless result

        keys.each do |k|
          if result.is_a?(Hash)
            result = result[k] || result[k.to_sym]
          else
            return nil
          end
        end
        result.is_a?(String) ? result : nil
      end
    end
  end
end
