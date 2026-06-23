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

  it "drives all 22 retired env vars through the guard, surfacing each TINA4_ replacement at runtime" do
    # The documented mapping. We do NOT assert the constant against this copy —
    # we feed each OLD name into the guard one at a time and prove the guard
    # consults the live LEGACY_ENV_VARS table to name the correct replacement.
    # This catches the failure the constant-comparison version could not: a
    # mapping that is declared but never actually used by the boot guard.
    expected = {
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
    }

    expected.each do |old, new_name|
      ENV[old] = "anything"
      io = StringIO.new
      err = nil
      begin
        Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
      rescue Tina4::LegacyEnvError => e
        err = e
      ensure
        ENV.delete(old)
      end

      # The guard must have refused to boot and named the offending legacy var.
      expect(err).to be_a(Tina4::LegacyEnvError),
                     "expected setting #{old} to trip the boot guard"
      expect(err.message).to include(old)
      # ...and the rendered guidance must point at the exact replacement,
      # proving the runtime mapping resolved old -> new through the guard.
      expect(io.string).to include(old)
      expect(io.string).to include(new_name),
                           "expected guard to tell user to use #{new_name} in place of #{old}"
    end

    # Every documented pair was exercised, and the live table holds exactly the
    # 22 mappings we drove through the guard (no extras, none missing).
    expect(expected.size).to eq(22)
    expect(Tina4::LEGACY_ENV_VARS.size).to eq(expected.size)
    expect(Tina4::LEGACY_ENV_VARS).to eq(expected)
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

  # ── 5b. Error message hints at the .env / build-context source + louder FIX (DX fix B)

  it "hints legacy names may come from a baked .env and lifts env --migrate to a FIX step" do
    Tina4::LEGACY_ENV_VARS.each_key { |k| ENV[k] = "value" }
    io = StringIO.new
    expect {
      Tina4.check_legacy_env_vars!(io: io, exit_on_error: false)
    }.to raise_error(Tina4::LegacyEnvError)
    output = io.string
    # source hint: a .env loaded by dotenv / baked into the image, not just runtime env
    expect(output).to include("dotenv")
    expect(output).to include("build context")
    expect(output).to include("baked into a Docker image")
    # louder, explicit FIX step pointing at env --migrate
    expect(output).to include("FIX:")
    expect(output).to include("tina4 env --migrate")
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
