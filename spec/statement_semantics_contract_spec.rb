# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Database statement semantics - the runner for statement_semantics_contract.json
# (ADR-0065).
#
# spec/fixtures/statement_semantics_contract.json is a byte-for-byte copy of
# tina4-documentation/plan/v3/fixtures/statement_semantics_contract.json. The
# same file drives the Python, PHP and Node runners, so a vector added there is
# a vector all four frameworks must answer identically.
#
#   * write detection and placeholder translation walk the fixture's vectors
#     through Tina4::Database.write_statement? and
#     Tina4::SQLTranslator.replace_placeholders (numbered :1, :2, ...);
#   * fetch of a write, execute rows and the query cache run against a REAL
#     SQLite file, with durability read back on a SECOND, fresh connection;
#   * OUTPUT and EXEC run against a REAL SQL Server, and the no-parameters rule
#     against a REAL PostgreSQL. Both are provisioned services: under
#     TINA4_REQUIRE_SERVICES their skip fails the run.
#
# NO MOCKS.

require "spec_helper"
require_relative "support/live_postgres"
require "json"
require "socket"
require "tmpdir"
require "uri"

module StatementSemanticsContract
  CONTRACT = JSON.parse(File.read(File.join(__dir__, "fixtures", "statement_semantics_contract.json")))
  JSONB = %('{"a":1}'::jsonb)
  PG_URL = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
  MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
  MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i

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

  def self.value(row, key)
    row[key] || row[key.to_s] || row[key.to_s.upcase.to_sym] || row[key.to_s.upcase]
  end
end

