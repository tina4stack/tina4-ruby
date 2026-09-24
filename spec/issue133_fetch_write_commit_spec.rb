# frozen_string_literal: true
#
# Issue #133 parity (tina4-python #133): a statement that WRITES and returns
# rows (INSERT/UPDATE/DELETE ... RETURNING, MSSQL OUTPUT) run through
# Database#fetch_one / #fetch OUTSIDE an explicit transaction must be COMMITTED
# like #execute - never handed back to the caller and then rolled back. The
# Python master closed fetch/fetch_one with a ROLLBACK, so the caller got the id
# of a row that no longer existed.
#
# Every example proves durability from a SECOND, FRESH connection, because the
# connection that ran the write can always see its own uncommitted work.
#
# The fetch (paginated) path also used to append the pagination clause to the
# write ("INSERT ... RETURNING id\nLIMIT 100 OFFSET 0"), which is a syntax error
# on Postgres/SQLite/Firebird, so db.fetch of a RETURNING write could not run at
# all. A write is never paginated now.
#
# Real engines only - NO mocks. Postgres/MSSQL are provisioned services (the
# TINA4_REQUIRE_SERVICES gate turns their skip into a failure); SQLite needs
# nothing. MySQL has no RETURNING/OUTPUT, so no write can return rows there.
# Firebird is NOT a case: the `fb` gem cannot fetch a RETURNING row at all
# (Fb::Cursor#fetch raises "Cursor is not open", measured on the lab's
# Firebird 5), so the statement fails LOUD there - it never hands back an id.

require "spec_helper"
require_relative "support/live_postgres"
require "socket"
require "uri"

module Issue133Spec
  TABLE = "issue133_rb_note"

  PG_URL = ENV["TINA4_TEST_PG_URL"] ||
           LivePostgres.url
  PG_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  PG_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")

  MSSQL_HOST = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
  MSSQL_PORT = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  MSSQL_USER = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
  MSSQL_PASS = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
  MSSQL_DB   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

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

  # Each engine: how to connect, the DDL, and the write-returning statements.
  ENGINES = {
    "PostgreSQL" => {
      skip: lambda {
        uri = URI.parse(PG_URL)
        if !gem?("pg") then "[needs:postgres] pg gem not installed - PostgreSQL not reachable"
        elsif !reachable?(uri.host, uri.port || 5432) then "[needs:postgres] PostgreSQL not reachable at #{PG_URL}"
        end
      },
      connect: -> { Tina4::Database.new(PG_URL, username: PG_USER, password: PG_PASS) },
      create: "CREATE TABLE #{TABLE} (id SERIAL PRIMARY KEY, body VARCHAR(100) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}",
      insert: "INSERT INTO #{TABLE} (body) VALUES (?) RETURNING id",
      update: "UPDATE #{TABLE} SET body = ? WHERE id = ? RETURNING id",
      delete: "DELETE FROM #{TABLE} WHERE id = ? RETURNING id"
    },
    "SQLite" => {
      skip: -> { nil },
      connect: -> { Tina4::Database.new("sqlite:///#{Issue133Spec.sqlite_path}") },
      create: "CREATE TABLE #{TABLE} (id INTEGER PRIMARY KEY AUTOINCREMENT, body VARCHAR(100) NOT NULL)",
      drop: "DROP TABLE IF EXISTS #{TABLE}",
      insert: "INSERT INTO #{TABLE} (body) VALUES (?) RETURNING id",
      update: "UPDATE #{TABLE} SET body = ? WHERE id = ? RETURNING id",
      delete: "DELETE FROM #{TABLE} WHERE id = ? RETURNING id"
    },
    "MSSQL" => {
      skip: lambda {
        if !gem?("tiny_tds") then "[needs:mssql] tiny_tds gem not installed - MSSQL not reachable"
        elsif !reachable?(MSSQL_HOST, MSSQL_PORT) then "[needs:mssql] MSSQL not reachable at #{MSSQL_HOST}:#{MSSQL_PORT}"
        end
      },
      connect: lambda {
        Tina4::Database.new("mssql://#{MSSQL_HOST}:#{MSSQL_PORT}/#{MSSQL_DB}",
                            username: MSSQL_USER, password: MSSQL_PASS)
      },
      create: "CREATE TABLE #{TABLE} (id INT IDENTITY(1,1) PRIMARY KEY, body VARCHAR(100) NOT NULL)",
      drop: "IF OBJECT_ID('#{TABLE}', 'U') IS NOT NULL DROP TABLE #{TABLE}",
      insert: "INSERT INTO #{TABLE} (body) OUTPUT inserted.id VALUES (?)",
      update: "UPDATE #{TABLE} SET body = ? OUTPUT inserted.id WHERE id = ?",
      delete: "DELETE FROM #{TABLE} OUTPUT deleted.id WHERE id = ?"
    }
  }.freeze

  def self.sqlite_path
    @sqlite_path ||= File.join(Dir.mktmpdir("issue133_rb"), "issue133.db")
  end

  def self.id_of(row)
    row[:id] || row["id"] || row[:ID] || row["ID"]
  end
