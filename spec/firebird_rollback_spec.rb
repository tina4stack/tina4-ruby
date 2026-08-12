# frozen_string_literal: true
#
# Regression / lock-in spec: Firebird explicit-transaction rollback() must UNDO
# a write (twin of the Node fix f8b138f and the PHP fix 3.13.86).
#
# The `fb` gem's Fb::Connection#transaction (no block) STARTS a transaction on
# the connection and returns `true` (a boolean — NOT a transaction object). The
# old FirebirdDriver stored that in @transaction and called @transaction&.commit
# / &.rollback, i.e. `true.commit` / `true.rollback` — a NoMethodError that broke
# every explicit-transaction commit AND rollback, so a rolled-back write was
# never undone (the atomicity contract was silently violated). At HEAD the driver
# starts the transaction on the connection and commits/rolls back the CONNECTION
# (matching the Python master's connection-level contract), tracking open-ness
# with an @in_transaction boolean.
#
# This exercises a REAL Firebird — NO mocks. It is env-gated on
# TINA4_TEST_FIREBIRD_URL and skips (green) when that is unset or the server is
# unreachable / the fb gem is missing. The skip reason always contains "firebird"
# and no other provisioned-service keyword, so the TINA4_REQUIRE_SERVICES gate
# leaves it green (Firebird is intentionally not in the provisioned set).
#
# NEGATIVE (the regression): rollback UNDOES the insert — this FAILS against the
#   pre-fix driver (rollback raised NoMethodError; the row survived).
# POSITIVE: read-after-write inside the txn sees the uncommitted row; commit
#   PERSISTS (verified from a FRESH connection); a standalone write autocommits
#   (verified from a FRESH connection).

require "spec_helper"
require "uri"
require "socket"

FB_ROLLBACK_URL  = ENV["TINA4_TEST_FIREBIRD_URL"].to_s
FB_ROLLBACK_USER = ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA")
FB_ROLLBACK_PASS = ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey")
FB_ROLLBACK_TABLE = "rb_fb_rollback_spec"

def fb_rollback_gem_available?
  require "fb"
  true
rescue LoadError
  false
end

def fb_rollback_reachable?(url)
  uri = URI.parse(url)
  TCPSocket.new(uri.host, uri.port || 3050).tap(&:close)
  true
rescue StandardError
  false
end

RSpec.describe "Firebird explicit-transaction rollback undoes writes (real FB)" do
  before(:all) do
    @skip_reason =
      if FB_ROLLBACK_URL.empty?
        "TINA4_TEST_FIREBIRD_URL not set — firebird rollback spec skipped"
      elsif !fb_rollback_gem_available?
        "fb gem not installed — firebird rollback spec skipped"
      elsif !fb_rollback_reachable?(FB_ROLLBACK_URL)
        "firebird not reachable at #{FB_ROLLBACK_URL} — spec skipped"
      end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(FB_ROLLBACK_URL, username: FB_ROLLBACK_USER, password: FB_ROLLBACK_PASS)
    # RECREATE drops+creates atomically; fall back to a clear if the table is new.
    begin
      @db.execute("RECREATE TABLE #{FB_ROLLBACK_TABLE} (id INTEGER NOT NULL PRIMARY KEY, v VARCHAR(20))")
    rescue StandardError
      @db.execute("DELETE FROM #{FB_ROLLBACK_TABLE}")
    end
    @db.commit rescue nil
  end

  after(:each) do
    next unless @db

    begin
      @db.execute("DROP TABLE #{FB_ROLLBACK_TABLE}")
      @db.commit rescue nil
    rescue StandardError
      # table already gone / connection closed — nothing to clean up
    ensure
      @db.close rescue nil
    end
  end

  def count(db, id)
    # Lowercase SYMBOL: an unquoted alias reads back folded, like every other
    # engine (see FirebirdDriver#column_name), and as a Symbol key like every
    # other Ruby driver (see FirebirdDriver#symbolize_keys).
    db.fetch_one("SELECT COUNT(*) AS C FROM #{FB_ROLLBACK_TABLE} WHERE id = ?", [id])[:c].to_i
  end

  it "rolls back an insert made inside an explicit transaction (NEGATIVE — fails on old code)" do
    @db.start_transaction
    @db.execute("INSERT INTO #{FB_ROLLBACK_TABLE} (id, v) VALUES (?, ?)", [1, "rolled"])
    # read-after-write inside the same transaction sees the uncommitted row
    expect(count(@db, 1)).to eq(1)
    @db.rollback
    # after rollback the row is GONE — the pre-fix driver never got here (rollback
    # raised NoMethodError) and, even swallowed, left the row behind.
    expect(count(@db, 1)).to eq(0)
  end

  it "persists an insert made inside an explicit transaction on commit (verified from a fresh connection)" do
    @db.start_transaction
    @db.execute("INSERT INTO #{FB_ROLLBACK_TABLE} (id, v) VALUES (?, ?)", [2, "kept"])
    @db.commit

    verifier = Tina4::Database.new(FB_ROLLBACK_URL, username: FB_ROLLBACK_USER, password: FB_ROLLBACK_PASS)
    begin
      expect(count(verifier, 2)).to eq(1)
    ensure
      verifier.close rescue nil
    end
  end

  it "auto-commits a standalone write made outside any explicit transaction (verified from a fresh connection)" do
    @db.execute("INSERT INTO #{FB_ROLLBACK_TABLE} (id, v) VALUES (?, ?)", [3, "auto"])

    verifier = Tina4::Database.new(FB_ROLLBACK_URL, username: FB_ROLLBACK_USER, password: FB_ROLLBACK_PASS)
    begin
      expect(count(verifier, 3)).to eq(1)
    ensure
      verifier.close rescue nil
    end
  end
end
