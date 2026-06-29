# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Localization do
  before(:each) do
    # Reset translations state between tests
    Tina4::Localization.instance_variable_set(:@translations, {})
    Tina4::Localization.instance_variable_set(:@flat_aliases, {})
    Tina4::Localization.instance_variable_set(:@current_locale, nil)
  end

  describe ".current_locale" do
    it "defaults to 'en'" do
      ENV.delete("TINA4_LOCALE")
      expect(Tina4::Localization.current_locale).to eq("en")
    end

    it "reads from TINA4_LOCALE env var" do
      original = ENV["TINA4_LOCALE"]
      ENV["TINA4_LOCALE"] = "fr"
      Tina4::Localization.instance_variable_set(:@current_locale, nil)
      expect(Tina4::Localization.current_locale).to eq("fr")
      ENV["TINA4_LOCALE"] = original
    end

    it "can be set explicitly" do
      Tina4::Localization.current_locale = "de"
      expect(Tina4::Localization.current_locale).to eq("de")
    end

    it "converts symbol locale to string" do
      Tina4::Localization.current_locale = :ja
      expect(Tina4::Localization.current_locale).to eq("ja")
    end
  end

  describe ".add and .t" do
    it "adds and retrieves a simple key" do
      Tina4::Localization.add("en", "greeting", "Hello")
      expect(Tina4::Localization.t("greeting")).to eq("Hello")
    end

    it "supports nested dot-notation keys" do
      Tina4::Localization.add("en", "messages.welcome", "Welcome!")
      expect(Tina4::Localization.t("messages.welcome")).to eq("Welcome!")
    end

    it "returns the key itself when no translation found" do
      expect(Tina4::Localization.t("missing.key")).to eq("missing.key")
    end

    it "returns default when provided and key missing" do
      result = Tina4::Localization.t("missing.key", default: "Fallback")
      expect(result).to eq("Fallback")
    end

    it "looks up in the specified locale" do
      Tina4::Localization.add("fr", "greeting", "Bonjour")
      expect(Tina4::Localization.t("greeting", locale: "fr")).to eq("Bonjour")
    end

    it "falls back to English when locale translation missing" do
      Tina4::Localization.add("en", "greeting", "Hello")
      expect(Tina4::Localization.t("greeting", locale: "de")).to eq("Hello")
    end

    it "uses current_locale for lookups" do
      Tina4::Localization.add("es", "greeting", "Hola")
      Tina4::Localization.current_locale = "es"
      expect(Tina4::Localization.t("greeting")).to eq("Hola")
    end

    it "performs string interpolation with {name}" do
      Tina4::Localization.add("en", "hello", "Hello {name}!")
      result = Tina4::Localization.t("hello", name: "World")
      expect(result).to eq("Hello World!")
    end

    it "performs multiple interpolations" do
      Tina4::Localization.add("en", "info", "{name} is {age} years old")
      result = Tina4::Localization.t("info", name: "Alice", age: 30)
      expect(result).to eq("Alice is 30 years old")
    end

    it "leaves unmatched placeholders as-is when no interpolation provided" do
      Tina4::Localization.add("en", "template", "Hello {name}")
      result = Tina4::Localization.t("template")
      expect(result).to eq("Hello {name}")
    end
  end

  describe ".available_locales" do
    # BREAKING (3.13.x i18n parity): available_locales now SCANS the locale
    # directory for *.json/*.yml/*.yaml stems (sorted) instead of returning the
    # in-memory loaded-keys, and returns a [default_locale] floor when no
    # directory exists/has files. Matches Python/PHP/Node.
    it "returns a [default_locale] floor when no locale directory exists" do
      ENV.delete("TINA4_LOCALE_DIR")
      ENV.delete("TINA4_LOCALE")
      Tina4::Localization.instance_variable_set(:@current_locale, nil)
      expect(Tina4::Localization.available_locales("/nonexistent/path")).to eq(["en"])
    end

    it "honours TINA4_LOCALE for the default-locale floor" do
      original = ENV["TINA4_LOCALE"]
      ENV["TINA4_LOCALE"] = "fr"
      expect(Tina4::Localization.available_locales("/nonexistent/path")).to eq(["fr"])
      ENV["TINA4_LOCALE"] = original
    end
  end

  describe ".translations" do
    it "reflects an added translation in its locale-keyed structure" do
      Tina4::Localization.add("en", "k", "v")
      expect(Tina4::Localization.translations).to be_a(Hash)
      expect(Tina4::Localization.translations.keys).to eq(["en"])
      expect(Tina4::Localization.translations.dig("en", "k")).to eq("v")
    end

    it "stores translations keyed by locale" do
      Tina4::Localization.add("en", "test", "Test value")
      expect(Tina4::Localization.translations["en"]).to be_a(Hash)
      expect(Tina4::Localization.translations["en"]["test"]).to eq("Test value")
    end
  end

  describe ".load from directory" do
    let(:tmpdir) { Dir.mktmpdir }

    after(:each) do
      FileUtils.remove_entry(tmpdir)
    end

    it "loads JSON locale files from locales/ directory" do
      locale_dir = File.join(tmpdir, "locales")
      FileUtils.mkdir_p(locale_dir)
      File.write(File.join(locale_dir, "en.json"), '{"hello": "Hello", "bye": "Goodbye"}')

      Tina4::Localization.load(tmpdir)

      expect(Tina4::Localization.t("hello")).to eq("Hello")
      expect(Tina4::Localization.t("bye")).to eq("Goodbye")
    end

    it "loads multiple locale files" do
      locale_dir = File.join(tmpdir, "locales")
      FileUtils.mkdir_p(locale_dir)
      File.write(File.join(locale_dir, "en.json"), '{"hello": "Hello"}')
      File.write(File.join(locale_dir, "fr.json"), '{"hello": "Bonjour"}')

      Tina4::Localization.load(tmpdir)

      expect(Tina4::Localization.t("hello", locale: "en")).to eq("Hello")
      expect(Tina4::Localization.t("hello", locale: "fr")).to eq("Bonjour")
    end

    it "does not crash when locale directory does not exist" do
      expect { Tina4::Localization.load("/nonexistent/path") }.not_to raise_error
    end

    it "actually scans each non-default LOCALE_DIRS entry, not just locales/" do
      # Prove the loader walks every directory name in LOCALE_DIRS (beyond the
      # primary "locales/") by placing a distinct locale file in each one and
      # asserting all of them are loaded in a single .load pass.
      %w[translations i18n].each do |dir_name|
        # Guard against a regression where a name is dropped from LOCALE_DIRS.
        expect(Tina4::Localization::LOCALE_DIRS).to include(dir_name)

        scan_dir = File.join(tmpdir, dir_name)
        FileUtils.mkdir_p(scan_dir)
        File.write(File.join(scan_dir, "en.json"), %({"from_#{dir_name}": "value-#{dir_name}"}))
      end

      Tina4::Localization.load(tmpdir)

      expect(Tina4::Localization.t("from_translations")).to eq("value-translations")
      expect(Tina4::Localization.t("from_i18n")).to eq("value-i18n")
    end
  end

  describe "deeply nested keys" do
    it "builds nested hash structure with dot-notation" do
      Tina4::Localization.add("en", "a.b.c", "deep value")
      expect(Tina4::Localization.t("a.b.c")).to eq("deep value")
    end

    it "returns nil for partial key path that resolves to hash" do
      Tina4::Localization.add("en", "a.b.c", "deep value")
      # Looking up "a.b" resolves to a Hash, not a String, so returns nil then falls back
      expect(Tina4::Localization.t("a.b")).to eq("a.b")
    end
  end

  describe "leaf-key aliasing" do
    it "resolves a leaf key from nested JSON" do
      locale_dir = Dir.mktmpdir
      locales_path = File.join(locale_dir, "locales")
      FileUtils.mkdir_p(locales_path)
      File.write(File.join(locales_path, "en.json"), '{"nav": {"home": "Home", "about": "About"}}')

      Tina4::Localization.load(locale_dir)

      # Leaf key works
      expect(Tina4::Localization.t("home")).to eq("Home")
      expect(Tina4::Localization.t("about")).to eq("About")

      FileUtils.remove_entry(locale_dir)
    end

    it "still resolves dot-path keys" do
      locale_dir = Dir.mktmpdir
      locales_path = File.join(locale_dir, "locales")
      FileUtils.mkdir_p(locales_path)
      File.write(File.join(locales_path, "en.json"), '{"nav": {"home": "Home"}}')

      Tina4::Localization.load(locale_dir)

      # Dot-path still works
      expect(Tina4::Localization.t("nav.home")).to eq("Home")

      FileUtils.remove_entry(locale_dir)
    end

    it "dot-path takes priority over leaf alias" do
      # Add a top-level "home" and a nested "nav.home"
      Tina4::Localization.add("en", "home", "Top-level Home")
      Tina4::Localization.add("en", "nav.home", "Nav Home")

      # "home" resolves via dot-path to the top-level value
      expect(Tina4::Localization.t("home")).to eq("Top-level Home")
      # "nav.home" resolves via dot-path
      expect(Tina4::Localization.t("nav.home")).to eq("Nav Home")
    end

    it "first-wins on leaf key conflict" do
      locale_dir = Dir.mktmpdir
      locales_path = File.join(locale_dir, "locales")
      FileUtils.mkdir_p(locales_path)
      # Two nested structures with the same leaf key "title"
      File.write(File.join(locales_path, "en.json"), '{"nav": {"title": "Nav Title"}, "page": {"title": "Page Title"}}')

      Tina4::Localization.load(locale_dir)

      # "title" alias should be the first one encountered (nav.title)
      expect(Tina4::Localization.t("title")).to eq("Nav Title")
      # But dot-paths still resolve correctly
      expect(Tina4::Localization.t("page.title")).to eq("Page Title")

      FileUtils.remove_entry(locale_dir)
    end

    it "handles mixed flat and nested keys" do
      locale_dir = Dir.mktmpdir
      locales_path = File.join(locale_dir, "locales")
      FileUtils.mkdir_p(locales_path)
      File.write(File.join(locales_path, "en.json"), '{"greeting": "Hello", "nav": {"home": "Home"}}')

      Tina4::Localization.load(locale_dir)

      # Flat key
      expect(Tina4::Localization.t("greeting")).to eq("Hello")
      # Nested dot-path
      expect(Tina4::Localization.t("nav.home")).to eq("Home")
      # Leaf alias
      expect(Tina4::Localization.t("home")).to eq("Home")

      FileUtils.remove_entry(locale_dir)
    end

    it "leaf alias works when added via add()" do
      Tina4::Localization.add("en", "messages.welcome", "Welcome!")

      # Dot-path works
      expect(Tina4::Localization.t("messages.welcome")).to eq("Welcome!")
      # Leaf alias works
      expect(Tina4::Localization.t("welcome")).to eq("Welcome!")
    end
  end

  describe "TINA4_LOCALE_DIR env var" do
    it "loads from custom locale directory" do
      locale_dir = Dir.mktmpdir
      FileUtils.mkdir_p(locale_dir)
      File.write(File.join(locale_dir, "en.json"), '{"custom": "Custom Value"}')

      original = ENV["TINA4_LOCALE_DIR"]
      ENV["TINA4_LOCALE_DIR"] = locale_dir

      Tina4::Localization.load("/nonexistent")

      expect(Tina4::Localization.t("custom")).to eq("Custom Value")

      ENV["TINA4_LOCALE_DIR"] = original
      FileUtils.remove_entry(locale_dir)
    end
  end

  describe "auto-wire i18n template global" do
    before(:each) do
      # Reset template globals
      Tina4::Template.instance_variable_set(:@globals, {})
    end

    it "registers t() when locales exist" do
      Tina4::Localization.add("en", "hello", "Hello")

      # Simulate the auto-wire logic
      Tina4.send(:autowire_i18n_template_global)

      expect(Tina4::Template.globals).to have_key("t")
      expect(Tina4::Template.globals["t"]).to respond_to(:call)
      expect(Tina4::Template.globals["t"].call("hello")).to eq("Hello")
    end

    it "does nothing when no locales are loaded" do
      # translations is empty (reset in before(:each))
      Tina4.send(:autowire_i18n_template_global)

      expect(Tina4::Template.globals).not_to have_key("t")
    end

    it "does not overwrite user-registered t()" do
      Tina4::Localization.add("en", "hello", "Hello")
      custom_t = ->(key) { "custom: #{key}" }
      Tina4::Template.add_global("t", custom_t)

      Tina4.send(:autowire_i18n_template_global)

      # Should still be the user's custom t()
      expect(Tina4::Template.globals["t"]).to eq(custom_t)
      expect(Tina4::Template.globals["t"].call("hello")).to eq("custom: hello")
    end
  end

  # ── Lock-in regression tests for the cross-framework i18n contract ──────────
  #
  # Each writes REAL locale files on disk and exercises the real Localization
  # module (NO mocks). Named to mirror the Python master's TestI18nContractFixes
  # plus the Ruby-specific fixes (BUG-1, BUG-4, BUG-5, available_locales scan).
  describe "i18n contract lock-in" do
    def write_locale(data, basename = "en.json")
      dir = Dir.mktmpdir
      locales = File.join(dir, "locales")
      FileUtils.mkdir_p(locales)
      File.write(File.join(locales, basename), data)
      dir
    end

    # BUG-2: leaf-alias must be first-wins on a leaf collision.
    it "leaf_alias_first_wins_on_conflict" do
      dir = write_locale('{"nav": {"title": "Navigation Title"}, "page": {"title": "Page Title"}}')
      Tina4::Localization.load(dir)

      expect(Tina4::Localization.t("title")).to eq("Navigation Title") # first dot-path wins
      expect(Tina4::Localization.t("nav.title")).to eq("Navigation Title")
      expect(Tina4::Localization.t("page.title")).to eq("Page Title")

      FileUtils.remove_entry(dir)
    end

    # BUG-2: an explicit top-level flat key is NEVER overwritten by a derived alias.
    it "leaf_alias_does_not_overwrite_explicit_flat_key" do
      dir = write_locale('{"home": "Flat Home", "nav": {"home": "Nested Home"}}')
      Tina4::Localization.load(dir)

      expect(Tina4::Localization.t("home")).to eq("Flat Home") # explicit flat wins, no data loss
      expect(Tina4::Localization.t("nav.home")).to eq("Nested Home")

      FileUtils.remove_entry(dir)
    end

    # BUG-1 / BUG-3: {name} token (NOT %{name}); partial — missing left literal.
    it "interpolation_uses_curly_brace_token" do
      dir = write_locale('{"hello": "Hello {name}!"}')
      Tina4::Localization.load(dir)

      expect(Tina4::Localization.t("hello", name: "World")).to eq("Hello World!")
      # The old Rails %{name} syntax is gone (BREAKING) — it is not a token now.
      Tina4::Localization.add("en", "rails", "Hi %{name}")
      expect(Tina4::Localization.t("rails", name: "Bob")).not_to eq("Hi Bob")

      FileUtils.remove_entry(dir)
    end

    it "interpolation_partial_leaves_missing_literal" do
      dir = write_locale('{"pair": "Hi {first} and {second}"}')
      Tina4::Localization.load(dir)

      expect(Tina4::Localization.t("pair", first: "A")).to eq("Hi A and {second}")

      FileUtils.remove_entry(dir)
    end

    it "interpolation_never_crashes_on_stray_brace" do
      dir = write_locale('{"oops": "Set { and forget"}')
      Tina4::Localization.load(dir)

      result = nil
      expect { result = Tina4::Localization.t("oops", name: "Alice") }.not_to raise_error
      expect(result).to eq("Set { and forget")

      FileUtils.remove_entry(dir)
    end

    it "interpolation_never_crashes_on_attr_or_spec" do
      dir = write_locale('{"attr": "Hello {name.first}", "spec": "You have {n:d} items"}')
      Tina4::Localization.load(dir)

      attr_result = nil
      spec_result = nil
      expect { attr_result = Tina4::Localization.t("attr", name: "Alice") }.not_to raise_error
      expect { spec_result = Tina4::Localization.t("spec", n: "five") }.not_to raise_error
      expect(attr_result).to eq("Hello {name.first}")
      expect(spec_result).to eq("You have {n:d} items")

      FileUtils.remove_entry(dir)
    end

    # BUG-6: non-string scalars render JSON-native (true/false/null/number).
    it "non_string_scalar_coercion_json_native" do
      dir = write_locale('{"flag": true, "off": false, "nil": null, "num": 42}')
      Tina4::Localization.load(dir)

      expect(Tina4::Localization.t("flag")).to eq("true")
      expect(Tina4::Localization.t("off")).to eq("false")
      expect(Tina4::Localization.t("nil")).to eq("null")
      expect(Tina4::Localization.t("num")).to eq("42")

      FileUtils.remove_entry(dir)
    end

    # FP-7: translate(locale:) switches, translates, and RESTORES the prior locale.
    it "translate_override_restores_locale" do
      dir = Dir.mktmpdir
      locales = File.join(dir, "locales")
      FileUtils.mkdir_p(locales)
      File.write(File.join(locales, "en.json"), '{"greeting": "Hello"}')
      File.write(File.join(locales, "fr.json"), '{"greeting": "Bonjour"}')
      Tina4::Localization.load(dir)

      expect(Tina4::Localization.translate("greeting", locale: "fr")).to eq("Bonjour")
      expect(Tina4::Localization.get_locale).to eq("en") # restored

      FileUtils.remove_entry(dir)
    end

    # BUG-4: a malformed locale file (JSON or YAML) must NEVER crash boot.
    it "malformed_locale_file_does_not_crash" do
      dir = Dir.mktmpdir
      locales = File.join(dir, "locales")
      FileUtils.mkdir_p(locales)
      File.write(File.join(locales, "en.json"), '{"broken": ')          # malformed JSON
      File.write(File.join(locales, "fr.yml"), "a: b:\n  - [oops")        # malformed YAML
      File.write(File.join(locales, "de.json"), '{"ok": "Hallo"}')        # a good neighbour

      expect { Tina4::Localization.load(dir) }.not_to raise_error
      # The good file still loaded; the broken locales degrade to key-fallback.
      expect(Tina4::Localization.t("ok", locale: "de")).to eq("Hallo")
      expect(Tina4::Localization.t("broken", locale: "en")).to eq("broken")
      expect(Tina4::Localization.t("missing", locale: "fr")).to eq("missing")

      FileUtils.remove_entry(dir)
    end

    # BUG-5: set_locale lazily loads the new locale's file (like Python/PHP/Node).
    it "set_locale_lazy_loads_file" do
      dir = Dir.mktmpdir
      locales = File.join(dir, "locales")
      FileUtils.mkdir_p(locales)
      File.write(File.join(locales, "fr.json"), '{"greeting": "Bonjour"}')

      original = ENV["TINA4_LOCALE_DIR"]
      ENV["TINA4_LOCALE_DIR"] = locales
      begin
        # Nothing loaded yet (no .load call).
        expect(Tina4::Localization.translations).not_to have_key("fr")
        Tina4::Localization.set_locale("fr")
        # The fr file is now loaded on switch and resolves.
        expect(Tina4::Localization.translations).to have_key("fr")
        expect(Tina4::Localization.t("greeting")).to eq("Bonjour")
      ensure
        ENV["TINA4_LOCALE_DIR"] = original
      end

      FileUtils.remove_entry(dir)
    end

    # available_locales scans the dir for stems, sorted, with a default floor.
    it "available_locales_scans_dir_with_default_floor" do
      dir = Dir.mktmpdir
      locales = File.join(dir, "locales")
      FileUtils.mkdir_p(locales)
      File.write(File.join(locales, "en.json"), '{"a": "1"}')
      File.write(File.join(locales, "de.json"), '{"a": "1"}')
      File.write(File.join(locales, "fr.yml"), "a: 1")

      original = ENV["TINA4_LOCALE_DIR"]
      ENV["TINA4_LOCALE_DIR"] = locales
      begin
        expect(Tina4::Localization.available_locales).to eq(%w[de en fr]) # scanned + sorted
      ensure
        ENV["TINA4_LOCALE_DIR"] = original
      end

      # Floor: no dir -> [default_locale].
      ENV.delete("TINA4_LOCALE_DIR")
      ENV.delete("TINA4_LOCALE")
      Tina4::Localization.instance_variable_set(:@current_locale, nil)
      expect(Tina4::Localization.available_locales("/nonexistent/path")).to eq(["en"])

      FileUtils.remove_entry(dir)
    end
  end
end
