# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Env do
  let(:tmpdir) { Dir.mktmpdir("tina4_dotenv_test") }

  after(:each) do
    Tina4::Env.reset_env if Tina4::Env.respond_to?(:reset_env)
    FileUtils.rm_rf(tmpdir)
  end

  # ── load_env Positive Tests ──────────────────────────────────────

  describe ".load_env" do
    it "loads basic key=value pairs" do
      File.write(File.join(tmpdir, ".env"), "DOTENV_FOO=bar\nDOTENV_BAZ=qux\n")
      ENV.delete("DOTENV_FOO")
      ENV.delete("DOTENV_BAZ")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_FOO"]).to eq("bar")
      expect(ENV["DOTENV_BAZ"]).to eq("qux")
      ENV.delete("DOTENV_FOO")
      ENV.delete("DOTENV_BAZ")
    end

    it "loads double-quoted values" do
      File.write(File.join(tmpdir, ".env"), 'DOTENV_NAME="hello world"')
      ENV.delete("DOTENV_NAME")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_NAME"]).to eq("hello world")
      ENV.delete("DOTENV_NAME")
    end

    it "loads single-quoted values" do
      File.write(File.join(tmpdir, ".env"), "DOTENV_SINGLE='single quoted'")
      ENV.delete("DOTENV_SINGLE")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_SINGLE"]).to eq("single quoted")
      ENV.delete("DOTENV_SINGLE")
    end

    it "ignores comment lines" do
      File.write(File.join(tmpdir, ".env"), "# comment\nDOTENV_VALID=ok\n# another comment\n")
      ENV.delete("DOTENV_VALID")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_VALID"]).to eq("ok")
      ENV.delete("DOTENV_VALID")
    end

    it "ignores blank lines" do
      File.write(File.join(tmpdir, ".env"), "\n\nDOTENV_KEY1=val1\n\nDOTENV_KEY2=val2\n")
      ENV.delete("DOTENV_KEY1")
      ENV.delete("DOTENV_KEY2")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_KEY1"]).to eq("val1")
      expect(ENV["DOTENV_KEY2"]).to eq("val2")
      ENV.delete("DOTENV_KEY1")
      ENV.delete("DOTENV_KEY2")
    end

    it "does not override existing environment variables" do
      ENV["DOTENV_EXISTING"] = "original"
      File.write(File.join(tmpdir, ".env"), "DOTENV_EXISTING=new_value\n")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_EXISTING"]).to eq("original")
      ENV.delete("DOTENV_EXISTING")
    end

    it "loads environment-specific .env files" do
      File.write(File.join(tmpdir, ".env.test"), 'DOTENV_ENVSPEC="test_value"')
      old_env = ENV["ENVIRONMENT"]
      ENV["ENVIRONMENT"] = "test"
      ENV.delete("DOTENV_ENVSPEC")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_ENVSPEC"]).to eq("test_value")
      ENV["ENVIRONMENT"] = old_env
      ENV.delete("DOTENV_ENVSPEC")
    end

    it "creates a default .env file if none exists" do
      Tina4::Env.load_env(tmpdir)
      expect(File.exist?(File.join(tmpdir, ".env"))).to be true
    end

    it "handles empty values" do
      File.write(File.join(tmpdir, ".env"), 'DOTENV_EMPTY=""')
      ENV.delete("DOTENV_EMPTY")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_EMPTY"]).to eq("")
      ENV.delete("DOTENV_EMPTY")
    end
  end

  # ── load_env Negative Tests ──────────────────────────────────────

  describe ".load_env negative cases" do
    it "handles a missing directory gracefully by creating .env" do
      new_dir = File.join(tmpdir, "subdir")
      FileUtils.mkdir_p(new_dir)
      Tina4::Env.load_env(new_dir)
      expect(File.exist?(File.join(new_dir, ".env"))).to be true
    end

    it "handles empty .env file" do
      File.write(File.join(tmpdir, ".env"), "")
      expect { Tina4::Env.load_env(tmpdir) }.not_to raise_error
    end

    it "skips lines without equals sign" do
      File.write(File.join(tmpdir, ".env"), "no_equals_sign\nDOTENV_GOOD=ok\n")
      ENV.delete("DOTENV_GOOD")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["DOTENV_GOOD"]).to eq("ok")
      ENV.delete("DOTENV_GOOD")
    end
  end

  # ── get_env Tests ────────────────────────────────────────────────

  describe ".get_env" do
    it "returns existing env var value" do
      ENV["DOTENV_GET_TEST"] = "hello"
      expect(Tina4::Env.get_env("DOTENV_GET_TEST")).to eq("hello")
      ENV.delete("DOTENV_GET_TEST")
    end

    it "returns default for missing var" do
      expect(Tina4::Env.get_env("DOTENV_NONEXISTENT", "fallback")).to eq("fallback")
    end

    it "returns nil for missing var without default" do
      expect(Tina4::Env.get_env("DOTENV_NONEXISTENT")).to be_nil
    end
  end

  # ── has_env? Tests ───────────────────────────────────────────────

  describe ".has_env?" do
    it "returns true for existing var" do
      ENV["DOTENV_HAS_TEST"] = "yes"
      expect(Tina4::Env.has_env?("DOTENV_HAS_TEST")).to be true
      ENV.delete("DOTENV_HAS_TEST")
    end

    it "returns false for missing var" do
      expect(Tina4::Env.has_env?("DOTENV_DEFINITELY_NOT_SET")).to be false
    end

    it "returns true for empty value" do
      ENV["DOTENV_HAS_EMPTY"] = ""
      expect(Tina4::Env.has_env?("DOTENV_HAS_EMPTY")).to be true
      ENV.delete("DOTENV_HAS_EMPTY")
    end
  end

  # ── all_env Tests ────────────────────────────────────────────────

  describe ".all_env" do
    it "returns a hash" do
      expect(Tina4::Env.all_env).to be_a(Hash)
    end

    it "contains known env var" do
      ENV["DOTENV_ALL_TEST"] = "present"
      expect(Tina4::Env.all_env["DOTENV_ALL_TEST"]).to eq("present")
      ENV.delete("DOTENV_ALL_TEST")
    end
  end

  # ── require_env! Tests ──────────────────────────────────────────

  describe ".require_env!" do
    it "returns normally when all vars are present" do
      ENV["DOTENV_REQ_A"] = "1"
      ENV["DOTENV_REQ_B"] = "2"
      expect { Tina4::Env.require_env!("DOTENV_REQ_A", "DOTENV_REQ_B") }.not_to raise_error
      ENV.delete("DOTENV_REQ_A")
      ENV.delete("DOTENV_REQ_B")
    end

    it "raises when a var is missing" do
      expect { Tina4::Env.require_env!("DOTENV_DEFINITELY_NOT_SET_99999") }.to raise_error(KeyError)
    end
  end

  # ── truthy? Tests ────────────────────────────────────────────────

  describe ".is_truthy" do
    it "returns true for 'true'" do
      expect(Tina4::Env.is_truthy("true")).to be true
    end

    it "returns true for '1'" do
      expect(Tina4::Env.is_truthy("1")).to be true
    end

    it "returns true for 'yes'" do
      expect(Tina4::Env.is_truthy("yes")).to be true
    end

    it "returns true for 'on'" do
      expect(Tina4::Env.is_truthy("on")).to be true
    end

    it "returns false for 'false'" do
      expect(Tina4::Env.is_truthy("false")).to be false
    end

    it "returns false for '0'" do
      expect(Tina4::Env.is_truthy("0")).to be false
    end

    it "returns false for empty string" do
      expect(Tina4::Env.is_truthy("")).to be false
    end

    it "returns false for nil" do
      expect(Tina4::Env.is_truthy(nil)).to be false
    end
  end
end
