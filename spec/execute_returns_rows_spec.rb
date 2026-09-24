# frozen_string_literal: true
#
# Database#execute returns the rows of any statement that produces them
# (maintainer decision, all four frameworks, matching PHP).
#
# Contract: execute(sql, params) of a SELECT, a WITH ... SELECT, an
# INSERT/UPDATE/DELETE ... RETURNING (MSSQL: OUTPUT), or a CALL/EXEC that
# returns a result set, returns a Tina4::DatabaseResult carrying those rows -
# the SAME type fetch returns. The statement runs exactly once, with no COUNT
# probe and no LIMIT/OFFSET. A write that returns no rows keeps its current
# return value (true). Writes commit as before, and a read outside an explicit
# transaction ends its transaction (proved through pg_stat_activity).
#
# Before: execute handed back the DRIVER's raw result for a row-returning
# statement - a PG::Result, a Mysql2 result, an Fb::Cursor - and not at all
# for WITH ... SELECT or OUTPUT, which got `true`.
#
# REAL engines - NO mocks. Postgres, MySQL, MSSQL are provisioned services;
# SQLite needs nothing; Firebird and ODBC run where the lab provides them
# (Firebird under the spec watchdog).

require "spec_helper"
require_relative "support/live_postgres"
require "socket"
require "uri"
require "tmpdir"
require_relative "support/firebird_watchdog"

