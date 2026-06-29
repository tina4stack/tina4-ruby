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

      # The fallback locale used when a key is missing in the current locale.
      # Mirrors the Python master (TINA4_LOCALE, else "en").
      def default_locale
        ENV["TINA4_LOCALE"] || "en"
      end

      def load(root_dir = Dir.pwd)
        locale_search_dirs(root_dir).each do |locale_dir|
          Dir.glob(File.join(locale_dir, "*.json")).each do |file|
            ingest_json_file(File.basename(file, ".json"), file)
          end
          Dir.glob(File.join(locale_dir, "*.{yml,yaml}")).each do |file|
            ingest_yaml_file(File.basename(file, File.extname(file)), file)
          end
        end
      end

      def t(key, locale: nil, default: nil, **interpolations)
        lang = locale || current_locale
        value = lookup(lang, key)

        # Fallback: current locale -> default/fallback locale -> the key itself.
        if value.nil? && lang != default_locale
          value = lookup(default_locale, key)
        end

        value = default || key if value.nil?

        # Interpolation: "Hello {name}" => "Hello World". PARTIAL — each {name}
        # token present in interpolations is replaced; a missing param's
        # placeholder is left literal, and a malformed placeholder ({x.y} with a
        # dot, {n:d} with a spec, a lone unmatched brace) is left literal too.
        # Never raises — a bad template must not crash t().
        interpolate(value, interpolations)
      end

      def set_locale(locale)
        self.current_locale = locale.to_s
        # Lazily load the new locale's file if it hasn't been loaded yet, so a
        # switch to an unloaded locale resolves its keys (parity with Python/PHP/
        # Node, where setting the locale triggers a per-locale load).
        load_locale(locale.to_s) unless translations.key?(locale.to_s)
        current_locale
      end

      # Load a SINGLE locale's file (JSON, then YAML) from the configured search
      # dirs if it is not already loaded. Boot-safe (a malformed file is skipped,
      # never raised) — mirrors Python's _load_locale.
      def load_locale(locale, root_dir = Dir.pwd)
        locale = locale.to_s
        return if translations.key?(locale)

        locale_search_dirs(root_dir).each do |locale_dir|
          json = File.join(locale_dir, "#{locale}.json")
          if File.file?(json)
            ingest_json_file(locale, json)
            return
          end
          %w[yml yaml].each do |ext|
            yaml = File.join(locale_dir, "#{locale}.#{ext}")
            if File.file?(yaml)
              ingest_yaml_file(locale, yaml)
              return
            end
          end
        end
        # No file found — cache an empty table so lookups fall back to the key.
        translations[locale] ||= {}
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

      # List available locale codes by scanning the configured locale dir(s) for
      # *.json / *.yml / *.yaml file stems, sorted. When no dir exists/has files,
      # returns a [default_locale] floor (parity with Python/PHP/Node — never an
      # empty list when a default locale is known).
      def available_locales(root_dir = Dir.pwd)
        stems = []
        locale_search_dirs(root_dir).each do |locale_dir|
          %w[*.json *.yml *.yaml].each do |pattern|
            Dir.glob(File.join(locale_dir, pattern)).each do |file|
              stems << File.basename(file, File.extname(file))
            end
          end
        end
        stems.uniq!
        stems.empty? ? [default_locale] : stems.sort
      end

      private

      # The locale directories to scan, in order: TINA4_LOCALE_DIR override (when
      # set) else the built-in LOCALE_DIRS list, each resolved against root_dir,
      # filtered to those that actually exist.
      def locale_search_dirs(root_dir = Dir.pwd)
        override = ENV["TINA4_LOCALE_DIR"]
        dirs = override && !override.empty? ? [override] : LOCALE_DIRS
        dirs.map { |dir| File.expand_path(dir, root_dir) }.select { |d| Dir.exist?(d) }
      end

      # Parse one JSON locale file into translations + leaf aliases. Boot-safe:
      # a malformed/unreadable file is logged, skipped, and cached empty so a
      # bad file never crashes boot and is never retried into a partial state.
      def ingest_json_file(locale, file)
        data = JSON.parse(File.read(file))
        translations[locale] ||= {}
        translations[locale].merge!(data)
        build_leaf_aliases(locale, data)
        Tina4::Log.debug("Loaded locale: #{locale} from #{file}")
      rescue JSON::ParserError, IOError, SystemCallError, StandardError => e
        Tina4::Log.error("Skipping malformed locale file #{file}: #{e.class}: #{e.message}")
        translations[locale] ||= {}
      end

      # Parse one YAML locale file into translations + leaf aliases. Same
      # boot-safe policy as ingest_json_file (Psych::SyntaxError is the YAML
      # parse error; the broad StandardError is a final safety net).
      def ingest_yaml_file(locale, file)
        require "yaml"
        data = YAML.safe_load(File.read(file))
        if data.is_a?(Hash)
          translations[locale] ||= {}
          translations[locale].merge!(data)
          build_leaf_aliases(locale, data)
        end
      rescue LoadError
        Tina4::Log.warning("YAML support requires the 'yaml' gem")
      rescue Psych::SyntaxError, IOError, SystemCallError, StandardError => e
        Tina4::Log.error("Skipping malformed locale file #{file}: #{e.class}: #{e.message}")
        translations[locale] ||= {}
      end

      # {name} placeholder. Matches Python's _PLACEHOLDER = \{(\w+)\}, so only a
      # bare word inside braces is a candidate — {x.y} (a dot) and {n:d} (a spec)
      # never match and are left literal, and a lone unmatched brace is untouched.
      PLACEHOLDER = /\{(\w+)\}/.freeze

      # Substitute {name} placeholders from params. PARTIAL + literal-leftover:
      # a placeholder present in params is replaced; a missing or malformed
      # placeholder is left untouched. Never raises (a bad template must not
      # crash t()). Params may be keyed by symbol (kwargs) or string.
      def interpolate(template, params)
        return template unless template.is_a?(String)
        return template if params.nil? || params.empty?

        template.gsub(PLACEHOLDER) do
          name = Regexp.last_match(1)
          if params.key?(name.to_sym)
            params[name.to_sym].to_s
          elsif params.key?(name)
            params[name].to_s
          else
            Regexp.last_match(0)
          end
        end
      end

      # Render a non-string locale scalar JSON-natively: boolean true/false ->
      # "true"/"false", null/nil -> "null", numbers as their plain form ("42").
      def coerce_scalar(value)
        case value
        when true then "true"
        when false then "false"
        when nil then "null"
        else value.to_s
        end
      end

      # Recursively walk a nested hash and register leaf-key aliases.
      # First-wins: if a leaf key already exists, it is NOT overwritten.
      def build_leaf_aliases(locale, hash, prefix = nil)
        flat_aliases[locale.to_s] ||= {}
        hash.each do |key, value|
          full_key = prefix ? "#{prefix}.#{key}" : key.to_s
          if value.is_a?(Hash)
            build_leaf_aliases(locale, value, full_key)
          else
            # Store the leaf key as an alias (first-wins). Coerce non-string
            # JSON-native scalars (true/false/null/number) to their string form.
            flat_aliases[locale.to_s][key.to_s] ||= coerce_scalar(value)
          end
        end
      end

      def lookup(locale, key)
        keys = key.to_s.split(".")
        node = translations[locale]
        return nil unless node

        # Try dot-path traversal first. Track found-ness explicitly so a leaf
        # whose value is false/nil is still recognised as resolved.
        found = true
        keys.each do |k|
          if node.is_a?(Hash) && (node.key?(k) || node.key?(k.to_sym))
            node = node.key?(k) ? node[k] : node[k.to_sym]
          else
            found = false
            break
          end
        end
        # A resolved leaf (string OR JSON-native scalar) wins. An intermediate
        # Hash is not a value — fall through to the leaf alias instead.
        return coerce_scalar(node) if found && !node.is_a?(Hash)

        # Fall back to leaf-key alias (stored already-coerced as a string).
        if flat_aliases[locale]
          alias_val = flat_aliases[locale][key.to_s]
          return alias_val if alias_val.is_a?(String)
        end

        nil
      end
    end
  end
end
