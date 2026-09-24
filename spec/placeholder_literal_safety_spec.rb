# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# tina4-python #138 parity: translating `?` into a driver's placeholder must
# skip every `?` that is not a placeholder, and a literal `%` must work with
# or without parameters.
#
# The contract (all four frameworks): a `?` inside a string literal ('...',
# Postgres E'...' and $$...$$ / $tag$...$tag$), a quoted identifier ("..." and
# `...`) or a comment (-- and /* */) is NOT a placeholder. Python's
# ? -> %s conversion was a plain text replace, and psycopg2 then read every
# literal % as a placeholder whenever parameters were passed - which fetch
# always does.
#
# Ruby rewrites `?` in exactly two places, and both were plain text rewrites:
#   * PostgresDriver#convert_placeholders  (? -> $1, $2 ... via gsub)
#   * MssqlDriver#interpolate_params       (tiny_tds has no binding, so each
#     ? is replaced by the escaped VALUE, one `sub` at a time - which also
#     rewrote a `?` inside a value it had just spliced in)
# MySQL (server-side prepare), SQLite, Firebird and ODBC bind `?` natively and
# never rewrite it; they are covered here as lock-ins. `%` is never special in
# Ruby's drivers (the pg gem has no %s style), which this spec also locks in.
#
# REAL engines - NO mocks. Postgres, MySQL, MSSQL are provisioned services;
# SQLite needs nothing; Firebird and ODBC run where the lab provides them.

require "spec_helper"
require_relative "support/live_postgres"
require "socket"
require "uri"
require "tmpdir"
require_relative "support/firebird_watchdog"

module PlaceholderSafetySpec
  TABLE = "placeholder_rb_note"

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
    @sqlite_path ||= File.join(Dir.mktmpdir("placeholder_rb"), "placeholder.db")
  end

  def self.value(row, key)
    return nil if row.nil?

    (row[key] || row[key.to_s] || row[key.to_s.upcase.to_sym]).then { |v| v.is_a?(String) ? v.strip : v }
  end

  PG_URL = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
  MYSQL_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MYSQL_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
  MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  FB_URL = ENV["TINA4_TEST_FIREBIRD_URL"].to_s
  ODBC_DSN = ENV["TINA4_TEST_ODBC_DSN"].to_s

  # from: what a FROM-less SELECT needs; int/text: a typed placeholder (Firebird
  # and Postgres cannot infer the type of a bare `?` in a select list).
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
      from: "", int: "CAST(? AS INTEGER)", text: "CAST(? AS VARCHAR(10))", ident: '"why?"',
      postgres: true, drop: "DROP TABLE IF EXISTS #{TABLE}"
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
      from: " FROM DUAL", int: "CAST(? AS SIGNED)", text: "CAST(? AS CHAR(10))", ident: "`why?`",
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
      from: "", int: "CAST(? AS INT)", text: "CAST(? AS VARCHAR(10))", ident: "[why?]",
      drop: "IF OBJECT_ID('#{TABLE}', 'U') IS NOT NULL DROP TABLE #{TABLE}"
    },
    "SQLite" => {
      skip: -> { nil },
      connect: -> { Tina4::Database.new("sqlite:///#{PlaceholderSafetySpec.sqlite_path}") },
      from: "", int: "CAST(? AS INTEGER)", text: "CAST(? AS TEXT)", ident: '"why?"',
      drop: "DROP TABLE IF EXISTS #{TABLE}"
    },
    "Firebird" => {
      skip: lambda {
        if FB_URL.empty? then "[needs:firebird] TINA4_TEST_FIREBIRD_URL not set - firebird case skipped"
        elsif !gem?("fb") then "[needs:firebird] fb gem not installed - firebird case skipped"
        else
          uri = URI.parse(FB_URL)
          "[needs:firebird] firebird not reachable at #{FB_URL}" unless reachable?(uri.host, uri.port || 3050)
        end
      },
      connect: lambda {
        Tina4::Database.new(FB_URL, username: ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA"),
                                    password: ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey"))
      },
      from: " FROM RDB$DATABASE", int: "CAST(? AS INTEGER)", text: "CAST(? AS VARCHAR(10))", ident: '"why?"',
      drop: "DROP TABLE #{TABLE}"
    },
    "ODBC" => {
      skip: lambda {
        if ODBC_DSN.empty? then "[needs:runtime=odbc] TINA4_TEST_ODBC_DSN not set - odbc case skipped"
        elsif !gem?("odbc") then "[needs:runtime=odbc] ruby-odbc gem not installed - odbc case skipped"
        end
      },
      connect: -> { Tina4::Database.new("odbc:///#{ODBC_DSN}") },
      from: "", int: "CAST(? AS INTEGER)", text: "CAST(? AS VARCHAR(10))", ident: '"why?"',
      drop: "DROP TABLE IF EXISTS #{TABLE}"
    }
  }.freeze
end

