# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Database#fetch reports the TRUE total for the filter, not the page length,
# on every engine - with and without a trailing ORDER BY.
#
# Found by the Node worker: on SQL Server and MySQL Node's fetch() returned the
# PAGE LENGTH as the total. Two causes: the COUNT probe lacked the derived-table
# alias those engines require, and SQL Server rejects an ORDER BY inside a
# derived table (error 1033) unless it carries TOP/OFFSET, so a trailing
# top-level ORDER BY must be stripped - for the probe ONLY; the page keeps it.
# A failed probe is best-effort by design (count falls back to the page
# length), which is exactly why the wrong number was silent.
#
# 25 rows, 22 match the filter, a 10-row page: count must be 22.
#
# REAL engines - NO mocks. Postgres, MySQL and MSSQL are provisioned services
# (their skips fail the TINA4_REQUIRE_SERVICES gate); SQLite needs nothing.

require "spec_helper"
require_relative "support/live_postgres"
require "socket"
require "uri"
require "tmpdir"

module CountProbeSpec
  TABLE = "count_probe_rb_row"

  def self.reachable?(host, port)
    TCPSocket.new(host, port).tap(&:close)
    true
  rescue StandardError
    false
  end

  def self.gem?(name)
    require name
    true
  rescue LoadError
    false
  end

  def self.sqlite_path
    @sqlite_path ||= File.join(Dir.mktmpdir("count_probe_rb"), "count_probe.db")
  end

  PG_URL = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
  MYSQL_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MYSQL_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
  MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i

  ENGINES = {
    "PostgreSQL" => {
      skip: lambda {
        uri = URI.parse(PG_URL)
        if !gem?("pg") then "[needs:postgres] pg gem not installed - PostgreSQL not reachable"
        elsif !reachable?(uri.host, uri.port || 5432) then "[needs:postgres] PostgreSQL not reachable at #{PG_URL}"
        end
      },
      connect: lambda {
        Tina4::Database.new(PG_URL, username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                                    password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
      },
      create: "CREATE TABLE #{TABLE} (id INTEGER PRIMARY KEY, cat VARCHAR(10) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}"
    },
    "MySQL" => {
      skip: lambda {
        if !gem?("mysql2") then "[needs:mysql] mysql2 gem not installed - MySQL not reachable"
        elsif !reachable?(MYSQL_HOST, MYSQL_PORT) then "[needs:mysql] MySQL not reachable at #{MYSQL_HOST}:#{MYSQL_PORT}"
        end
      },
      connect: lambda {
        Tina4::Database.new("mysql://#{MYSQL_HOST}:#{MYSQL_PORT}/#{ENV.fetch('TINA4_TEST_MYSQL_DB', 'tina4_test')}",
                            username: ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4"),
                            password: ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4"))
      },
      create: "CREATE TABLE #{TABLE} (id INTEGER PRIMARY KEY, cat VARCHAR(10) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}"
    },
    "MSSQL" => {
      skip: lambda {
        if !gem?("tiny_tds") then "[needs:mssql] tiny_tds gem not installed - MSSQL not reachable"
        elsif !reachable?(MSSQL_HOST, MSSQL_PORT) then "[needs:mssql] MSSQL not reachable at #{MSSQL_HOST}:#{MSSQL_PORT}"
        end
      },
      connect: lambda {
        Tina4::Database.new("mssql://#{MSSQL_HOST}:#{MSSQL_PORT}/#{ENV.fetch('TINA4_TEST_MSSQL_DB', 'tina4_test')}",
                            username: ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa"),
                            password: ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure"))
      },
      create: "CREATE TABLE #{TABLE} (id INT PRIMARY KEY, cat VARCHAR(10) NOT NULL)",
      drop: "IF OBJECT_ID('#{TABLE}', 'U') IS NOT NULL DROP TABLE #{TABLE}"
    },
    "SQLite" => {
      skip: -> { nil },
      connect: -> { Tina4::Database.new("sqlite:///#{CountProbeSpec.sqlite_path}") },
      create: "CREATE TABLE #{TABLE} (id INTEGER PRIMARY KEY, cat VARCHAR(10) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}"
    }
  }.freeze
end

RSpec.describe "Database#fetch reports the true total for the filter, not the page length" do
  CountProbeSpec::ENGINES.each do |engine, cfg|
    context engine do
      before(:all) { @skip_reason = cfg[:skip].call }

      before(:each) do
        skip(@skip_reason) if @skip_reason
        @db = cfg[:connect].call
        @db.execute(cfg[:drop])
        @db.execute(cfg[:create])
        (1..25).each do |id|
          @db.execute("INSERT INTO #{CountProbeSpec::TABLE} (id, cat) VALUES (?, ?)", [id, id <= 22 ? "keep" : "drop"])
        end
      end

      after(:each) do
        next unless @db

        begin
          @db.execute(cfg[:drop])
        rescue StandardError
          nil
        ensure
          @db.close rescue nil
        end
      end

      {
        "without ORDER BY" => "SELECT id, cat FROM #{CountProbeSpec::TABLE} WHERE cat = ?",
        "with a trailing ORDER BY" => "SELECT id, cat FROM #{CountProbeSpec::TABLE} WHERE cat = ? ORDER BY id"
      }.each do |label, sql|
        it "a 10-row page of 22 matching rows reports count 22 (#{label})" do
          page = @db.fetch(sql, ["keep"], limit: 10, no_cache: true)
          expect(page.records.length).to eq(10)
          expect(page.count).to eq(22), "#{engine} reported #{page.count} - the page length, not the filter total"

          last = @db.fetch(sql, ["keep"], limit: 10, offset: 20, no_cache: true)
          expect(last.records.length).to eq(2)
          expect(last.count).to eq(22)
        end
      end

      it "the page itself keeps its ORDER BY (only the probe drops it)" do
        page = @db.fetch("SELECT id FROM #{CountProbeSpec::TABLE} WHERE cat = ? ORDER BY id DESC", ["keep"],
                         limit: 3, no_cache: true)
        expect(page.records.map { |row| (row[:id] || row["id"]).to_i }).to eq([22, 21, 20])
        expect(page.count).to eq(22)
      end
    end
  end
end

RSpec.describe "Tina4::Database.strip_trailing_order_by (the COUNT probe's view of the SQL)" do
  {
    "SELECT * FROM t WHERE a = ? ORDER BY id" => "SELECT * FROM t WHERE a = ?",
    "SELECT * FROM t order by id desc, name" => "SELECT * FROM t",
    "SELECT * FROM t" => "SELECT * FROM t",
    "SELECT * FROM (SELECT TOP 5 * FROM t ORDER BY id) x" => "SELECT * FROM (SELECT TOP 5 * FROM t ORDER BY id) x",
    "SELECT * FROM t ORDER BY id OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY" =>
      "SELECT * FROM t ORDER BY id OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY",
    "SELECT * FROM t WHERE note = 'ORDER BY x'" => "SELECT * FROM t WHERE note = 'ORDER BY x'",
    "SELECT * FROM t -- ORDER BY id" => "SELECT * FROM t -- ORDER BY id"
  }.each do |sql, expected|
    it "#{sql.inspect} -> #{expected.inspect}" do
      expect(Tina4::Database.strip_trailing_order_by(sql)).to eq(expected)
    end
  end
end