RSpec.describe "Database statement semantics contract (ADR-0065)" do
  let(:contract) { StatementSemanticsContract::CONTRACT }

  def value(row, key)
    StatementSemanticsContract.value(row, key)
  end

  # ── Vectors: the same data through every framework's own function ────────

  it "write detection answers every fixture vector" do
    wrong = contract["write_detection_vectors"].reject { |vector| Tina4::Database.write_statement?(vector["sql"]) == vector["write"] }
    expect(wrong.map { |vector| "#{vector['sql'].inspect} expected write=#{vector['write']}" }).to eq([])
  end

  it "placeholder translation answers every fixture vector" do
    wrong = contract["placeholder_vectors"].filter_map do |vector|
      translated = Tina4::SQLTranslator.replace_placeholders(vector["sql"]) { |index| ":#{index + 1}" }
      "#{vector['sql'].inspect} -> #{translated.inspect}, expected #{vector['numbered'].inspect}" if translated != vector["numbered"]
    end
    expect(wrong).to eq([])
  end

  # ── SQLite: fetch of a write, execute rows, the query cache ──────────────

  context "on a real SQLite file" do
    around(:each) do |example|
      saved = %w[TINA4_DB_CACHE TINA4_AUTO_CACHING].to_h { |key| [key, ENV[key]] }
      saved.each_key { |key| ENV.delete(key) }
      Dir.mktmpdir("tina4-statement-semantics") do |dir|
        @url = "sqlite:///#{File.join(dir, 'semantics.db')}"
        setup = Tina4::Database.new(@url)
        setup.execute("CREATE TABLE note (id INTEGER PRIMARY KEY AUTOINCREMENT, text VARCHAR(40))")
        setup.close
        example.run
      end
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    def rows_seen_by_a_fresh_connection
      fresh = Tina4::Database.new(@url)
      value(fresh.fetch_one("SELECT COUNT(*) AS n FROM note", [], no_cache: true), :n).to_i
    ensure
      fresh&.close
    end

    it "fetch of an insert returning runs once and commits" do
      writer = Tina4::Database.new(@url)
      result = writer.fetch("INSERT INTO note (text) VALUES (?) RETURNING id", ["via fetch"])
      writer.close
      expect(result.records.map { |row| value(row, :id).to_i }).to eq([1])
      expect(rows_seen_by_a_fresh_connection).to eq(1)
    end

    it "fetch one of an insert returning runs once and commits" do
      writer = Tina4::Database.new(@url)
      row = writer.fetch_one("INSERT INTO note (text) VALUES (?) RETURNING id", ["via fetch_one"])
      writer.close
      expect(value(row, :id).to_i).to eq(1)
      expect(rows_seen_by_a_fresh_connection).to eq(1)
    end

    it "a fetched write is never cached and flushes the cache" do
      ENV["TINA4_DB_CACHE"] = "true"
      database = Tina4::Database.new(@url)
      ENV.delete("TINA4_DB_CACHE")
      count_sql = "SELECT COUNT(*) AS n FROM note"
      expect(value(database.fetch_one(count_sql), :n).to_i).to eq(0) # a cached read
      first = database.fetch_one("INSERT INTO note (text) VALUES (?) RETURNING id", ["same"])
      second = database.fetch_one("INSERT INTO note (text) VALUES (?) RETURNING id", ["same"])
      expect(value(first, :id).to_i).not_to eq(value(second, :id).to_i), "the second fetched write was served from the cache"
      expect(value(database.fetch_one(count_sql), :n).to_i).to eq(2), "the cached count survived a fetched write"
      database.close
      expect(rows_seen_by_a_fresh_connection).to eq(2)
    end

    it "execute returns rows for select with select and returning" do
      database = Tina4::Database.new(@url)
      database.execute("INSERT INTO note (text) VALUES (?)", ["one"])
      [
        ["SELECT id, text FROM note WHERE id = ?", [1], [[1, "one"]]],
        ["WITH later AS (SELECT id FROM note WHERE id >= ?) SELECT id FROM later", [1], [[1, nil]]],
        ["INSERT INTO note (text) VALUES (?) RETURNING id", ["two"], [[2, nil]]]
      ].each do |sql, params, expected|
        result = database.execute(sql, params)
        expect(result).to be_a(Tina4::DatabaseResult), "execute(#{sql}) returned #{result.inspect}"
        expect(result.records.map { |row| [value(row, :id).to_i, value(row, :text)] }).to eq(expected), sql
      end
      database.close
      expect(rows_seen_by_a_fresh_connection).to eq(2)
    end

    it "execute of a plain write keeps its return value" do
      database = Tina4::Database.new(@url)
      expect(database.execute("INSERT INTO note (text) VALUES (?)", ["plain"])).to be(true)
      database.close
      expect(rows_seen_by_a_fresh_connection).to eq(1)
    end
  end

  # ── SQL Server: OUTPUT and EXEC ──────────────────────────────────────────

  it "execute returns rows for output and exec on sql server" do
    host = StatementSemanticsContract::MSSQL_HOST
    port = StatementSemanticsContract::MSSQL_PORT
    skip "[needs:mssql] tiny_tds gem not installed - MSSQL not reachable" unless StatementSemanticsContract.gem?("tiny_tds")
    skip "[needs:mssql] MSSQL not reachable at #{host}:#{port}" unless StatementSemanticsContract.reachable?(host, port)

    database = Tina4::Database.new("mssql://#{host}:#{port}/#{ENV.fetch('TINA4_TEST_MSSQL_DB', 'tina4_test')}",
                                   username: ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa"),
                                   password: ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure"))
    drop_all = lambda do
      database.execute("IF OBJECT_ID('contract_rb_notes', 'P') IS NOT NULL DROP PROCEDURE contract_rb_notes")
      database.execute("IF OBJECT_ID('contract_rb_note', 'U') IS NOT NULL DROP TABLE contract_rb_note")
    end
    begin
      drop_all.call
      database.execute("CREATE TABLE contract_rb_note (id INT IDENTITY(1,1) PRIMARY KEY, text VARCHAR(40))")
      database.execute("CREATE PROCEDURE contract_rb_notes AS SELECT id, text FROM contract_rb_note ORDER BY id")
      inserted = database.execute("INSERT INTO contract_rb_note (text) OUTPUT inserted.id VALUES (?)", ["out"])
      expect(inserted).to be_a(Tina4::DatabaseResult)
      expect(inserted.records.map { |row| value(row, :id).to_i }).to eq([1])
      listed = database.execute("EXEC contract_rb_notes")
      expect(listed).to be_a(Tina4::DatabaseResult)
      expect(listed.records.map { |row| [value(row, :id).to_i, value(row, :text)] }).to eq([[1, "out"]])
    ensure
      drop_all.call
      database.close
    end
  end

  # ── PostgreSQL: no parameters, no rewrite ────────────────────────────────

  context "on a real PostgreSQL" do
    before(:each) do
      url = StatementSemanticsContract::PG_URL
      uri = URI.parse(url)
      skip "[needs:postgres] pg gem not installed - PostgreSQL not reachable" unless StatementSemanticsContract.gem?("pg")
      skip "[needs:postgres] PostgreSQL not reachable at #{url}" unless StatementSemanticsContract.reachable?(uri.host, uri.port || 5432)
      @db = Tina4::Database.new(url, username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                                     password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
    end

    after(:each) { @db&.close }

    def truthy(row, key)
      [true, "t", "true"].include?(value(row, key))
    end

    it "sql with no parameters is sent exactly as written on postgresql" do
      jsonb = StatementSemanticsContract::JSONB
      row = @db.fetch_one("SELECT #{jsonb} ? 'a' AS has_key, #{jsonb} ?| array['a','z'] AS any_key, " \
                          "#{jsonb} ?& array['a'] AS all_keys, 'a%' AS percent", [], no_cache: true)
      expect([truthy(row, :has_key), truthy(row, :any_key), truthy(row, :all_keys), value(row, :percent)])
        .to eq([true, true, true, "a%"])
    end

    it "jsonb exists functions and literal percent work with parameters on postgresql" do
      jsonb = StatementSemanticsContract::JSONB
      row = @db.fetch_one("SELECT jsonb_exists(#{jsonb}, ?) AS has_key, 'a%' || ? AS joined", %w[a b], no_cache: true)
      expect([truthy(row, :has_key), value(row, :joined)]).to eq([true, "a%b"])
    end
  end
end