end

RSpec.describe "Issue #133: a write run through fetch/fetch_one is committed, not rolled back" do
  Issue133Spec::ENGINES.each do |engine, cfg|
    context engine do
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
        @db.commit rescue nil
      end

      after(:each) do
        next unless @db

        begin
          @db.rollback rescue nil
          @db.execute(cfg[:drop])
          @db.commit rescue nil
        rescue StandardError
          nil
        ensure
          @db.close rescue nil
        end
      end

      # A SECOND connection: it can only see what was committed.
      def fresh_rows(cfg)
        other = cfg[:connect].call
        other.fetch_all("SELECT id, body FROM #{Issue133Spec::TABLE} ORDER BY id", [], no_cache: true)
      ensure
        other&.close rescue nil
      end

      # EXACTLY-ONCE: the table must hold exactly one row afterwards, counted
      # through a fresh connection. PHP's SQLite driver ran every write twice
      # through fetch (once for the COUNT probe), which "the row exists" cannot
      # catch.
      def fresh_count(cfg)
        other = cfg[:connect].call
        row = other.fetch_one("SELECT COUNT(*) AS n FROM #{Issue133Spec::TABLE}", [], no_cache: true)
        (row[:n] || row["n"] || row[:N] || row["N"]).to_i
      ensure
        other&.close rescue nil
      end

      it "fetch_one(INSERT ... RETURNING) returns the new id AND exactly one row persists" do
        row = @db.fetch_one(cfg[:insert], ["written with fetch_one"], no_cache: true)
        new_id = Issue133Spec.id_of(row)
        expect(new_id).not_to be_nil

        expect(fresh_count(cfg)).to eq(1)
        expect(fresh_rows(cfg).map { |r| Issue133Spec.id_of(r).to_i }).to eq([new_id.to_i])
      end

      it "fetch(INSERT ... RETURNING) returns the new id AND exactly one row persists" do
        result = @db.fetch(cfg[:insert], ["written with fetch"], no_cache: true)
        ids = result.records.map { |r| Issue133Spec.id_of(r).to_i }
        expect(ids.length).to eq(1)

        expect(fresh_count(cfg)).to eq(1)
        expect(fresh_rows(cfg).map { |r| Issue133Spec.id_of(r).to_i }).to eq(ids)
      end

      it "the same RETURNING write twice with the query cache ON writes exactly two rows (never cached)" do
        saved = ENV["TINA4_AUTO_CACHING"]
        ENV["TINA4_AUTO_CACHING"] = "true"
        cached = cfg[:connect].call
        begin
          first = Issue133Spec.id_of(cached.fetch_one(cfg[:insert], ["same"]))
          second = Issue133Spec.id_of(cached.fetch(cfg[:insert], ["same"]).records.first)
          third = Issue133Spec.id_of(cached.fetch_one(cfg[:insert], ["same"]))
          expect([first, second, third].map(&:to_i).uniq.length).to eq(3),
                                                                  "a repeated write was answered from the query cache"
        ensure
          cached.close rescue nil
          saved.nil? ? ENV.delete("TINA4_AUTO_CACHING") : ENV["TINA4_AUTO_CACHING"] = saved
        end
        expect(fresh_count(cfg)).to eq(3)
      end

      it "fetch_one(UPDATE ... RETURNING) and fetch_one(DELETE ... RETURNING) are both durable" do
        @db.execute("INSERT INTO #{Issue133Spec::TABLE} (body) VALUES (?)", ["original"])
        id = Issue133Spec.id_of(fresh_rows(cfg).first).to_i

        updated = @db.fetch_one(cfg[:update], ["changed", id], no_cache: true)
        expect(Issue133Spec.id_of(updated).to_i).to eq(id)
        expect(fresh_count(cfg)).to eq(1)
        expect(fresh_rows(cfg).map { |r| (r[:body] || r["body"]).to_s.strip }).to eq(["changed"])

        deleted = @db.fetch_one(cfg[:delete], [id], no_cache: true)
        expect(Issue133Spec.id_of(deleted).to_i).to eq(id)
        expect(fresh_count(cfg)).to eq(0)
      end

      it "inside an explicit transaction a fetch_one write is NOT committed early - rollback undoes it" do
        @db.start_transaction
        row = @db.fetch_one(cfg[:insert], ["in a transaction"], no_cache: true)
        expect(Issue133Spec.id_of(row)).not_to be_nil
        @db.rollback

        expect(fresh_rows(cfg)).to be_empty
      end

      it "a plain read through fetch/fetch_one is unaffected" do
        @db.execute("INSERT INTO #{Issue133Spec::TABLE} (body) VALUES (?)", ["read me"])
        expect((@db.fetch_one("SELECT body FROM #{Issue133Spec::TABLE}", [], no_cache: true) || {})
                 .then { |r| (r[:body] || r["body"]).to_s.strip }).to eq("read me")
        expect(@db.fetch("SELECT body FROM #{Issue133Spec::TABLE}", [], no_cache: true).records.length).to eq(1)
      end
    end
  end
