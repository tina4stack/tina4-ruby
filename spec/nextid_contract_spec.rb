# frozen_string_literal: true

# Race-safe get_next_id contract - feature 16 (nextid_contract.json), parity
# with tina4-python/tests/test_nextid_contract.py.
#
# Two duplicate-id bugs locked out against REAL databases with REAL concurrency
# (native threads, each its own connection - no mocks):
#
#   * NEXTID-GENERIC-TOCTOU + NEXTID-PG-FIRSTUSE: the generic sequence fallback
#     did an UPDATE then a SEPARATE SELECT (two concurrent callers read the same
#     post-increment value -> DUPLICATE id), and the PostgreSQL first-use path
#     let two concurrent first-callers each CREATE a separate sequence so the
#     loser drew a duplicate from a second counter. Fixed: a single atomic
#     UPDATE ... RETURNING, and CREATE SEQUENCE IF NOT EXISTS + always-draw-from
#     nextval so every caller shares ONE counter.
#
#   * NEXTID-MONGO-BROKEN: Ruby had NO Mongo path (a Mongo DB fell to the
#     relational generic path, inapplicable). It now has a DEDICATED atomic
#     findOneAndUpdate($inc) counter keyed by _id, monotonic and
#     concurrency-safe.
#
# Real services on the .99 lab: PostgreSQL :55432 (tina4/tina4 -> tina4_rb),
# MySQL :3306 (tina4/tina4 -> tina4_test), MongoDB :27017. Real skips (never a
# `describe ..., if:` that DROPS examples) so TINA4_REQUIRE_SERVICES catches a
# service that silently went missing. Constants carry a file-unique _NIC suffix
# so they never clobber another spec's globals.
#
# Mutation-proof: revert the fallback to UPDATE-then-separate-SELECT and the
# generic-concurrency example goes RED (a duplicate id); drop the $inc from the
# Mongo path and the monotonic example goes RED (id2 == id1).

require "spec_helper"
require "socket"
require "securerandom"

