# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# PostgreSQL: a connection the server drops is replaced, not reused forever
# (parity with the Python master #236/#242; issue #244).
#
# BUG (pre-fix): the PostgresDriver never re-established a dropped link. Once the
# server closed the connection (failover, idle reap, pg_terminate_backend) every
# exec raised PG::ConnectionBad until the process was restarted.
#
# FIX: exec_with_reconnect heals a dead link before a statement runs, and on a
# connection error (not a real SQL error) reconnects and retries once when no
# explicit transaction owns the link; a reconnect that itself fails leaves the
# link closed so the next statement recovers once a server returns.
#
# NO MOCKS: a real PostgreSQL. The drop is a real pg_terminate_backend from a
# second connection. Same gate as the other PG specs - skip when the pg gem is
# missing or the server is unreachable.
require "socket"

PG244_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PG244_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "5432").to_i
PG244_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
PG244_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
PG244_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pg244_reachable?
  TCPSocket.new(PG244_HOST, PG244_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def pg244_gem_available?
  require "pg"
  true
rescue LoadError
  false
end

RSpec.describe "PostgreSQL reconnect after a dropped link (#244)" do
  before(:all) do
    @skip_reason = if !pg244_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pg244_reachable?
                     "PostgreSQL not reachable at #{PG244_HOST}:#{PG244_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    url = "postgres://#{PG244_HOST}:#{PG244_PORT}/#{PG244_DB}"
    @db = Tina4::Database.new(url, username: PG244_USER, password: PG244_PASS)
    @killer = Tina4::Database.new(url, username: PG244_USER, password: PG244_PASS)
    @db.execute("DROP TABLE IF EXISTS pg244_reconnect")
    @db.execute("CREATE TABLE pg244_reconnect (id SERIAL PRIMARY KEY, note TEXT)")
  end

  after(:each) do
    next unless @db

    begin
      @db.execute("DROP TABLE IF EXISTS pg244_reconnect")
    ensure
      @db.close rescue nil
      @killer&.close rescue nil
    end
  end

  def backend_pid(db)
    db.fetch("SELECT pg_backend_pid() AS p")[0][:p].to_i
  end

  def drop_connection(pid)
    @killer.fetch("SELECT pg_terminate_backend(#{pid.to_i})")
  end

  it "replaces a dropped link and the statement recovers on a fresh backend" do
    before = backend_pid(@db)
    drop_connection(before)

    @db.execute("INSERT INTO pg244_reconnect (note) VALUES (?)", ["after-drop"])

    expect(backend_pid(@db)).not_to eq(before)
    rows = @db.fetch("SELECT note FROM pg244_reconnect ORDER BY id")
    expect(rows.count).to eq(1)
    expect(rows[0][:note]).to eq("after-drop")
  end

  it "recovers on every read path after a drop" do
    drop_connection(backend_pid(@db))
    expect(@db.fetch("SELECT note FROM pg244_reconnect").count).to eq(0)

    drop_connection(backend_pid(@db))
    expect(@db.fetch("SELECT 1 AS one")[0][:one].to_i).to eq(1)
  end
end
