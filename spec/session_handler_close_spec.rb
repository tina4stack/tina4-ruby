# frozen_string_literal: true

# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# DatabaseHandler#close releases the connection the handler opened itself
# (from TINA4_DATABASE_URL), and never one the caller injected with :db.
#
# The handler had no close at all, so an env-built SQLite session file stayed
# open for the life of the process; on Windows an open file cannot be deleted.
# The proof works on every OS: the SQLite driver runs in WAL mode, and SQLite
# removes the -wal side file when the LAST connection closes. Real SQLite files,
# real connections, no doubles.

require "spec_helper"
require_relative "support/real_env"
require "tmpdir"

RSpec.describe Tina4::SessionHandlers::DatabaseHandler do
  around do |example|
    Dir.mktmpdir("tina4_sessclose_") do |dir|
      @dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  it "releases a connection it opened, and reopens on the next use" do
    set_real_env("TINA4_DATABASE_URL" => "sqlite:///sessions.db")
    handler = described_class.new
    handler.write("sess-1", { "user" => "ada" }, 3600)
    expect(File.exist?(File.join(@dir, "sessions.db-wal"))).to be(true), "a write opens the database in WAL mode"

    handler.close
    expect(File.exist?(File.join(@dir, "sessions.db-wal"))).to be(false), "SQLite removes -wal on the last close"

    expect { handler.close }.not_to raise_error

    expect(handler.read("sess-1")).to include("user" => "ada")
    handler.close
    expect { File.delete(File.join(@dir, "sessions.db")) }.not_to raise_error
  end

  it "leaves an injected connection open" do
    db = Tina4::Database.new("sqlite:///injected.db")
    # A TEMP table lives only inside the one connection that made it, so it
    # proves the caller's connection survived - a reconnect would lose it.
    db.execute("CREATE TEMP TABLE caller_state (x INTEGER)")
    db.execute("INSERT INTO caller_state (x) VALUES (7)")
    begin
      handler = described_class.new(db: db)
      handler.write("sess-2", { "user" => "grace" }, 3600)

      handler.close

      expect(db.fetch_one("SELECT x FROM caller_state")).to include(x: 7)
    ensure
      db.close
    end
  end
end
