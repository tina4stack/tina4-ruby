# frozen_string_literal: true
#
# -- SESSION CONTRACT: the database backend works on every engine it claims ----
#
# session_contract.json invariant 5 (ADR-0024):
#   "A backend that advertises support for an engine works on that engine. The
#    database session backend works on every engine the Database layer
#    supports, not a subset."
#
# THIS IS A PARITY LOCK-IN, NOT A BUG FIX. Node was the framework that failed
# this: its DatabaseSessionHandler resolved a session file path itself and THREW
# on any non-sqlite TINA4_DATABASE_URL, so you developed on sqlite, deployed on
# postgres, and the app did not start - in the subsystem that decides whether
# anyone is logged in. ADR-0028 records the fix AND the wrong premise that
# nearly froze it; read it before changing anything here.
#
# Ruby was EXPECTED to pass at HEAD, and does. It never grew Node's defect
# because DatabaseHandler owns no path resolution at all: it takes an injected
# Tina4::Database, or builds one from TINA4_DATABASE_URL on FIRST USE
# (database_handler.rb#db), so whatever engine the Database layer supports the
# session backend supports for free. That is the design this file pins, so a
# future "optimisation" that special-cases sqlite cannot land quietly.
#
# WHAT THE REFUSAL LOOKS LIKE IN RUBY, and where it comes from. Ruby refuses an
# unsupported engine EARLIER in the stack than Node does and LATER in time:
#   * EARLIER in the stack - the refusal is not in the session handler. It is
#     Tina4::DatabaseUrl#parse_standard raising ArgumentError on a scheme that
#     is not in ENGINE_ALIASES, reached through Tina4::Database#detect_driver.
#     The session backend inherits the guarantee instead of re-implementing it,
#     which is exactly why it never had Node's bug.
#   * LATER in time - it fires on FIRST USE, not at construction, because
#     invariant 4 / ADR-0021 forbids network I/O in a handler constructor.
#     Constructing the handler against a garbage URL is silent by design; the
#     write is what refuses.
#
# NO MOCKS. Real PostgreSQL 16, real MySQL 8, real SQLite files. Every round
# trip is re-read OUT OF BAND through a connection this spec owns, opened with
# the ENGINE'S OWN CLIENT GEM (sqlite3 / pg / mysql2) rather than through
# Tina4 - so a handler that silently demoted to a local file could not fake a
# pass, because the row would not be on the real server.
#
# THE TWO CASES, and why each is load-bearing:
#   1. every engine it claims - a real write, a read back through a FRESH
#      handler, and the row proved present in THAT engine's tina4_session table
#      by an independent client. FAILS (never skips) if fewer than three
#      engines really ran: one engine passing is not the invariant.
#   2. an unsupported engine refuses BY NAME - a genuinely unknown scheme must
#      raise, and the message must name the scheme it got. Without case 2,
#      "delete the guard and let anything through" passes case 1 and ships; and
#      without the by-name assertion an operator cannot tell a typo from an
#      unsupported engine.

require "spec_helper"
require "tina4"
require "json"
require "socket"
require "tmpdir"
require "fileutils"
require "securerandom"
require_relative "support/real_env"

