# frozen_string_literal: true

require "spec_helper"
require_relative "support/live_postgres"

# A percent-encoded password in a DATABASE_URL must reach the driver DECODED.
#
# Ruby was already correct here - it hands the whole URL to the driver, and
# libpq decodes userinfo itself. Python was the framework that did NOT decode
# (its adapters read urlparse().password, which returns the RAW userinfo), and
# this spec exists so Ruby cannot ACQUIRE the bug in a later refactor.
#
# The failure mode is why it matters: the driver reports a plain "login failed",
# nothing mentions the URL, the password looks right in the config, and the same
# credentials work when passed as separate arguments.
#
# NO MOCKS: pure parsing, plus a live PostgreSQL round trip when one is set.
#
# Identical case names in all four frameworks:
#   tina4-python/tests/test_database_url_credentials.py
#   tina4-php/tests/DatabaseUrlCredentialsTest.php
#   tina4-nodejs/test/databaseUrlCredentials.test.ts
RSpec.describe "DatabaseUrl credentials" do
  it "a percent encoded password is decoded" do
    expect(Tina4::DatabaseUrl.new("mssql://sa:TinaSQL123%21Secure@h:1433/db").password)
      .to eq("TinaSQL123!Secure")
  end

  # Exactly the characters that FORCE encoding in a URL - the only ones that can
  # expose the bug. A password without them works either way.
  it "every reserved character survives a round trip" do
    u = Tina4::DatabaseUrl.new("postgres://us%3Aer:p%40ss%21w%3Ard%2Fx%23y@h:5432/db")
    expect(u.username).to eq("us:er")
    expect(u.password).to eq("p@ss!w:rd/x#y")
  end

  it "an unencoded password is unchanged" do
    expect(Tina4::DatabaseUrl.new("postgres://tina4:tina4@h:5432/db").password).to eq("tina4")
  end

  # A real '%' encodes to '%25'. Decoding once yields '%'; twice would corrupt it.
  it "a literal percent in a password survives" do
    expect(Tina4::DatabaseUrl.new("postgres://u:100%25sure@h:5432/db").password).to eq("100%sure")
  end

  # The end-to-end proof: '%61' decodes to 'a', so the encoded form spells the
  # SAME password. It connects only if the credential path decodes.
  #
  # This used to gate on TINA4_TEST_PG_URL and skip with "live PostgreSQL not
  # configured" whenever that was unset - which is always, locally. The skip
  # reads green and is not caught by the TINA4_REQUIRE_SERVICES gate either
  # ("not configured" is not one of its unavailability hints), so the one
  # end-to-end proof in this file has been silently not running. It now selects
  # a reachable endpoint (see spec/support/live_postgres.rb) and REQUIRES it,
  # so the claim is either proven or the spec is red. The assertion itself is
  # unchanged.
  it "an encoded password connects to a live database" do
    expect(LivePostgres.reachable?).to be(true),
                                       "live PostgreSQL required at #{LivePostgres.host}:#{LivePostgres.port}"
    raw = LivePostgres.password
    expect(raw).to include("a"), "the test password must contain an 'a' to percent-encode"

    db = Tina4::Database.new(LivePostgres.url(pass: raw.sub("a", "%61")))
    expect([true, false]).to include(db.table_exists?("tina4_write_contract"))
    db.close
  end
end
