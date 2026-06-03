# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Env do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".load_env" do
    it "creates a default .env file if none exists" do
      Tina4::Env.load_env(tmpdir)
      expect(File.exist?(File.join(tmpdir, ".env"))).to be true
    end

    it "sets default environment variables" do
      # Clear any existing values
      ENV.delete("PROJECT_NAME")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["PROJECT_NAME"]).not_to be_nil
    end

    it "does not override existing environment variables" do
      ENV["PROJECT_NAME"] = "TestProject"
      Tina4::Env.load_env(tmpdir)
      expect(ENV["PROJECT_NAME"]).to eq("TestProject")
      ENV.delete("PROJECT_NAME")
    end

    it "loads environment-specific .env files" do
      File.write(File.join(tmpdir, ".env.test"), 'TEST_VAR="hello_test"')
      ENV["ENVIRONMENT"] = "test"
      ENV.delete("TEST_VAR")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["TEST_VAR"]).to eq("hello_test")
      ENV.delete("TEST_VAR")
    end

    it "parses key=value pairs correctly" do
      File.write(File.join(tmpdir, ".env"), "MY_KEY=\"my_value\"\nANOTHER=plain")
      ENV.delete("MY_KEY")
      ENV.delete("ANOTHER")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["MY_KEY"]).to eq("my_value")
    end

    it "ignores comments" do
      File.write(File.join(tmpdir, ".env"), "# This is a comment\nVALID_KEY=\"valid\"")
      ENV.delete("VALID_KEY")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["VALID_KEY"]).to eq("valid")
      ENV.delete("VALID_KEY")
    end

    it "ignores empty lines" do
      File.write(File.join(tmpdir, ".env"), "\n\nKEY1=\"val1\"\n\nKEY2=\"val2\"\n")
      ENV.delete("KEY1")
      ENV.delete("KEY2")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["KEY1"]).to eq("val1")
      ENV.delete("KEY1")
      ENV.delete("KEY2")
    end
  end

  # ── Typed coercion helpers — parity with tina4_python Env class ─────
  describe "typed coercion (.bool / .int / .float / .str)" do
    # Scoped helper to set + delete the env var around each example so
    # nothing leaks between tests (parallels of pytest's monkeypatch).
    def with_env(name, value)
      previous = ENV[name]
      ENV[name] = value
      yield
    ensure
      previous.nil? ? ENV.delete(name) : ENV[name] = previous
    end

    let(:key) { "TINA4_TYPED_ENV_TEST" }

    before { ENV.delete(key) }
    after  { ENV.delete(key) }

    describe ".bool" do
      it "returns the default when the var is unset" do
        expect(Tina4::Env.bool(key, default: false)).to be false
        expect(Tina4::Env.bool(key, default: true)).to be true
      end

      %w[1 true on yes y t True ON YES Y T  TRUE ].each do |raw|
        it "treats #{raw.inspect} as truthy" do
          with_env(key, raw) { expect(Tina4::Env.bool(key)).to be true }
        end
      end

      %w[0 false off no n f False OFF NO N F].each do |raw|
        it "treats #{raw.inspect} as falsy" do
          with_env(key, raw) { expect(Tina4::Env.bool(key, default: true)).to be false }
        end
      end

      it "treats empty string as falsy" do
        with_env(key, "") { expect(Tina4::Env.bool(key, default: true)).to be false }
      end

      it "falls back to default for unknown tokens" do
        with_env(key, "maybe") { expect(Tina4::Env.bool(key, default: true)).to be true }
        with_env(key, "maybe") { expect(Tina4::Env.bool(key, default: false)).to be false }
      end

      it "strips whitespace before matching" do
        with_env(key, "  true  ") { expect(Tina4::Env.bool(key)).to be true }
        with_env(key, "\tno\n")   { expect(Tina4::Env.bool(key, default: true)).to be false }
      end
    end

    describe ".int" do
      it "returns default when unset" do
        expect(Tina4::Env.int(key, default: 99)).to eq(99)
      end

      it "parses a plain integer" do
        with_env(key, "42") { expect(Tina4::Env.int(key)).to eq(42) }
      end

      it "parses a negative integer" do
        with_env(key, "-17") { expect(Tina4::Env.int(key)).to eq(-17) }
      end

      it "strips surrounding whitespace" do
        with_env(key, "  7\n") { expect(Tina4::Env.int(key)).to eq(7) }
      end

      it "returns default when unparseable (no exception)" do
        with_env(key, "banana") { expect(Tina4::Env.int(key, default: 5)).to eq(5) }
      end

      it "returns default when given a float string" do
        with_env(key, "3.14") { expect(Tina4::Env.int(key, default: 0)).to eq(0) }
      end
    end

    describe ".float" do
      it "returns default when unset" do
        expect(Tina4::Env.float(key, default: 1.5)).to eq(1.5)
      end

      it "parses a plain float" do
        with_env(key, "3.14") { expect(Tina4::Env.float(key)).to eq(3.14) }
      end

      it "parses scientific notation" do
        with_env(key, "1.5e3") { expect(Tina4::Env.float(key)).to eq(1500.0) }
      end

      it "parses an integer as float" do
        with_env(key, "10") { expect(Tina4::Env.float(key)).to eq(10.0) }
      end

      it "returns default on garbage" do
        with_env(key, "not-a-number") { expect(Tina4::Env.float(key, default: 2.5)).to eq(2.5) }
      end
    end

    describe ".str" do
      it "returns default when unset" do
        expect(Tina4::Env.str(key, default: "fallback")).to eq("fallback")
      end

      it "returns the raw value when set" do
        with_env(key, "hello") { expect(Tina4::Env.str(key)).to eq("hello") }
      end

      it "preserves surrounding whitespace (unlike bool/int/float)" do
        with_env(key, "  spaced  ") { expect(Tina4::Env.str(key)).to eq("  spaced  ") }
      end

      it "returns an empty string when explicitly set to empty" do
        with_env(key, "") { expect(Tina4::Env.str(key, default: "fallback")).to eq("") }
      end
    end
  end
end