RSpec.describe "Session database backend across engines" do
  # LOCALS, never constants. A bare constant assigned inside RSpec.describe is
  # defined on Object and is therefore GLOBAL - it has clobbered other spec
  # files in this repo before (see spec_helper.rb:17-35).
  pg_host = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
  pg_port = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  pg_user = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  pg_pass = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  pg_db   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

  mysql_host = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
  mysql_port = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  mysql_user = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "root")
  mysql_pass = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  mysql_db   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4")

  session_table = Tina4::SessionHandlers::DatabaseHandler::TABLE_NAME

  # A real TCP probe, used only to say WHICH engine is down in the failure
  # message. It never produces a skip: under TINA4_REQUIRE_SERVICES an
  # unreachable engine must be a hard failure, and a run with skips is not
  # verification either way, so an unreachable engine simply fails case 1.
  reachable = lambda do |host, port|
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  # ---- Out-of-band readers -------------------------------------------------
  # Each opens the engine's OWN client, reads the row the handler claims to have
  # written, and closes. Nothing here goes through Tina4, so the assertion is
  # independent of the code under test.
  read_out_of_band_sqlite = lambda do |db_path, session_id|
    require "sqlite3"
    connection = SQLite3::Database.new(db_path)
    begin
      connection.get_first_value(
        "SELECT data FROM #{session_table} WHERE session_id = ?", [session_id]
      )
    ensure
      connection.close
    end
  end

  open_out_of_band_postgres = lambda do
    require "pg"
    PG.connect(host: pg_host, port: pg_port, user: pg_user, password: pg_pass, dbname: pg_db)
  end

  read_out_of_band_postgres = lambda do |session_id|
    connection = open_out_of_band_postgres.call
    begin
      result = connection.exec_params(
        "SELECT data FROM #{session_table} WHERE session_id = $1", [session_id]
      )
      result.ntuples.zero? ? nil : result[0]["data"]
    ensure
      connection.close
    end
  end

  open_out_of_band_mysql = lambda do
    require "mysql2"
    Mysql2::Client.new(host: mysql_host, port: mysql_port, username: mysql_user,
                       password: mysql_pass, database: mysql_db)
  end

  read_out_of_band_mysql = lambda do |session_id|
    connection = open_out_of_band_mysql.call
    begin
      row = connection.prepare(
        "SELECT data FROM #{session_table} WHERE session_id = ?"
      ).execute(session_id).first
      row && (row["data"] || row[:data])
    ensure
      connection.close
    end
  end

  # ---- Cleanup -------------------------------------------------------------
  # Every row this spec writes is deleted. The table is dropped only when this
  # spec created it, so a pre-existing tina4_session belonging to another spec
  # or to the lab database is left exactly as found.
  postgres_table_exists = lambda do
    connection = open_out_of_band_postgres.call
    begin
      !connection.exec("SELECT to_regclass('#{session_table}') AS present")[0]["present"].nil?
    ensure
      connection.close
    end
  end

  mysql_table_exists = lambda do
    connection = open_out_of_band_mysql.call
    begin
      connection.query("SHOW TABLES LIKE '#{session_table}'").count.positive?
    ensure
      connection.close
    end
  end

  clean_up_postgres = lambda do |session_ids, drop_table|
    connection = open_out_of_band_postgres.call
    begin
      session_ids.each do |session_id|
        connection.exec_params("DELETE FROM #{session_table} WHERE session_id = $1", [session_id])
      end
      connection.exec("DROP TABLE IF EXISTS #{session_table}") if drop_table
    ensure
      connection.close
    end
  end

  clean_up_mysql = lambda do |session_ids, drop_table|
    connection = open_out_of_band_mysql.call
    begin
      session_ids.each do |session_id|
        connection.prepare("DELETE FROM #{session_table} WHERE session_id = ?").execute(session_id)
      end
      connection.query("DROP TABLE IF EXISTS #{session_table}") if drop_table
    ensure
      connection.close
    end
  end

  # A handler builds its OWN Tina4::Database on first use, so every handler this
  # spec constructs holds a real connection. Close what we opened - a leaked
  # pool has already broken docstore_substitutability_spec's connection-count
  # gate on this task, and that gate is order-dependent, so it fails on a seed
  # rather than every run.
  close_handler = lambda do |handler|
    handler&.instance_variable_get(:@db)&.close
  rescue StandardError
    nil
  end

  let(:work_dir) { Dir.mktmpdir("tina4-session-engines") }

  after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

  it "the_database_session_backend_works_on_every_engine_it_claims" do
    sqlite_path = File.join(work_dir, "engines.db")

    engines = [
      { name: "sqlite",
        # "sqlite:" + an ABSOLUTE path. NOT "sqlite://#{path}" - that yields
        # three slashes, which is the documented RELATIVE form, so the file
        # would be created under the repo working directory instead of the temp
        # dir (the footgun that leaves stray ./var/folders/... trees behind).
        url: "sqlite:#{sqlite_path}",
        up: -> { true },
        read_back: ->(session_id) { read_out_of_band_sqlite.call(sqlite_path, session_id) } },
      { name: "postgres",
        url: "postgres://#{pg_user}:#{pg_pass}@#{pg_host}:#{pg_port}/#{pg_db}",
        up: -> { reachable.call(pg_host, pg_port) },
        read_back: read_out_of_band_postgres },
      { name: "mysql",
        url: "mysql://#{mysql_user}:#{mysql_pass}@#{mysql_host}:#{mysql_port}/#{mysql_db}",
        up: -> { reachable.call(mysql_host, mysql_port) },
        read_back: read_out_of_band_mysql }
    ]

    # Remember what we found so cleanup can put it back exactly. On any doubt
    # assume the table was already there: never DROP something we cannot prove
    # this spec created. A failure to probe is not swallowed - the engine loop
    # below hits the same client and reports it as a broken engine.
    postgres_had_table = begin
      engines.find { |e| e[:name] == "postgres" }[:up].call ? postgres_table_exists.call : true
    rescue StandardError
      true
    end
    mysql_had_table = begin
      engines.find { |e| e[:name] == "mysql" }[:up].call ? mysql_table_exists.call : true
    rescue StandardError
      true
    end

    ran = []
    broken = []
    written_session_ids = []

    begin
      engines.each do |engine|
        session_id = "engine-#{engine[:name]}-#{SecureRandom.hex(4)}"
        payload = { "seeded" => true, "engine" => engine[:name] }
        writer = nil
        reader = nil

        begin
          unless engine[:up].call
            broken << "#{engine[:name]} (not reachable)"
            next
          end

          written_session_ids << session_id

          # The handler follows the CONFIGURED connection - no injected :db, no
          # per-engine branch in the test, exactly as an app configures it.
          # Clear the credential env vars so the URL is the only source of
          # truth; TINA4_DATABASE_USERNAME would otherwise override it.
          set_real_env("TINA4_DATABASE_URL" => engine[:url],
                       "TINA4_DATABASE_USERNAME" => nil,
                       "TINA4_DATABASE_PASSWORD" => nil)

          writer = Tina4::SessionHandlers::DatabaseHandler.new
          writer.write(session_id, payload, 60)

          # A FRESH handler, so nothing in-process can answer from memory.
          reader = Tina4::SessionHandlers::DatabaseHandler.new
          round_tripped = reader.read(session_id)

          # OUT OF BAND: the engine's own client, not Tina4. A backend that had
          # silently demoted to a local SQLite file would round-trip happily
          # above and find nothing here.
          stored = engine[:read_back].call(session_id)

          if round_tripped != payload
            broken << "#{engine[:name]} (handler read back #{round_tripped.inspect})"
          elsif stored.nil?
            broken << "#{engine[:name]} (no row in #{session_table} out of band - " \
                      "the write did not land on this engine)"
          elsif JSON.parse(stored) != payload
            broken << "#{engine[:name]} (out of band row was #{stored.inspect})"
          else
            ran << engine[:name]
          end

          reader.destroy(session_id)
        rescue StandardError => e
          broken << "#{engine[:name]} (#{e.class}: #{e.message.to_s[0, 140]})"
        ensure
          close_handler.call(writer)
          close_handler.call(reader)
        end
      end

      expect(broken).to be_empty,
                        "these engines did NOT work: #{broken.join('; ')}. " \
                        "A backend that advertises an engine must work on it - develop on " \
                        "sqlite, deploy on postgres, and nobody can log in."
      expect(ran.length).to(
        be >= 3,
        "only #{ran.length} engine(s) ran (#{ran.join(', ')}) - one engine passing is not the " \
        "invariant. sqlite, postgres AND mysql are all required " \
        "(TINA4_REQUIRE_SERVICES=#{ENV['TINA4_REQUIRE_SERVICES'].inspect})."
      )

      RSpec.configuration.reporter.message("     engines exercised: #{ran.join(', ')}")
    ensure
      begin
        clean_up_postgres.call(written_session_ids, !postgres_had_table) if reachable.call(pg_host, pg_port)
      rescue StandardError
        nil
      end
      begin
        clean_up_mysql.call(written_session_ids, !mysql_had_table) if reachable.call(mysql_host, mysql_port)
      rescue StandardError
        nil
      end
    end
  end

  it "an_unsupported_engine_refuses_by_name_instead_of_degrading" do
    unsupported_url = "notareal://tina4user:tina4secret@127.0.0.1:1234/db"
    set_real_env("TINA4_DATABASE_URL" => unsupported_url,
                 "TINA4_DATABASE_USERNAME" => nil,
                 "TINA4_DATABASE_PASSWORD" => nil)

    # Construction must stay silent: invariant 4 / ADR-0021 forbids network I/O
    # in a handler constructor, and resolving the connection IS network I/O, so
    # the refusal cannot live here even though Node's did.
    handler = nil
    expect { handler = Tina4::SessionHandlers::DatabaseHandler.new }.not_to raise_error

    raised = nil
    begin
      handler.write("unsupported-engine-#{SecureRandom.hex(4)}", { "seeded" => true }, 60)
    rescue StandardError => e
      raised = e
    ensure
      close_handler.call(handler)
    end

    expect(raised).not_to be_nil,
                          "writing a session against #{unsupported_url.sub('tina4secret', '***')} did " \
                          "NOT raise. Falling through to some other engine is the failure mode this " \
                          "invariant exists to stop: a silent demotion looks exactly like success " \
                          "until sessions start disappearing across instances."
    # The refusal comes from Tina4::DatabaseUrl#parse_standard (via
    # Tina4::Database#detect_driver), reached from DatabaseHandler#db on FIRST
    # USE. Ruby refuses one layer below the session handler, which is why the
    # session backend never had to grow its own engine allow-list.
    expect(raised).to be_a(ArgumentError),
                      "expected the Database layer's ArgumentError, got #{raised.class}: #{raised.message}"
    expect(raised.message).to include("notareal"),
                              "the refusal must NAME the scheme it got, or an operator cannot tell a " \
                              "typo from a genuinely unsupported engine. Got: #{raised.message}"
    expect(raised.message).not_to include("tina4secret"),
                                  "the refusal named the scheme but leaked the password with it: " \
                                  "#{raised.message}"
  end
end