RSpec.describe "Placeholder translation skips literals, identifiers and comments (python #138)" do
  PlaceholderSafetySpec::ENGINES.each do |engine, cfg|
    # A leaked Firebird transaction fails the example instead of hanging it.
    context engine, firebird_watchdog: engine == "Firebird" do
      before(:all) { @skip_reason = cfg[:skip].call }

      before(:each) do
        skip(@skip_reason) if @skip_reason
        @db = cfg[:connect].call
      end

      after(:each) { @db&.close rescue nil }

      def v(row, key)
        PlaceholderSafetySpec.value(row, key)
      end

      let(:from) { cfg[:from] }

      it "fetch: a literal % with no params" do
        rows = @db.fetch("SELECT 'a%' AS v#{from}", [], limit: 5, no_cache: true).records
        expect(rows.map { |row| v(row, :v) }).to eq(["a%"])
      end

      it "fetch: LIKE 'a%' plus a ? param" do
        rows = @db.fetch("SELECT 'abc' AS v#{from} WHERE 'abc' LIKE 'a%' AND 1 = ?", [1], limit: 5, no_cache: true).records
        expect(rows.map { |row| v(row, :v) }).to eq(["abc"])
      end

      it "fetch_one: SELECT 'why?' AS v, ? AS n" do
        row = @db.fetch_one("SELECT 'why?' AS v, #{cfg[:int]} AS n#{from}", [1], no_cache: true)
        expect([v(row, :v), v(row, :n).to_i]).to eq(["why?", 1])
      end

      it "fetch: the pattern passed as a param" do
        rows = @db.fetch("SELECT 'abc' AS v#{from} WHERE 'abc' LIKE ?", ["a%"], limit: 5, no_cache: true).records
        expect(rows.map { |row| v(row, :v) }).to eq(["abc"])
      end

      it "a ? inside a -- comment and a /* */ comment is not a placeholder" do
        row = @db.fetch_one("SELECT /* a ? here */ #{cfg[:int]} AS n#{from} -- and a ? there\n", [7], no_cache: true)
        expect(v(row, :n).to_i).to eq(7)
      end

      it "a ? inside a quoted identifier is not a placeholder" do
        row = @db.fetch_one("SELECT 1 AS #{cfg[:ident]}, #{cfg[:int]} AS n#{from}", [8], no_cache: true)
        expect(v(row, :n).to_i).to eq(8)
      end

      it "a param VALUE containing ? is bound whole, and the next param still lands" do
        row = @db.fetch_one("SELECT #{cfg[:text]} AS a, #{cfg[:int]} AS n#{from}", ["a?b", 2], no_cache: true)
        expect([v(row, :a), v(row, :n).to_i]).to eq(["a?b", 2])
      end

      it "execute: a literal % and a literal ? with a param, read back" do
        begin
          @db.execute(cfg[:drop])
        rescue StandardError
          nil
        end
        @db.execute("CREATE TABLE #{PlaceholderSafetySpec::TABLE} (id INTEGER NOT NULL PRIMARY KEY, body VARCHAR(20))")
        begin
          @db.execute("INSERT INTO #{PlaceholderSafetySpec::TABLE} (id, body) VALUES (?, 'a% why?')", [1])
          @db.execute("UPDATE #{PlaceholderSafetySpec::TABLE} SET body = body WHERE body LIKE 'a%' AND id = ?", [1])
          row = @db.fetch_one("SELECT body FROM #{PlaceholderSafetySpec::TABLE} WHERE id = ?", [1], no_cache: true)
          expect(v(row, :body)).to eq("a% why?")
        ensure
          @db.execute(cfg[:drop]) rescue nil
        end
      end

      if cfg[:postgres]
        it "Postgres: a ? inside $$...$$, $tag$...$tag$ and E'...' is not a placeholder" do
          row = @db.fetch_one(
            "SELECT $$why?$$ AS a, $q$and ? here$q$ AS b, E'it\\'s ?' AS c, #{cfg[:int]} AS n", [9], no_cache: true
          )
          expect([v(row, :a), v(row, :b), v(row, :c), v(row, :n).to_i]).to eq(["why?", "and ? here", "it's ?", 9])
        end
      end
    end
  end
end

RSpec.describe "Tina4::SQLTranslator.replace_placeholders (the shared ? scanner)" do
  def numbered(sql)
    Tina4::SQLTranslator.replace_placeholders(sql) { |index| "$#{index + 1}" }
  end

  {
    "SELECT ? , ?" => "SELECT $1 , $2",
    "SELECT 'why?', ?" => "SELECT 'why?', $1",
    "SELECT 'it''s ?', ?" => "SELECT 'it''s ?', $1",
    "SELECT E'it\\'s ?', ?" => "SELECT E'it\\'s ?', $1",
    "SELECT \"a?\", `b?`, ?" => "SELECT \"a?\", `b?`, $1",
    "SELECT $$x?$$, $t$y?$t$, ?" => "SELECT $$x?$$, $t$y?$t$, $1",
    "SELECT ? -- c?\n, ?" => "SELECT $1 -- c?\n, $2",
    "SELECT /* ? */ ?" => "SELECT /* ? */ $1",
    "SELECT 'a%' WHERE x = ?" => "SELECT 'a%' WHERE x = $1",
    "SELECT $1" => "SELECT $1"
  }.each do |sql, expected|
    it "#{sql.inspect} -> #{expected.inspect}" do
      expect(numbered(sql)).to eq(expected)
    end
  end
end
