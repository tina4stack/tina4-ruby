# frozen_string_literal: true

# Firebird URL parsing + TINA4_DATABASE_FIREBIRD_PATH override tests.
#
# The Firebird URL is the awkward one in the stack — every other engine
# (PostgreSQL, MySQL, MSSQL) has a server-side database name where you can
# write `pg://host:port/dbname` and the path component is just a name.
# Firebird wants either an absolute file path on the server, a Windows
# drive-letter path, or an alias. The classic URI form needs a double
# slash to keep the absolute path through URI.parse, which is unintuitive.
#
# This suite verifies the framework accepts five equivalent forms and
# also honours TINA4_DATABASE_FIREBIRD_PATH as an explicit override
# (useful for Windows backslash paths and ops setups that keep config
# split across layers).

require "spec_helper"
require "socket"
require "tina4/drivers/firebird_driver"

RSpec.describe Tina4::Drivers::FirebirdDriver do
  describe ".normalize_db_identifier" do
    it "handles classic double-slash absolute path" do
      # firebird://host:port//abs/path/db.fdb → URI.parse path = //abs/path/db.fdb
      expect(described_class.normalize_db_identifier("//firebird/data/app.fdb"))
        .to eq("/firebird/data/app.fdb")
    end

    it "handles single-slash absolute path" do
      # firebird://host:port/abs/path/db.fdb → URI.parse path = /abs/path/db.fdb
      expect(described_class.normalize_db_identifier("/firebird/data/app.fdb"))
        .to eq("/firebird/data/app.fdb")
    end

    it "handles Windows drive letter with leading slash" do
      # firebird://host:port/C:/Data/db.fdb → URI.parse path = /C:/Data/db.fdb
      expect(described_class.normalize_db_identifier("/C:/Data/app.fdb"))
        .to eq("C:/Data/app.fdb")
    end

    it "handles Windows drive letter that's URL-encoded" do
      # firebird://host:port/C%3A/Data/db.fdb → URI.parse path = /C%3A/Data/db.fdb
      expect(described_class.normalize_db_identifier("/C%3A/Data/app.fdb"))
        .to eq("C:/Data/app.fdb")
    end

    it "treats single-token path as alias" do
      # firebird://host:port/employee → URI.parse path = /employee
      expect(described_class.normalize_db_identifier("/employee")).to eq("employee")
    end

    it "promotes a relative-looking path to absolute" do
      # If user writes a path-like value without a leading slash, treat it
      # as an absolute path (Firebird doesn't have a notion of relative
      # paths anyway). Prepend a slash so the driver sees an absolute path
      # and errors clearly if it doesn't exist.
      expect(described_class.normalize_db_identifier("data/app.fdb"))
        .to eq("/data/app.fdb")
    end

    it "decodes URL-encoded unicode characters in the path" do
      # Path with URL-encoded non-ASCII char — decoded correctly.
      expect(described_class.normalize_db_identifier("/data/d%C3%A9j%C3%A0.fdb"))
        .to eq("/data/déjà.fdb")
    end

    it "handles a lowercase drive letter the same as uppercase" do
      expect(described_class.normalize_db_identifier("/c:/data/app.fdb"))
        .to eq("c:/data/app.fdb")
    end
  end

  # ── End-to-end against a live Firebird container ─────────────────────────

  FIREBIRD_HOST = "localhost"
  FIREBIRD_PORT = 53050
  LIVE_DB_PATH = "/firebird/data/tina4.fdb"

  def self.firebird_reachable?
    return @_firebird_reachable unless @_firebird_reachable.nil?
    @_firebird_reachable = begin
      Socket.tcp(FIREBIRD_HOST, FIREBIRD_PORT, connect_timeout: 1).close
      # The fb gem must also be loadable — without it we can't connect.
      require "fb"
      true
    rescue LoadError, StandardError
      false
    end
  end

  describe "live connectivity", if: firebird_reachable? do
    # Each form should connect to the same database when the framework
    # is given a live Firebird container.

    def connect_with_env(url, env_overrides = {})
      old = {}
      env_overrides.each { |k, _| old[k] = ENV[k] }
      env_overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      Tina4::Database.new(url)
    ensure
      old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v } if old
    end

    it "connects via the single-slash URL form" do
      url = "firebird://SYSDBA:masterkey@#{FIREBIRD_HOST}:#{FIREBIRD_PORT}#{LIVE_DB_PATH}"
      db = connect_with_env(url)
      row = db.fetch_one("SELECT 1 AS x FROM rdb$database")
      expect(row["x"] || row[:x]).to eq(1)
      db.close
    end

    it "connects via the double-slash URL form" do
      url = "firebird://SYSDBA:masterkey@#{FIREBIRD_HOST}:#{FIREBIRD_PORT}/#{LIVE_DB_PATH}"
      db = connect_with_env(url)
      row = db.fetch_one("SELECT 1 AS x FROM rdb$database")
      expect(row["x"] || row[:x]).to eq(1)
      db.close
    end

    it "honours TINA4_DATABASE_FIREBIRD_PATH override over a wrong URL path" do
      # Provide a deliberately wrong URL path; the env override points at
      # the real DB. The framework should connect to the real one.
      wrong_url = "firebird://SYSDBA:masterkey@#{FIREBIRD_HOST}:#{FIREBIRD_PORT}/this/path/does/not/exist.fdb"
      db = connect_with_env(wrong_url, "TINA4_DATABASE_FIREBIRD_PATH" => LIVE_DB_PATH)
      row = db.fetch_one("SELECT 1 AS x FROM rdb$database")
      expect(row["x"] || row[:x]).to eq(1)
      db.close
    end
  end
end
