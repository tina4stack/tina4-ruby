# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Localization do
  before(:each) do
    # Reset translations state between tests
    Tina4::Localization.instance_variable_set(:@translations, {})
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

    it "performs string interpolation with %{name}" do
      Tina4::Localization.add("en", "hello", "Hello %{name}!")
      result = Tina4::Localization.t("hello", name: "World")
      expect(result).to eq("Hello World!")
    end

    it "performs multiple interpolations" do
      Tina4::Localization.add("en", "info", "%{name} is %{age} years old")
      result = Tina4::Localization.t("info", name: "Alice", age: 30)
      expect(result).to eq("Alice is 30 years old")
    end

    it "leaves unmatched placeholders as-is when no interpolation provided" do
      Tina4::Localization.add("en", "template", "Hello %{name}")
      result = Tina4::Localization.t("template")
      expect(result).to eq("Hello %{name}")
    end
  end

  describe ".available_locales" do
    it "returns empty array when no translations loaded" do
      expect(Tina4::Localization.available_locales).to eq([])
    end

    it "returns locales that have been added" do
      Tina4::Localization.add("en", "hello", "Hello")
      Tina4::Localization.add("fr", "hello", "Bonjour")
      locales = Tina4::Localization.available_locales
      expect(locales).to include("en")
      expect(locales).to include("fr")
    end
  end

  describe ".translations" do
    it "returns a hash" do
      expect(Tina4::Localization.translations).to be_a(Hash)
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

    it "searches multiple directory names" do
      expect(Tina4::Localization::LOCALE_DIRS).to include("locales")
      expect(Tina4::Localization::LOCALE_DIRS).to include("translations")
      expect(Tina4::Localization::LOCALE_DIRS).to include("i18n")
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
end
