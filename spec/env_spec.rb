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
end
