# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# The boot-time "Database connected: <url>" line is only written when the
# database really connected.
#
# Tina4.setup_database logged it unconditionally after Tina4::Database.new. But
# Database#connect logs-and-degrades on failure (it records the error and leaves
# `connected` false rather than raising), so the rescue never ran and an operator
# reading the boot log saw "Database connection failed" followed by "Database
# connected: <url>" for the same unreachable database.
#
# No mocks: a subprocess boots Tina4.setup_database against a REAL closed port
# (nothing listens on port 1), and the success path uses a real SQLite file.

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Database connected boot log is truthful" do
  let(:repository_root) { File.expand_path("..", __dir__) }

  def boot_setup_database(database_url, dir)
    source = <<~RUBY
      require "tina4"
      Tina4.send(:setup_database)
      puts "TINA4_REPORT connected=\#{Tina4.database&.connected.inspect}"
    RUBY
    environment = { "TINA4_DATABASE_URL" => database_url, "TINA4_DEBUG" => "false",
                    "TINA4_LOG_LEVEL" => "ALL", "TINA4_NO_BROWSER" => "true" }
    stdout, stderr, = Open3.capture3(environment, RbConfig.ruby, "-I#{File.join(repository_root, "lib")}",
                                     "-e", source, chdir: dir)
    "#{stdout}\n#{stderr}"
  end

  it "does not log 'Database connected: <url>' when the connect failed" do
    begin
      require "pg"
    rescue LoadError
      skip "needs the pg gem to build a postgres driver"
    end
    url = "postgres://127.0.0.1:1/tina4_does_not_exist"

    output = Dir.mktmpdir("tina4-db-log") { |dir| boot_setup_database(url, dir) }

    expect(output).to include("TINA4_REPORT connected=false"), output
    expect(output).to include("Database connection failed"), output
    expect(output).not_to include("Database connected: postgres://"), output
    expect(output).to include("Database not connected: postgres://127.0.0.1:1/tina4_does_not_exist"), output
  end

  it "still logs 'Database connected: <url>' when the connect succeeded" do
    output = Dir.mktmpdir("tina4-db-log") do |dir|
      boot_setup_database("sqlite:///#{File.join(dir, "app.db")}", dir)
    end

    expect(output).to include("TINA4_REPORT connected=true"), output
    expect(output).to include("Database connected: sqlite:///"), output
    expect(output).not_to include("Database not connected"), output
  end
end
