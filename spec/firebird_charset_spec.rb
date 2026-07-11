# frozen_string_literal: true

# #160 — the Firebird adapter must honour a charset override.
#
# The driver used to pass NO charset to the `fb` gem, leaving it on the gem's
# own (non-UTF8) default, which double-encodes UTF-8 bytes stored under a legacy
# NONE database and diverges from the other frameworks. The charset is now
# resolved from, in precedence order:
#
#     1. the connection URL query   firebird://host:port/path?charset=NONE
#     2. an explicit charset: kwarg passed to #connect
#     3. the TINA4_DATABASE_CHARSET environment variable
#     4. the UTF8 default (canonical across all four frameworks)
#
# These exercise the PURE config resolver `resolve_charset` directly. It opens
# NO connection (it only parses a URL, a kwarg, and an env var), so this is
# pure-logic — not a mocked DB. The live double-encode fix itself is verified in
# the PHP mirror where php #160 was reported (real Firebird is not available on
# this runner). Mirrors tests/test_firebird_charset.py.

require "spec_helper"
require "tina4/drivers/firebird_driver"

RSpec.describe Tina4::Drivers::FirebirdDriver do
  describe ".resolve_charset" do
    # Set/restore TINA4_DATABASE_CHARSET around a block without leaking into
    # other examples — the resolver reads the REAL process env.
    def with_env(value)
      key = "TINA4_DATABASE_CHARSET"
      old = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
      yield
    ensure
      old.nil? ? ENV.delete(key) : ENV[key] = old
    end

    it "defaults to UTF8" do
      with_env(nil) do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee"))
          .to eq("UTF8")
      end
    end

    it "lets the URL query charset win" do
      with_env(nil) do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee?charset=NONE"))
          .to eq("NONE")
      end
    end

    it "lets the URL query charset override the env var" do
      with_env("WIN1252") do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee?charset=NONE"))
          .to eq("NONE"), "URL query param must win over the env var"
      end
    end

    it "uses the env var when no URL param is present" do
      with_env("ISO8859_1") do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee"))
          .to eq("ISO8859_1")
      end
    end

    it "uses an explicit kwarg when no URL param is present (beats env/default)" do
      with_env(nil) do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee", "WIN1251"))
          .to eq("WIN1251")
      end
    end

    it "lets the URL param beat an explicit kwarg" do
      with_env(nil) do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee?charset=NONE", "UTF8"))
          .to eq("NONE")
      end
    end

    it "treats a blank ?charset= as absent and falls through to the default" do
      with_env(nil) do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee?charset="))
          .to eq("UTF8")
      end
    end

    it "treats a blank env var as absent and falls through to the default" do
      with_env("") do
        expect(described_class.resolve_charset("firebird://localhost:3050/employee"))
          .to eq("UTF8")
      end
    end

    it "does not let ?charset= pollute the resolved DB identifier" do
      # A ?charset= query must not leak into the normalised DB path — the
      # double-slash absolute path form still resolves cleanly alongside it
      # (URI.parse keeps the query separate from the path component).
      require "uri"
      parsed = URI.parse("firebird://localhost:3050//data/app.fdb?charset=NONE")
      expect(described_class.normalize_db_identifier(parsed.path)).to eq("/data/app.fdb")
      expect(described_class.resolve_charset("firebird://localhost:3050//data/app.fdb?charset=NONE"))
        .to eq("NONE")
    end
  end
end
