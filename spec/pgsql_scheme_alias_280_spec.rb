# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Parity lock for tina4-php#280: the pgsql:// scheme (and every documented
# alias) resolves, and resolves to the same engine as its canonical spelling.
#
# Ruby already accepts pgsql (DRIVERS map); this LOCKS it so it cannot silently
# regress the way PHP's did (DatabaseUrl mapped pgsql but Database::create
# refused it). DatabaseUrl#engine is the exact resolver Database#detect_driver
# uses for a URL, so asserting it locks the real path. No mocks.

require "spec_helper"

RSpec.describe "pgsql:// scheme alias (#280 parity)" do
  ALIASES = {
    "sqlite" => "sqlite", "sqlite3" => "sqlite",
    "postgres" => "postgres", "postgresql" => "postgres", "pgsql" => "postgres",
    "mysql" => "mysql", "mssql" => "mssql", "sqlserver" => "mssql",
    "firebird" => "firebird"
  }.freeze

  ALIASES.each do |scheme, engine|
    it "resolves #{scheme}:// to the #{engine} engine" do
      url = %w[sqlite sqlite3].include?(scheme) ? "#{scheme}:///tmp/x.db" : "#{scheme}://user:pass@localhost:5432/db"
      expect(Tina4::DatabaseUrl.new(url).engine).to eq(engine)
    end
  end

  it "resolves pgsql:// through Database#driver_name too (the #280 point)" do
    expect(Tina4::Database.new("pgsql://localhost:5432/db").driver_name).to eq("postgres")
  end

  it "refuses a genuinely unknown scheme rather than falling through to sqlite" do
    expect { Tina4::DatabaseUrl.new("bogus://host/db") }.to raise_error(StandardError)
  end
end
