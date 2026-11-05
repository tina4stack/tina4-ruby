# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# SECURITY (GHSA-cxqw-5cwf-wv3r): a TINA4_DATABASE_URL that lost the ":" of its
# scheme (`postgres//u:pass@host/app`, a one-character typo) must not write the
# password to a log. DatabaseUrl.scrub only redacted text containing "://", and
# the pg driver's own "could not translate host name" error quotes the whole
# scheme-less string, password included, into the log.
#
# Driven for real: the two scrub cases are the pure redaction primitive, and the
# third boots a REAL Tina4::Database against the REAL pg driver with an
# unresolvable host (no server needed - the failure IS the test) and greps the
# REAL log bytes the error sink wrote.

require_relative "spec_helper"
require_relative "support/real_log_capture"

RSpec.describe "Scheme-less DATABASE_URL redaction (GHSA-cxqw-5cwf-wv3r)" do
  PASSWORD = "Pq1Rs2SchemelessSecretXyz"

  it "scrubs the password from a scheme-less postgres URL" do
    out = Tina4::DatabaseUrl.scrub("postgres//u:#{PASSWORD}@127.0.0.1/app")
    expect(out).not_to include(PASSWORD)
    expect(out).to include("***")
  end

  it "scrubs the password from a scheme-less odbc URL" do
    out = Tina4::DatabaseUrl.scrub("odbc//u:#{PASSWORD}@x/db")
    expect(out).not_to include(PASSWORD)
    expect(out).to include("***")
  end

  it "keeps the password out of the real log when a scheme-less connect fails" do
    skip "pg driver not available" unless defined?(PG) || begin
      require "pg"
      true
    rescue LoadError
      false
    end

    url = "postgres//u:#{PASSWORD}@tina4-nonexistent.invalid/app"
    log = capture_real_log(error_log: true) do
      db = Tina4::Database.new(url, driver_name: "postgres")
      begin
        db.connect
      rescue StandardError
        # A failed connect is the point; the log line is already written.
      end
    end

    expect(log).to include("Database connection failed")
    expect(log).not_to include(PASSWORD),
      "the scheme-less connection string's password reached the log"
  end
end
