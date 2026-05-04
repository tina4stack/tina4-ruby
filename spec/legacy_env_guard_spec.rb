# frozen_string_literal: true

# Regression coverage for the v3.12 legacy env-var boot guard.
#
# Tina4 v3.12 hard-renamed every framework env var to use the TINA4_
# prefix. The boot path must refuse to start if any pre-3.12 un-prefixed
# names are still set in the environment, and must list each legacy var
# alongside its replacement in the error so users know exactly what to
# rename. TINA4_ALLOW_LEGACY_ENV=true must bypass the guard for migration
# scripts that need both names set during a transition window.
#
# Run: bundle exec rspec spec/legacy_env_guard_spec.rb

require "spec_helper"
require "stringio"

RSpec.describe "Tina4 v3.12 legacy env-var boot guard" do
  # Each test runs in its own clean ENV slice — capture and restore.
  ALL_LEGACY = Tina4::LEGACY_ENV_VARS.keys + ["TINA4_ALLOW_LEGACY_ENV"]

  before(:each) do
    @saved_env = ALL_LEGACY.each_with_object({}) { |k, h| h[k] = ENV[k] }
    ALL_LEGACY.each { |k| ENV.delete(k) }
  end

  after(:each) do
    ALL_LEGACY.each do |k|
      if @saved_env[k].nil?
        ENV.delete(k)
      else
        ENV[k] = @saved_env[k]
      end
    end
  end

  # ── 1. Maps every documented legacy var to a TINA4_ replacement ──

  it "maps all 22 retired env vars to their TINA4_-prefixed replacements" do
    expect(Tina4::LEGACY_ENV_VARS).to include(
      "DATABASE_URL"           => "TINA4_DATABASE_URL",
      "DATABASE_USERNAME"      => "TINA4_DATABASE_USERNAME",
      "DATABASE_PASSWORD"      => "TINA4_DATABASE_PASSWORD",
      "DB_URL"                 => "TINA4_DATABASE_URL",
      "SECRET"                 => "TINA4_SECRET",
      "API_KEY"                => "TINA4_API_KEY",
      "JWT_ALGORITHM"          => "TINA4_JWT_ALGORITHM",
      "SMTP_HOST"              => "TINA4_MAIL_HOST",
      "SMTP_PORT"              => "TINA4_MAIL_PORT",
      "SMTP_USERNAME"          => "TINA4_MAIL_USERNAME",
      "SMTP_PASSWORD"          => "TINA4_MAIL_PASSWORD",
      "SMTP_FROM"              => "TINA4_MAIL_FROM",
      "SMTP_FROM_NAME"         => "TINA4_MAIL_FROM_NAME",
      "IMAP_HOST"              => "TINA4_MAIL_IMAP_HOST",
      "IMAP_PORT"              => "TINA4_MAIL_IMAP_PORT",
      "IMAP_USER"              => "TINA4_MAIL_IMAP_USERNAME",
      "IMAP_PASS"              => "TINA4_MAIL_IMAP_PASSWORD",
      "HOST_NAME"              => "TINA4_HOST_NAME",
      "SWAGGER_TITLE"          => "TINA4_SWAGGER_TITLE",
      "SWAGGER_DESCRIPTION"    => "TINA4_SWAGGER_DESCRIPTION",
      "SWAGGER_VERSION"        => "TINA4_SWAGGER_VERSION",
      "ORM_PLURAL_TABLE_NAMES" => "TINA4_ORM_PLURAL_TABLE_NAMES"
    )
    expect(Tina4::LEGACY_ENV_VARS.size).to eq(22)
  end

  # ── 2. Clean env passes silently ─────────────────────────────────

  it "is a no-op when no legacy env vars are set" do
    io = StringIO.new
    expect {
      Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
    }.not_to raise_error
    expect(io.string).to eq("")
  end

  # ── 3. Each legacy name individually triggers the guard ──────────

  Tina4::LEGACY_ENV_VARS.each do |old, new_name|
    it "trips the boot guard when #{old} is set (and tells the user to use #{new_name})" do
      ENV[old] = "anything"
      io = StringIO.new
      expect {
        Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
      }.to raise_error(Tina4::LegacyEnvError, /#{Regexp.escape(old)}/)
      expect(io.string).to include(old)
      expect(io.string).to include(new_name)
    end
  end

  # ── 4. Bypass behaviour ─────────────────────────────────────────

  it "bypasses the guard when TINA4_ALLOW_LEGACY_ENV=true" do
    ENV["DATABASE_URL"] = "sqlite::memory:"
    ENV["TINA4_ALLOW_LEGACY_ENV"] = "true"
    io = StringIO.new
    expect {
      Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
    }.not_to raise_error
    expect(io.string).to eq("")
  end

  it "accepts other truthy bypass values (1, yes)" do
    ENV["SECRET"] = "x"
    %w[1 yes TRUE Yes True].each do |truthy|
      ENV["TINA4_ALLOW_LEGACY_ENV"] = truthy
      io = StringIO.new
      expect {
        Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
      }.not_to raise_error, "expected #{truthy.inspect} to bypass guard"
    end
  end

  it "does NOT bypass when TINA4_ALLOW_LEGACY_ENV is set to a falsy value" do
    ENV["DATABASE_URL"] = "sqlite::memory:"
    ENV["TINA4_ALLOW_LEGACY_ENV"] = "false"
    io = StringIO.new
    expect {
      Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
    }.to raise_error(Tina4::LegacyEnvError)
  end

  # ── 5. Error message lists every legacy var ─────────────────────

  it "lists every legacy var with its replacement in the error message" do
    Tina4::LEGACY_ENV_VARS.each_key { |k| ENV[k] = "value" }
    io = StringIO.new
    expect {
      Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
    }.to raise_error(Tina4::LegacyEnvError)
    output = io.string
    Tina4::LEGACY_ENV_VARS.each do |old, new_name|
      expect(output).to include(old), "expected error to list legacy var #{old}"
      expect(output).to include(new_name), "expected error to list replacement #{new_name}"
    end
    expect(output).to include("Tina4 v3.12")
    expect(output).to include("TINA4_ALLOW_LEGACY_ENV=true")
  end

  # ── 6. Whitelisted un-prefixed names DO NOT trip the guard ──────

  it "does not trip on un-prefixed runtime names that stay as-is (PORT, HOST, RACK_ENV, RUBY_ENV, NODE_ENV, ENVIRONMENT)" do
    saved = {}
    %w[PORT HOST NODE_ENV RACK_ENV RUBY_ENV ENVIRONMENT].each do |k|
      saved[k] = ENV[k]
      ENV[k] = "test-value"
    end
    begin
      io = StringIO.new
      expect {
        Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
      }.not_to raise_error
      expect(io.string).to eq("")
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