module ExecuteRowsSpec
  TABLE = "exec_rows_rb_note"

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
    @sqlite_path ||= File.join(Dir.mktmpdir("exec_rows_rb"), "exec_rows.db")
  end

  def self.value(row, key)
    row[key] || row[key.to_s] || row[key.to_s.upcase.to_sym] || row[key.to_s.upcase]
  end

  PG_URL = ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
  MYSQL_HOST = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MYSQL_PORT = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
  MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  FB_URL = ENV["TINA4_TEST_FIREBIRD_URL"].to_s
  ODBC_DSN = ENV["TINA4_TEST_ODBC_DSN"].to_s

  # returning: the INSERT that hands back the new id, or nil where the engine
  # cannot (MySQL has no RETURNING; the fb gem cannot read a single-row
  # INSERT ... VALUES ... RETURNING, so Firebird uses INSERT ... SELECT).
  ENGINES = {
    "PostgreSQL" => {
      skip: lambda {
        uri = URI.parse(PG_URL)
        if !gem?("pg") then "pg gem not installed - PostgreSQL not reachable"
        elsif !reachable?(uri.host, uri.port || 5432) then "PostgreSQL not reachable at #{PG_URL}"
        end
      },
      connect: lambda {
        Tina4::Database.new(PG_URL, username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                                    password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
      },
      create: "CREATE TABLE #{TABLE} (id SERIAL PRIMARY KEY, body VARCHAR(40) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}",
      returning: "INSERT INTO #{TABLE} (body) VALUES (?) RETURNING id",
      cte: "WITH picked AS (SELECT id, body FROM #{TABLE} WHERE body = ?) SELECT id, body FROM picked"
    },
    "MySQL" => {
      skip: lambda {
        if !gem?("mysql2") then "mysql2 gem not installed - MySQL not reachable"
        elsif !reachable?(MYSQL_HOST, MYSQL_PORT) then "MySQL not reachable at #{MYSQL_HOST}:#{MYSQL_PORT}"
        end
      },
      connect: lambda {
        Tina4::Database.new("mysql://#{MYSQL_HOST}:#{MYSQL_PORT}/#{ENV.fetch('TINA4_TEST_MYSQL_DB', 'tina4_test')}",
                            username: ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4"),
                            password: ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4"))
      },
      create: "CREATE TABLE #{TABLE} (id INTEGER AUTO_INCREMENT PRIMARY KEY, body VARCHAR(40) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}",
      returning: nil,
      cte: "WITH picked AS (SELECT id, body FROM #{TABLE} WHERE body = ?) SELECT id, body FROM picked"
    },
    "MSSQL" => {
      skip: lambda {
        if !gem?("tiny_tds") then "tiny_tds gem not installed - MSSQL not reachable"
        elsif !reachable?(MSSQL_HOST, MSSQL_PORT) then "MSSQL not reachable at #{MSSQL_HOST}:#{MSSQL_PORT}"
        end
      },
      connect: lambda {
        Tina4::Database.new("mssql://#{MSSQL_HOST}:#{MSSQL_PORT}/#{ENV.fetch('TINA4_TEST_MSSQL_DB', 'tina4_test')}",
                            username: ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa"),
                            password: ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure"))
      },
      create: "CREATE TABLE #{TABLE} (id INT IDENTITY(1,1) PRIMARY KEY, body VARCHAR(40) NOT NULL)",
      drop: "IF OBJECT_ID('#{TABLE}', 'U') IS NOT NULL DROP TABLE #{TABLE}",
      returning: "INSERT INTO #{TABLE} (body) OUTPUT inserted.id VALUES (?)",
      cte: "WITH picked AS (SELECT id, body FROM #{TABLE} WHERE body = ?) SELECT id, body FROM picked"
    },
    "SQLite" => {
      skip: -> { nil },
      connect: -> { Tina4::Database.new("sqlite:///#{ExecuteRowsSpec.sqlite_path}") },
      create: "CREATE TABLE #{TABLE} (id INTEGER PRIMARY KEY AUTOINCREMENT, body VARCHAR(40) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}",
      returning: "INSERT INTO #{TABLE} (body) VALUES (?) RETURNING id",
      cte: "WITH picked AS (SELECT id, body FROM #{TABLE} WHERE body = ?) SELECT id, body FROM picked"
    },
    "Firebird" => {
      skip: lambda {
        if FB_URL.empty? then "TINA4_TEST_FIREBIRD_URL not set - firebird case skipped"
        elsif !gem?("fb") then "fb gem not installed - firebird case skipped"
        else
          uri = URI.parse(FB_URL)
          "firebird not reachable at #{FB_URL}" unless reachable?(uri.host, uri.port || 3050)
        end
      },
      connect: lambda {
        Tina4::Database.new(FB_URL, username: ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA"),
                                    password: ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey"))
      },
      create: "CREATE TABLE #{TABLE} (id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, " \
              "body VARCHAR(40) NOT NULL)",
      drop: "DROP TABLE #{TABLE}",
      returning: "INSERT INTO #{TABLE} (body) SELECT CAST(? AS VARCHAR(40)) FROM RDB$DATABASE RETURNING id",
      cte: "WITH picked AS (SELECT id, body FROM #{TABLE} WHERE body = ?) SELECT id, body FROM picked"
    },
    "ODBC" => {
      skip: lambda {
        if ODBC_DSN.empty? then "TINA4_TEST_ODBC_DSN not set - odbc case skipped"
        elsif !gem?("odbc") then "ruby-odbc gem not installed - odbc case skipped"
        end
      },
      connect: -> { Tina4::Database.new("odbc:///#{ODBC_DSN}") },
      create: "CREATE TABLE #{TABLE} (id SERIAL PRIMARY KEY, body VARCHAR(40) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}",
      returning: "INSERT INTO #{TABLE} (body) VALUES (?) RETURNING id",
      cte: "WITH picked AS (SELECT id, body FROM #{TABLE} WHERE body = ?) SELECT id, body FROM picked"
    }
  }.freeze
end

RSpec.describe "Database#execute returns the rows of a statement that produces them" do
  ExecuteRowsSpec::ENGINES.each do |engine, cfg|
    context engine, firebird_watchdog: engine == "Firebird" do
      before(:all) { @skip_reason = cfg[:skip].call }

      before(:each) do
        skip(@skip_reason) if @skip_reason
        @db = cfg[:connect].call
        begin
          @db.execute(cfg[:drop])
        rescue StandardError
          nil
        end
        @db.execute(cfg[:create])
        %w[alpha beta alpha].each { |body| @db.execute("INSERT INTO #{ExecuteRowsSpec::TABLE} (body) VALUES (?)", [body]) }
      end

      after(:each) do
        next unless @db

        begin
          @db.rollback rescue nil
          @db.execute(cfg[:drop])
        rescue StandardError
          nil
        ensure
          @db.close rescue nil
        end
      end

      def fresh_count(cfg)
        other = cfg[:connect].call
        ExecuteRowsSpec.value(other.fetch_one("SELECT COUNT(*) AS n FROM #{ExecuteRowsSpec::TABLE}", [],
                                              no_cache: true), :n).to_i
      ensure
        other&.close rescue nil
      end

      def ids(result)
        result.records.map { |row| ExecuteRowsSpec.value(row, :id).to_i }
      end

      it "execute(SELECT with a param) returns the same rows, in the same type, as fetch" do
        sql = "SELECT id, body FROM #{ExecuteRowsSpec::TABLE} WHERE body = ? ORDER BY id"
        executed = @db.execute(sql, ["alpha"])
        fetched = @db.fetch(sql, ["alpha"], no_cache: true)
        expect(executed).to be_a(Tina4::DatabaseResult)
        expect(executed.class).to eq(fetched.class)
        expect(ids(executed)).to eq(ids(fetched))
        expect(ids(executed).length).to eq(2)
      end

      it "execute(WITH ... SELECT) returns its rows" do
        result = @db.execute(cfg[:cte], ["beta"])
        expect(result).to be_a(Tina4::DatabaseResult)
        expect(result.records.map { |row| ExecuteRowsSpec.value(row, :body).to_s.strip }).to eq(["beta"])
      end

      # MySQL has no RETURNING/OUTPUT, so there is no such statement to run.
      if cfg[:returning]
      it "execute(INSERT ... RETURNING id) returns the id AND the table holds exactly one new row" do
        result = @db.execute(cfg[:returning], ["gamma"])
        expect(result).to be_a(Tina4::DatabaseResult)
        expect(ids(result).length).to eq(1)
        expect(ids(result).first).to be > 0
        expect(fresh_count(cfg)).to eq(4) # the three seeded rows + exactly one
      end
      end

      it "execute(UPDATE without RETURNING) keeps its return value (true) and commits" do
        expect(@db.execute("UPDATE #{ExecuteRowsSpec::TABLE} SET body = ? WHERE body = ?", %w[delta beta])).to be(true)
        other = cfg[:connect].call
        begin
          row = other.fetch_one("SELECT COUNT(*) AS n FROM #{ExecuteRowsSpec::TABLE} WHERE body = ?", ["delta"],
                                no_cache: true)
          expect(ExecuteRowsSpec.value(row, :n).to_i).to eq(1)
        ensure
          other.close rescue nil
        end
      end

      if engine == "PostgreSQL"
        it "a read through execute leaves no idle-in-transaction connection (pg_stat_activity)" do
          @db.execute("SELECT id FROM #{ExecuteRowsSpec::TABLE} WHERE body = ?", ["alpha"])
          pid = ExecuteRowsSpec.value(@db.fetch_one("SELECT pg_backend_pid() AS pid", [], no_cache: true), :pid)
          observer = cfg[:connect].call
          begin
            row = observer.fetch_one("SELECT state FROM pg_stat_activity WHERE pid = ?", [pid], no_cache: true)
            expect(ExecuteRowsSpec.value(row, :state)).to eq("idle")
          ensure
            observer.close rescue nil
          end
        end
      end
    end
  end
end
