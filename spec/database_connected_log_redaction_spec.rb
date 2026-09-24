# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# SECURITY: the boot-time "Database connected: <url>" log line never carries the
# password.
#
# Tina4.setup_database logged TINA4_DATABASE_URL through its own hand-rolled
# regex, db_url.sub(/:[^:@]+@/, ":***@"), instead of Tina4::DatabaseUrl.redact
# (the one redaction primitive). MEASURED on that expression:
#   postgresql://u:s3:cret@h/db          -> postgresql://u:s3:***@h/db   (prefix leaks)
#   odbc:///...;Uid=u;Pwd=<secret>;      -> printed verbatim               (whole secret)
# and a raw "@" in the password (postgresql://u:s3@cret@h/db) left the tail.
#
# Driven for real: a subprocess boots Tina4.setup_database against the REAL lab
# PostgreSQL (a throwaway role whose password contains ":" / "@") and the REAL
# ODBC source, runs a query through the bound database to prove it really
# connected, and everything the process wrote (the real Tina4::Log console sink,
# stderr) is searched for the password.

require_relative "spec_helper"
require "open3"
require "json"
require "uri"
require "securerandom"
require "rbconfig"
require "tmpdir"

RSpec.describe "Database connected log line redaction (real PostgreSQL + ODBC)" do
  let(:repository_root) { File.expand_path("..", __dir__) }
  let(:admin_url) { ENV["TINA4_TEST_PG_URL"].to_s }
  let(:odbc_dsn) { ENV["TINA4_TEST_ODBC_DSN"].to_s }

  def boot_setup_database(database_url)
    source = <<~RUBY
      require "json"
      require "tina4"
      Tina4.send(:setup_database)
      row = begin
        Tina4.database&.fetch_one("SELECT 1 AS probe")
      rescue StandardError => e
        { "error" => e.class.name }
      end
      puts "TINA4_REPORT \#{JSON.generate("bound" => !Tina4.database.nil?, "row" => row)}"
    RUBY
    environment = { "TINA4_DATABASE_URL" => database_url, "TINA4_DEBUG" => "false",
                    "TINA4_LOG_LEVEL" => "ALL", "TINA4_NO_BROWSER" => "true" }
    stdout, stderr, status = Dir.mktmpdir("tina4-db-log") do |dir|
      Open3.capture3(environment, RbConfig.ruby, "-I#{File.join(repository_root, "lib")}", "-e", source, chdir: dir)
    end
    line = stdout.lines.find { |candidate| candidate.start_with?("TINA4_REPORT ") }
    raise "setup_database probe reported nothing (exit #{status.exitstatus})\n#{stdout}\n#{stderr}" if line.nil?

    [JSON.parse(line.sub("TINA4_REPORT ", "")), "#{stdout}\n#{stderr}"]
  end

  def probe_ok?(report)
    row = report["row"]
    row.is_a?(Hash) && (row["probe"] || row["PROBE"]).to_i == 1
  end

  describe "PostgreSQL passwords containing ':' and '@'" do
    before do
      skip "[needs:postgres] postgres not set: TINA4_TEST_PG_URL not set" if admin_url.empty?
      begin
        require "pg"
      rescue LoadError
        skip "[needs:postgres] pg gem not installed"
      end
      begin
        @admin = PG.connect(admin_url)
      rescue PG::Error => e
        skip "[needs:postgres] postgres not reachable at #{URI.parse(admin_url).host}: #{e.class}"
      end
      @roles = []
    end

    after do
      @roles&.each { |role| @admin.exec("DROP ROLE IF EXISTS #{@admin.quote_ident(role)}") }
      @admin&.close
    end

    # A throwaway login role with +password+, and the URL that reaches it.
    def role_url(password, encode_password: false)
      role = "tina4_redact_#{SecureRandom.hex(4)}"
      @admin.exec("CREATE ROLE #{@admin.quote_ident(role)} LOGIN PASSWORD #{@admin.escape_literal(password)}")
      @roles << role
      admin = URI.parse(admin_url)
      written = encode_password ? URI.encode_www_form_component(password) : password
      "postgresql://#{role}:#{written}@#{admin.host}:#{admin.port}#{admin.path}"
    end

    it "a password with ':' connects and the log never shows any part of it" do
      password = "s3:cret-#{SecureRandom.hex(4)}"
      report, output = boot_setup_database(role_url(password))

      expect(probe_ok?(report)).to be(true), "did not really connect: #{report.inspect}\n#{output}"
      expect(output).to include("Database connected: ")
      expect(output).to include(":***@")
      expect(output).not_to include(password)
      expect(output).not_to include(password.split(":").first + ":") # the prefix the old regex left
      expect(output).not_to include(password.split(":").last)
    end

    it "a password with '@' (percent-encoded, so it connects) never reaches the log" do
      password = "s3@cret-#{SecureRandom.hex(4)}"
      report, output = boot_setup_database(role_url(password, encode_password: true))

      expect(probe_ok?(report)).to be(true), "did not really connect: #{report.inspect}\n#{output}"
      expect(output).to include("Database connected: ")
      expect(output).not_to include(password.split("@").last)
      expect(output).not_to include(URI.encode_www_form_component(password))
    end

    it "a raw '@' in the password never reaches the log on the refusal path either" do
      password = "s3@cret-#{SecureRandom.hex(4)}"
      _report, output = boot_setup_database(role_url(password))

      expect(output).to match(/Database (connected|connection failed)/)
      expect(output).not_to include(password.split("@").last)
    end
  end

  describe "ODBC PWD=" do
    before do
      skip "[needs:postgres] TINA4_TEST_ODBC_DSN not set (needs a live ODBC source)" if odbc_dsn.empty?
      skip "[needs:postgres] TINA4_TEST_ODBC_DSN carries no Pwd= - not set for this check" unless odbc_dsn.match?(/pwd=([^;]+)/i)
    end

    it "the ODBC password is redacted in the Database connected line" do
      secret = odbc_dsn[/pwd=([^;]+)/i, 1]
      report, output = boot_setup_database("odbc:///#{odbc_dsn}")

      expect(probe_ok?(report)).to be(true), "did not really connect: #{report.inspect}\n#{output}"
      # Tina4.setup_database's line carries the URL; Database#initialize logs a
      # separate "Database connected: odbc" (driver name only).
      connected = output.lines.find { |line| line.include?("Database connected: odbc:") }
      expect(connected).not_to be_nil, output
      expect(connected).to match(/pwd=\*\*\*/i)
      expect(output).not_to match(/pwd=#{Regexp.escape(secret)}/i)
    end
  end
end
