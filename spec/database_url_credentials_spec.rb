# frozen_string_literal: true

require "spec_helper"

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
  it "an encoded password connects to a live database" do
    url = ENV["TINA4_TEST_PG_URL"].to_s.strip
    skip "live PostgreSQL not configured (TINA4_TEST_PG_URL)" if url.empty?
    raw = (ENV["TINA4_TEST_PG_PASSWORD"] || "tina4").strip
    skip "password has no 'a' to encode" unless raw.include?("a")

    user = (ENV["TINA4_TEST_PG_USERNAME"] || "tina4").strip
    scheme, rest = url.split("://", 2)
    tail = rest.split("@").last
    encoded = raw.sub("a", "%61")

    db = Tina4::Database.new("#{scheme}://#{user}:#{encoded}@#{tail}")
    expect([true, false]).to include(db.table_exists?("tina4_write_contract"))
  end
end
