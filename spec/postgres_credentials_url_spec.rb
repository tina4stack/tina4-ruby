# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"

# The PostgreSQL driver puts the credentials into the URL it hands libpq. It
# used URI#password=, which REFUSES a "/", "@", "%" or space
# (URI::InvalidComponentError), so a Ruby app could not connect to PostgreSQL
# with such a password at all - even when the URL spelled it percent-encoded,
# because Tina4 decodes it and passed the decoded value back in. The value is
# now percent-encoded, and libpq's OWN parser (PG::Connection.conninfo_parse)
# must read back exactly the original. Needs the pg gem; no server.
RSpec.describe "PostgreSQL credentials in the libpq URL" do
  before(:all) do
    begin
      require "pg"
    rescue LoadError
      skip "[needs:gem=pg] the pg gem is not installed"
    end
  end

  def libpq_reads(url)
    PG::Connection.conninfo_parse(url).to_h { |o| [o[:keyword], o[:val]] }
  end

  ["Pq1Rs2", "a/b", "a@b", "a b", "a:b", "a%41", "p?q#r", "ü-ß"].each do |password|
    it "libpq reads the password #{password.inspect} back unchanged" do
      url = Tina4::Drivers::PostgresDriver.connection_url(
        "postgres://dbhost:5432/appdb", "app@user", password
      )
      parsed = libpq_reads(url)
      # conninfo_parse returns binary strings; the BYTES are what libpq sends.
      expect(parsed["password"].b).to eq(password.b)
      expect(parsed["user"]).to eq("app@user")
      expect(parsed["host"]).to eq("dbhost")
      expect(parsed["dbname"]).to eq("appdb")
    end
  end

  it "leaves a URL alone when no credentials are passed in" do
    url = "postgres://u:x@dbhost:5432/appdb"
    expect(Tina4::Drivers::PostgresDriver.connection_url(url, nil, nil)).to eq(url)
  end
end