RSpec.describe "Race-safe get_next_id contract (feature 16)" do
  CONCURRENCY_NIC = 24

  PG_HOST_NIC = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  PG_PORT_NIC = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  PG_USER_NIC = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  PG_PASS_NIC = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  PG_DB_NIC   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  MYSQL_HOST_NIC = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  MYSQL_PORT_NIC = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  MYSQL_USER_NIC = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
  MYSQL_PASS_NIC = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  MYSQL_DB_NIC   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")

  MONGO_URI_NIC = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017")
  MONGO_DB_NIC  = "tina4_nextid_rb"

  def self.tcp_reachable?(host, port)
    TCPSocket.new(host, port).tap(&:close)
    true
  rescue StandardError
    false
  end

  def self.mongo_reachable?
    require "mongo"
    Mongo::Logger.logger.level = Logger::FATAL
    client = Mongo::Client.new(MONGO_URI_NIC, server_selection_timeout: 3)
    client.database.command(ping: 1)
    client.close
    true
  rescue StandardError, LoadError
    false
  end

  PG_REACHABLE_NIC    = tcp_reachable?(PG_HOST_NIC, PG_PORT_NIC)
  MYSQL_REACHABLE_NIC = tcp_reachable?(MYSQL_HOST_NIC, MYSQL_PORT_NIC)
  MONGO_REACHABLE_NIC = mongo_reachable?

  def pg_url
    "postgres://#{PG_HOST_NIC}:#{PG_PORT_NIC}/#{PG_DB_NIC}"
  end

  def mysql_url
    "mysql://#{MYSQL_HOST_NIC}:#{MYSQL_PORT_NIC}/#{MYSQL_DB_NIC}"
  end

  def mongo_url_with_db
    scheme, rest = MONGO_URI_NIC.split("://", 2)
    query = rest.include?("?") ? "?#{rest.split('?', 2)[1]}" : ""
    host = rest.split("?", 2)[0].split("/", 2)[0]
    "#{scheme}://#{host}/#{MONGO_DB_NIC}#{query}"
  end

  def new_pg
    Tina4::Database.new(pg_url, username: PG_USER_NIC, password: PG_PASS_NIC)
  end

  def new_mysql
    Tina4::Database.new(mysql_url, username: MYSQL_USER_NIC, password: MYSQL_PASS_NIC)
  end

  # A simple N-thread barrier so every worker is released together and the race
  # window is as wide as possible (makes the pre-fix duplicate reliably appear).
  class Barrier
    def initialize(count)
      @count = count
      @waiting = 0
      @mutex = Mutex.new
      @cond = ConditionVariable.new
    end

    def wait
      @mutex.synchronize do
        @waiting += 1
        if @waiting >= @count
          @cond.broadcast
        else
          @cond.wait(@mutex, 15)
        end
      end
    end
  end

  # Run make_id.call on n threads released together; returns [ids, errors].
  def hammer(n, &make_id)
    barrier = Barrier.new(n)
    mutex = Mutex.new
    ids = []
    errors = []
    threads = Array.new(n) do
      Thread.new do
        begin
          barrier.wait
          value = make_id.call
          mutex.synchronize { ids << value }
        rescue StandardError => e
          mutex.synchronize { errors << e.message }
        end
      end
    end
    threads.each(&:join)
    [ids, errors]
  end

  # ── PostgreSQL: public first-use + the direct generic fallback ──────────────

  describe "PostgreSQL" do
    before do
      skip "no reachable postgres at #{PG_HOST_NIC}:#{PG_PORT_NIC} (set TINA4_TEST_PG_*)" unless PG_REACHABLE_NIC
    end

    it "concurrent get next id on a fresh table yields distinct ids" do
      table = "nextid_fresh_#{SecureRandom.hex(5)}"
      admin = new_pg
      begin
        admin.execute("DROP TABLE IF EXISTS #{table}")
        admin.execute("DROP SEQUENCE IF EXISTS #{table}_id_seq")
        admin.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, v VARCHAR(20))")
        admin.close

        ids, errors = hammer(CONCURRENCY_NIC) do
          db = new_pg
          begin
            db.get_next_id(table)
          ensure
            db.close
          end
        end

        expect(errors).to eq([]), "get_next_id raised under concurrency: #{errors.first(3)}"
        expect(ids.length).to eq(CONCURRENCY_NIC)
        expect(ids.uniq.length).to eq(CONCURRENCY_NIC), "DUPLICATE ids under concurrency: #{ids.sort}"
      ensure
        cleanup = new_pg
        cleanup.execute("DROP TABLE IF EXISTS #{table}") rescue nil
        cleanup.execute("DROP SEQUENCE IF EXISTS #{table}_id_seq") rescue nil
        cleanup.close
      end
    end

    it "concurrent generic sequence next id yields distinct ids" do
      seq = "gen.#{SecureRandom.hex(5)}"
      admin = new_pg
      begin
        # Seed the tina4_sequences row once so every worker hits the atomic
        # increment (isolating the TOCTOU). On postgres, sequence_next routes to
        # the generic fallback.
        admin.send(:sequence_next, seq, table: nil, pk_column: "id")
        admin.close

        ids, errors = hammer(CONCURRENCY_NIC) do
          db = new_pg
          begin
            db.send(:sequence_next, seq, table: nil, pk_column: "id")
          ensure
            db.close
          end
        end

        expect(errors).to eq([]), "generic next-id raised under concurrency: #{errors.first(3)}"
        expect(ids.length).to eq(CONCURRENCY_NIC)
        expect(ids.uniq.length).to eq(CONCURRENCY_NIC),
                                   "DUPLICATE ids from the generic fallback under concurrency: #{ids.sort}"
      ensure
        cleanup = new_pg
        cleanup.execute("DELETE FROM tina4_sequences WHERE seq_name = ?", [seq]) rescue nil
        cleanup.close
      end
    end
  end

  # ── MySQL: the tina4_sequences LAST_INSERT_ID path under real concurrency ────

  describe "MySQL" do
    before do
      skip "no reachable mysql at #{MYSQL_HOST_NIC}:#{MYSQL_PORT_NIC} (set TINA4_TEST_MYSQL_*)" unless MYSQL_REACHABLE_NIC
    end

    it "concurrent get next id on mysql yields distinct ids" do
      table = "nextid_my_#{SecureRandom.hex(4)}"
      admin = new_mysql
      begin
        admin.execute("DROP TABLE IF EXISTS #{table}")
        admin.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, v VARCHAR(20))")
        admin.get_next_id(table) # pre-create tina4_sequences + the row
        admin.close

        ids, errors = hammer(CONCURRENCY_NIC) do
          db = new_mysql
          begin
            db.get_next_id(table)
          ensure
            db.close
          end
        end

        expect(errors).to eq([]), "get_next_id raised under concurrency: #{errors.first(3)}"
        expect(ids.length).to eq(CONCURRENCY_NIC)
        expect(ids.uniq.length).to eq(CONCURRENCY_NIC), "DUPLICATE ids under concurrency (mysql): #{ids.sort}"
      ensure
        cleanup = new_mysql
        cleanup.execute("DELETE FROM tina4_sequences WHERE seq_name = ?", ["#{table}.id"]) rescue nil
        cleanup.execute("DROP TABLE IF EXISTS #{table}") rescue nil
        cleanup.close
      end
    end
  end

  # ── MongoDB: the dedicated atomic findOneAndUpdate($inc) counter ────────────

  describe "MongoDB" do
    before do
      skip "no reachable mongodb at #{MONGO_URI_NIC} (set TINA4_TEST_MONGO_URI)" unless MONGO_REACHABLE_NIC
    end

    it "mongo next id increments monotonically" do
      db = Tina4::Database.new(mongo_url_with_db)
      table = "mono_#{SecureRandom.hex(5)}"
      begin
        id1 = db.get_next_id(table)
        id2 = db.get_next_id(table)
        id3 = db.get_next_id(table)
        expect(id2).to be > id1, "mongo next-id did not advance: id1=#{id1} id2=#{id2}"
        expect(id3).to be > id2, "mongo next-id did not advance: id2=#{id2} id3=#{id3}"
        expect([id1, id2, id3].uniq.length).to eq(3)
      ensure
        db.execute("DROP TABLE #{table}") rescue nil
        db.close
      end
    end

    it "concurrent mongo next id yields distinct ids" do
      db = Tina4::Database.new(mongo_url_with_db)
      table = "conc_#{SecureRandom.hex(5)}"
      begin
        db.get_next_id(table) # seed the counter once

        ids, errors = hammer(CONCURRENCY_NIC) { db.get_next_id(table) }

        expect(errors).to eq([]), "mongo get_next_id raised under concurrency: #{errors.first(3)}"
        expect(ids.length).to eq(CONCURRENCY_NIC)
        expect(ids.uniq.length).to eq(CONCURRENCY_NIC), "DUPLICATE ids under concurrency (mongo): #{ids.sort}"
      ensure
        db.execute("DROP TABLE #{table}") rescue nil
        db.close
      end
    end
  end
end
