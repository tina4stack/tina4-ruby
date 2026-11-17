# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# The database lines in the boot log tell the truth (review of tina4-ruby#172).
#
#   * Pooled mode (TINA4_DB_POOL > 0) connects lazily, so Database#initialize
#     sets `connected` true before anything connects. setup_database used to
#     print "Database connected: <url>" for an unreachable database; it now
#     says the pool is configured and not yet connected.
#   * A successful single connection printed TWO "Database connected" lines
#     (Database#connect with the driver name, setup_database with the URL); it
#     now prints one, carrying the URL.
#   * auto_migrate_on_startup! said "no database configured" when
#     TINA4_DATABASE_URL was set but Database.new could not open it.
#   * None of these lines carries `user:pass@`.
#
# No mocks: a subprocess boots the real setup_database / auto_migrate_on_startup!
# against a REAL closed port (nothing listens on port 1), a real unsupported
# scheme, and a real SQLite file.

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Database boot log is truthful (pool, single line, startup migrations)" do
  let(:repository_root) { File.expand_path("..", __dir__) }
  let(:unreachable) { "postgres://tina4user:s3cret@127.0.0.1:1/tina4_nodb" }

  def boot(database_url, extra_env = {})
    source = <<~RUBY
      require "tina4"
      Tina4.send(:setup_database)
      Tina4.auto_migrate_on_startup!(Dir.pwd)
    RUBY
    environment = { "TINA4_DEBUG" => "false", "TINA4_DB_POOL" => nil, "TINA4_AUTO_MIGRATE" => nil,
                    "TINA4_LOG_LEVEL" => "ALL", "TINA4_NO_BROWSER" => "true" }
    Dir.mktmpdir("tina4-db-boot-log") do |dir|
      Dir.mkdir(File.join(dir, "migrations"))
      File.write(File.join(dir, "migrations", "000001_items.sql"), "CREATE TABLE items (id INTEGER PRIMARY KEY);")
      environment["TINA4_DATABASE_URL"] = database_url&.gsub("@DIR@", dir)
      stdout, stderr, = Open3.capture3(environment.merge(extra_env),
                                       RbConfig.ruby, "-I#{File.join(repository_root, "lib")}",
                                       "-e", source, chdir: dir)
      "#{stdout}\n#{stderr}"
    end
  end

  def require_pg
    require "pg"
  rescue LoadError
    skip "[needs:postgres] pg gem not installed (builds the postgres driver)"
  end

  it "pooled mode with an unreachable database does not claim 'Database connected'" do
    require_pg
    output = boot(unreachable, "TINA4_DB_POOL" => "2")

    expect(output).not_to include("Database connected"), output
    expect(output).to include("Database pool configured (2 connections, not yet connected - connects on first use): " \
                              "postgres://127.0.0.1:1/tina4_nodb"), output
    expect(output).not_to include("s3cret"), output
    expect(output).not_to include("tina4user"), output
  end

  it "a single unreachable connection names the database without credentials" do
    require_pg
    output = boot(unreachable)

    expect(output).to include("Database not connected: postgres://127.0.0.1:1/tina4_nodb"), output
    expect(output).not_to include("Database connected"), output
  end

  it "a successful connection logs exactly one 'Database connected' line, with the URL" do
    output = boot("sqlite:///@DIR@/app.db")

    connected = output.lines.grep(/Database connected/)
    expect(connected.size).to eq(1), output
    expect(connected.first).to include("Database connected: sqlite:///"), output
    expect(output).to include("Applied 1 pending migration(s) on startup"), output
  end

  it "startup migrations name a configured-but-unopenable database instead of 'no database configured'" do
    output = boot("bogus://tina4user:s3cret@127.0.0.1:1/tina4_nodb")

    expect(output).not_to include("no database configured"), output
    expect(output).to include("Startup migrations skipped (database configured but could not connect to " \
                              "bogus://127.0.0.1:1/tina4_nodb)"), output
  end

  it "startup migrations still say 'no database configured' when TINA4_DATABASE_URL is unset" do
    output = boot(nil)

    expect(output).to include("Startup migrations skipped (no database configured)"), output
  end
end
