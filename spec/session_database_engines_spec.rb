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
#   3. the CONCURRENT FIRST-USE RACE is covered on every engine - two workers
#      booting together both reach ensure_table and both issue the CREATE, and
#      the loser must not take down the subsystem that decides who is logged in.
#      This is the case that pins the PER-ENGINE DDL as well, because the DDL a
#      worker issues has to be legal on its engine before the race is even
#      reachable: the single generic string this replaced opened with CREATE
#      TABLE IF NOT EXISTS, which is not T-SQL, so the backend did not work on
#      MSSQL AT ALL, and Firebird rejected it twice over (no IF NOT EXISTS
#      clause, no TEXT type). Case 3 therefore drives FIVE engines, two more
#      than case 1: sqlite, postgres, mysql, mssql AND firebird.

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
  # mysql2/libmysqlclient connects over a UNIX SOCKET whenever host is
  # "localhost" (ignoring the port), and the lab's MySQL is a TCP-only container
  # with no local socket. Force TCP for the raw out-of-band reader below -- the
  # Tina4 MySQL driver already rewrites localhost+port to 127.0.0.1 itself.
  mysql_host = "127.0.0.1" if mysql_host == "localhost"
  mysql_port = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
  mysql_user = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "root")
  mysql_pass = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
  mysql_db   = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4")

  # Case 3 only. The canonical TINA4_TEST_MSSQL_* spelling the rest of the suite
  # uses (database_mysql_mssql_live_spec, batch_insert_spec); the lab exports the
  # credentials, the defaults cover a local container.
  mssql_host = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
  mssql_port = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
  mssql_user = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
  mssql_pass = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
  mssql_db   = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")

  # Firebird follows the repo's established gate: it is exercised when
  # TINA4_TEST_FIREBIRD_URL is configured (the lab exports it), and is simply
  # absent from the roster when it is not, rather than skipping an example. The
  # credentials are the spelling the other firebird specs hardcode.
  firebird_url  = ENV["TINA4_TEST_FIREBIRD_URL"].to_s
  firebird_user = ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA")
  firebird_pass = ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey")

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

  it "the_concurrent_first_use_race_is_covered_on_every_engine" do
    sqlite_path = File.join(work_dir, "race.db")

    # Every engine the DatabaseHandler can be pointed at. sqlite/postgres/mysql
    # settle the race ENGINE-SIDE with IF NOT EXISTS; mssql and firebird have no
    # such clause and are carried entirely by the rescue in ensure_table. All
    # five are driven the same way, so the case cannot pass by covering only the
    # engines that were already safe.
    engines = [
      { name: "sqlite", url: "sqlite:#{sqlite_path}", username: nil, password: nil },
      { name: "postgres",
        url: "postgres://#{pg_host}:#{pg_port}/#{pg_db}",
        username: pg_user, password: pg_pass },
      { name: "mysql",
        url: "mysql://#{mysql_host}:#{mysql_port}/#{mysql_db}",
        username: mysql_user, password: mysql_pass },
      # Credentials go in the KWARGS and the env, never inside the URL: the
      # lab's sa password contains a '!', which a URL would have to
      # percent-encode, and a mis-encoded password reads as an engine failure.
      { name: "mssql",
        url: "mssql://#{mssql_host}:#{mssql_port}/#{mssql_db}",
        username: mssql_user, password: mssql_pass }
    ]
    unless firebird_url.empty?
      engines << { name: "firebird", url: firebird_url,
                   username: firebird_user, password: firebird_pass }
    end

    ran = []
    broken = []

    engines.each do |engine|
      sentinel_id = "race-#{engine[:name]}-#{SecureRandom.hex(4)}"
      # The spec's OWN connection, independent of both handlers. It sets the
      # table up, plants the sentinel, and answers "is the table intact" - so
      # intactness is never asserted through the connection under test.
      probe = nil
      first_use = nil
      second_use = nil
      created_here = false

      begin
        probe = Tina4::Database.new(engine[:url],
                                    username: engine[:username], password: engine[:password])
        had_table = probe.table_exists?(session_table)

        set_real_env("TINA4_DATABASE_URL" => engine[:url],
                     "TINA4_DATABASE_USERNAME" => engine[:username],
                     "TINA4_DATABASE_PASSWORD" => engine[:password])

        # WORKER A. The first boot creates the table. ensure_table is private
        # because nothing outside the handler should call it, but it is the
        # first thing read/write/destroy/cleanup/gc each do, so driving it
        # directly exercises the real path with nothing else in the way.
        first_use = Tina4::SessionHandlers::DatabaseHandler.new
        first_use.send(:ensure_table)
        created_here = !had_table

        unless probe.table_exists?(session_table)
          broken << "#{engine[:name]} (first use did not create #{session_table})"
          next
        end

        # A row planted BEFORE the second creation. If the second CREATE were
        # allowed to replace the table rather than being absorbed, this row
        # would be gone afterwards - which is how "intact" is proved rather
        # than assumed.
        probe.execute(
          "INSERT INTO #{session_table} (session_id, data, expires_at) VALUES (?, ?, ?)",
          [sentinel_id, '{"sentinel":true}', 0.0]
        )
        begin
          probe.commit
        rescue StandardError
          nil # autocommit engines have nothing to commit
        end

        # WORKER B. A FRESH handler, so @table_ready is unset and the CREATE is
        # really issued against a table that is already there - the losing side
        # of the concurrent first-use race, made deterministic.
        second_use = Tina4::SessionHandlers::DatabaseHandler.new
        begin
          second_use.send(:ensure_table)
        rescue StandardError => e
          broken << "#{engine[:name]} (second first-use RAISED #{e.class}: #{e.message.to_s[0, 200]})"
          next
        end

        if !probe.table_exists?(session_table)
          broken << "#{engine[:name]} (#{session_table} is GONE after the second first-use)"
        elsif probe.fetch_one("SELECT session_id FROM #{session_table} WHERE session_id = ?",
                              [sentinel_id]).nil?
          broken << "#{engine[:name]} (the row planted before the second first-use was lost - " \
                    "the table was replaced, not left alone)"
        else
          ran << engine[:name]
        end
      # LoadError too, and deliberately: a missing driver gem is a ScriptError,
      # not a StandardError, so without it the FIRST engine whose gem is absent
      # aborts the whole example and the engines after it are never reached.
      # An engine that cannot be driven is a broken engine, reported by name
      # alongside the rest, not an exception that hides the other four.
      rescue StandardError, LoadError => e
        broken << "#{engine[:name]} (#{e.class}: #{e.message.to_s[0, 200]})"
      ensure
        close_handler.call(first_use)
        close_handler.call(second_use)
        if probe
          begin
            if created_here
              probe.execute("DROP TABLE #{session_table}")
            else
              probe.execute("DELETE FROM #{session_table} WHERE session_id = ?", [sentinel_id])
            end
            begin
              probe.commit
            rescue StandardError
              nil
            end
          rescue StandardError
            nil
          end
          begin
            probe.close
          rescue StandardError
            nil
          end
        end
      end
    end

    expect(broken).to be_empty,
                      "the concurrent first-use race is NOT covered on: #{broken.join('; ')}. " \
                      "Two workers booting together both issue the CREATE; the loser must be " \
                      "absorbed, because the alternative is the session backend refusing to " \
                      "start and nobody being able to log in."
    expect(ran.length).to(
      be >= engines.length,
      "only #{ran.length} of #{engines.length} engine(s) ran (#{ran.join(', ')}). The race guard " \
      "has to hold on EVERY engine - IF NOT EXISTS covers sqlite/postgres/mysql engine-side, so a " \
      "run that skipped mssql or firebird has proved nothing about the engines that need the rescue."
    )

    RSpec.configuration.reporter.message("     race covered on: #{ran.join(', ')}")
  end
end