end

RSpec.describe "Issue #133: Tina4::Database.write_statement? (the cross-framework classification table)" do
  # The same table the Python (test_write_statement_classification) and Node
  # suites assert, plus the MSSQL/MERGE forms Ruby's drivers accept.
  {
    "SELECT * FROM t" => false,
    "INSERT INTO t (a) VALUES (1) RETURNING id" => true,
    "UPDATE t SET a = 1 WHERE id = 2 RETURNING id" => true,
    "DELETE FROM t WHERE id = 1 RETURNING id" => true,
    "WITH gone AS (DELETE FROM t RETURNING id) SELECT count(*) FROM gone" => true,
    "WITH recent AS (SELECT id FROM t) SELECT * FROM recent" => false,
    "SELECT * FROM t WHERE x = 'DELETE'" => false,
    "SELECT * FROM t WHERE note = 'INSERT INTO x'" => false,
    "SELECT id FROM t -- UPDATE later" => false,
    "  -- a leading comment\n update t SET a = 1 RETURNING a" => true,
    "/* block */ DELETE FROM t RETURNING id" => true,
    "(INSERT INTO t (a) VALUES (1) RETURNING id)" => true,
    "SELECT replace(name, 'a', 'b') AS updated FROM t" => false,
    "SELECT id, updated_at FROM t FOR UPDATE" => false,
    "INSERT INTO t (a) OUTPUT inserted.id VALUES (?)" => true,
    "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a" => true,
    "upsert into t (a) values (1)" => true,
    "REPLACE INTO t (a) VALUES (1)" => true,
    "" => false
  }.each do |sql, expected|
    it "#{sql.inspect} is #{expected ? 'a write' : 'a read'}" do
      expect(Tina4::Database.write_statement?(sql)).to be(expected)
    end
  end
end
