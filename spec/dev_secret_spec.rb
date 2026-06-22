# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Fail-safe dev secret bootstrap — Tina4::Auth.ensure_dev_secret(root_dir).
#
# Mirrors Python's tests/test_dev_secret.py and the contract in
# tina4_python/auth/__init__.py.
#
# In DEV (TINA4_DEBUG truthy, CI unset, not production) with a blank
# TINA4_SECRET, the bootstrap mints a cryptographically-random secret, writes
# it to a gitignored .env.local, and sets it in the process env for this run.
#
# In CI (CI=true) or production it NEVER generates and NEVER writes — it emits
# the actionable warning path instead. No DB is needed for any of this.
#
# ENV is snapshotted and restored around every example, and the four relevant
# vars are cleared first so a test only sets what it needs.
RSpec.describe "Tina4::Auth.ensure_dev_secret" do
  RELEVANT = %w[TINA4_SECRET CI TINA4_ENV TINA4_DEBUG].freeze

  around(:each) do |example|
    saved = RELEVANT.each_with_object({}) { |k, h| h[k] = ENV[k] }
    RELEVANT.each { |k| ENV.delete(k) }
    begin
      example.run
    ensure
      RELEVANT.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
    end
  end

  describe "dev generates" do
    it "writes .env.local and sets the process env" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true" # dev; CI unset, TINA4_ENV unset, secret blank

        secret = Tina4::Auth.ensure_dev_secret(dir)

        expect(secret).not_to be_nil
        expect(secret.length).to eq(64)        # 32 bytes hex
        expect(secret).to match(/\A[0-9a-f]{64}\z/)
        # Set in the process env for this run.
        expect(ENV["TINA4_SECRET"]).to eq(secret)
        # Persisted to .env.local (and ONLY .env.local).
        env_local = File.join(dir, ".env.local")
        expect(File.file?(env_local)).to be true
        expect(File.read(env_local)).to include("TINA4_SECRET=#{secret}")
        expect(File.exist?(File.join(dir, ".env"))).to be false # never writes .env
      end
    end

    it "appends to an existing .env.local without corrupting the last line" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true"
        env_local = File.join(dir, ".env.local")
        File.write(env_local, "EXISTING=1") # no trailing newline

        secret = Tina4::Auth.ensure_dev_secret(dir)

        content = File.read(env_local)
        expect(content).to include("EXISTING=1")               # preserved
        expect(content).to include("TINA4_SECRET=#{secret}")   # appended
        # Existing content without trailing newline is not corrupted onto the
        # same line as the new key.
        expect(content).to include("EXISTING=1\nTINA4_SECRET=")
      end
    end

    it "leaves an existing secret untouched and writes nothing" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true"
        ENV["TINA4_SECRET"] = "already-set"

        result = Tina4::Auth.ensure_dev_secret(dir)

        expect(result).to be_nil                       # nothing minted
        expect(ENV["TINA4_SECRET"]).to eq("already-set")
        expect(File.exist?(File.join(dir, ".env.local"))).to be false
      end
    end
  end

  describe "CI and production never generate" do
    it "does not generate or write in CI" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true" # even in dev-debug...
        ENV["CI"] = "true"          # ...CI must NOT generate

        result = Tina4::Auth.ensure_dev_secret(dir)

        expect(result).to be_nil                          # no secret minted
        expect(ENV.key?("TINA4_SECRET")).to be false      # process env untouched
        expect(File.exist?(File.join(dir, ".env.local"))).to be false
      end
    end

    it "does not generate or write in production" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true"
        ENV["TINA4_ENV"] = "production"

        result = Tina4::Auth.ensure_dev_secret(dir)

        expect(result).to be_nil
        expect(ENV.key?("TINA4_SECRET")).to be false
        expect(File.exist?(File.join(dir, ".env.local"))).to be false
      end
    end

    it "does not generate when not in dev (TINA4_DEBUG falsy)" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "false" # not dev → no generation even outside CI/prod

        result = Tina4::Auth.ensure_dev_secret(dir)

        expect(result).to be_nil
        expect(ENV.key?("TINA4_SECRET")).to be false
        expect(File.exist?(File.join(dir, ".env.local"))).to be false
      end
    end
  end

  describe "blank-secret warning is self-explanatory (DX fix A)" do
    it "names BOTH the prod fix and the LOCAL DEV auto-generate path" do
      w = Tina4::Auth::BLANK_SECRET_WARNING
      # existing actionable guidance kept
      expect(w).to include("TINA4_SECRET is not set")
      expect(w).to include("openssl rand -hex 32")
      # appended: how to auto-generate in local dev
      expect(w).to include("TINA4_DEBUG=true")
      expect(w).to include(".env.local")
      # appended: why you are seeing the warning (not detected as dev)
      expect(w).to include("NOT detected as dev")
      expect(w).to include("TINA4_ENV=production")
    end
  end

  describe "never crashes on write failure" do
    it "keeps the in-memory secret when .env.local cannot be written" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true"
        # Point root_dir at a regular file (not a directory) so opening
        # <path>/.env.local raises — the bootstrap must NOT crash.
        not_a_dir = File.join(dir, "blocker")
        File.write(not_a_dir, "x")

        secret = nil
        expect { secret = Tina4::Auth.ensure_dev_secret(not_a_dir) }.not_to raise_error

        # In-memory secret kept for this run despite the write failure.
        expect(secret).not_to be_nil
        expect(ENV["TINA4_SECRET"]).to eq(secret)
      end
    end
  end
end
