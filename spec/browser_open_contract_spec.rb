# frozen_string_literal: true

# ADR-0070 contract runner: spec/fixtures/browser_open_contract.json (a copy of
# tina4-documentation/plan/v3/fixtures/browser_open_contract.json).
#
# Every decision_table row is fed to the REAL gate, Tina4.browser_launch_allowed?,
# with the environment set for real: the row's process variables go into ENV,
# its .env values into a real .env file loaded by the real Tina4::Env.load_env
# (process environment wins, as the ADR requires), its mode into TINA4_DEBUG and
# its flags into argv. The gate's own lists must equal the fixture's element
# for element. NO MOCKS.

require "spec_helper"
require "json"
require "tmpdir"

RSpec.describe "Browser-open contract (ADR-0070)" do
  fixture = JSON.parse(File.read(File.expand_path("fixtures/browser_open_contract.json", __dir__)))
  managed = (fixture["ci_env_vars"] + %w[TINA4_DEBUG TINA4_NO_BROWSER]).uniq

  around do |example|
    saved = ENV.to_h
    managed.each { |key| ENV.delete(key) }
    example.run
  ensure
    ENV.replace(saved)
  end

  it "ci env vars match the contract fixture" do
    expect(Tina4::CI_ENV_VARS).to eq(fixture["ci_env_vars"])
  end

  it "the truthy set and the ci not set values match the contract fixture" do
    expect(Tina4::Env::TRUTHY).to eq(fixture["truthy"])
    expect(Tina4::CI_FALSE_VALUES).to eq(fixture["ci_not_set_values"])
  end

  it "every ci variable vetoes on its own" do
    ENV["TINA4_DEBUG"] = "true"
    fixture["ci_env_vars"].each do |name|
      ENV[name] = "true"
      expect(Tina4.browser_launch_allowed?(argv: [])).to be(false), "#{name}=true did not veto"
      ENV.delete(name)
    end
    expect(Tina4.browser_launch_allowed?(argv: [])).to be(true)
  end

  it "a programmatic no_browser vetoes, and no_browser false never forces a browser open" do
    ENV["TINA4_DEBUG"] = "true"
    expect(Tina4.browser_launch_allowed?(argv: [], no_browser: true)).to be(false)
    ENV["TINA4_DEBUG"] = "false"
    expect(Tina4.browser_launch_allowed?(argv: [], no_browser: false)).to be(false)
  end

  fixture["decision_table"].each do |row|
    it "decision #{row['name']}" do
      ENV["TINA4_DEBUG"] = row["mode"] == "development" ? "true" : "false"
      row["env"].each { |key, value| ENV[key] = value }
      if row["dotenv"]
        Dir.mktmpdir("tina4-browser-open") do |dir|
          File.write(File.join(dir, ".env"), row["dotenv"].map { |key, value| "#{key}=#{value}\n" }.join)
          Tina4::Env.load_env(dir)
        end
      end

      expect(Tina4.browser_launch_allowed?(argv: row["flags"])).to be(row["opens"]),
        "#{row['name']}: mode=#{row['mode']} env=#{row['env']} dotenv=#{row['dotenv']} " \
        "flags=#{row['flags']} expected opens=#{row['opens']}"
    end
  end
end
