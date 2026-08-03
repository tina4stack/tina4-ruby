# frozen_string_literal: true

require "json"
require "pp"
require "socket"
require "stringio"
require "spec_helper"
require_relative "support/live_postgres"

# A credential must never reach a log line, an exception message, or a dump.
#
# Every case below was MEASURED as leaking in this repo on 2026-08-02 before the
# fix, on the real path named in its comment - not inferred from reading source.
#
# The sentinel password contains a SPACE on purpose. Every redaction bug in this
# cluster was a pattern that stopped at a delimiter the password itself can
# contain (PHP's `password=\S*` stopped at the space; Ruby's
# `([^:/@]+):[^@]*@` stopped at the first "@"), so a sentinel without one lets
# that whole bug class hide.
#
# NO MOCKS. The connect-failure cases run against the live PostgreSQL.
#
# Identical case names belong in all four frameworks:
#   tina4-python/tests/test_database_url_redaction.py
#   tina4-php/tests/DatabaseUrlRedactionTest.php
#   tina4-nodejs/test/databaseUrlRedaction.test.ts
SENTINEL_PASSWORD = "s3ntinel-Pa55 word"
SENTINEL_STEM     = "s3ntinel" # matches the raw AND the %20-encoded spelling

RSpec.describe "DatabaseUrl credential redaction" do
  # ── C2 ──────────────────────────────────────────────────────────────────
  #
  # MEASURED BEFORE THE FIX, on the boot path (Database#detect_driver calls
  # DatabaseUrl.new on the raw TINA4_DATABASE_URL):
  #   ArgumentError: DatabaseUrl: Invalid URL format
  #     'postgres://tina4:s3ntinel-Pa55 word@192.168.88.99:notaport/tina4_py'
  # That exception reaches the boot log, the error overlay, a crash report and
  # CI output. The message still has to be diagnosable, which is why the
  # positive half is as strict as the negative half: a fix that redacts
  # everything would pass a naive "the secret is absent" test and be useless.
  describe "a malformed URL" do
    let(:malformed) { "postgres://tina4:#{SENTINEL_PASSWORD}@192.168.88.99:notaport/tina4_py" }

    it "c2_a_malformed_url_keeps_the_password_out_of_the_exception" do
      message = (begin
        Tina4::DatabaseUrl.new(malformed)
        raise "expected DatabaseUrl to reject #{malformed.sub(SENTINEL_PASSWORD, '***')}"
      rescue ArgumentError => e
        e.message
      end)

      # NEGATIVE half - the credential is gone.
      expect(message).not_to include(SENTINEL_STEM)
      # POSITIVE half - the fault is still diagnosable without it.
      expect(message).to include("postgres://")   # the scheme
      expect(message).to include("192.168.88.99") # the host
      expect(message).to include("notaport")      # the actual fault
      expect(message).to include("tina4_py")      # the database
      expect(message).to include("***")           # where the password was
      expect(message).to include("scheme://user:password@host:port/database")
    end

    it "c2_a_malformed_url_keeps_the_password_out_of_the_exception_on_the_boot_path" do
      message = (begin
        Tina4::Database.new(malformed)
        raise "expected Database.new to reject a malformed URL"
      rescue ArgumentError => e
        e.message
      end)

      expect(message).not_to include(SENTINEL_STEM)
      expect(message).to include("192.168.88.99")
      expect(message).to include("notaport")
    end

    # The shape with NO structure at all - the measured Python case
    # 'notaurl-with-SuperSecret123'. There is no scheme, no "@" and no host, so
    # nothing in the value can be proven not to be the password: the ONLY safe
    # answer is to describe the fault and show none of it.
    it "c2_a_url_with_no_scheme_is_not_echoed_at_all" do
      message = (begin
        Tina4::DatabaseUrl.new("notaurl-with-#{SENTINEL_PASSWORD}")
        raise "expected DatabaseUrl to reject a scheme-less value"
      rescue ArgumentError => e
        e.message
      end)

      expect(message).not_to include(SENTINEL_STEM)
      expect(message).to include("no '://'")
      expect(message).to include("scheme://user:password@host:port/database")
    end

    # A password containing an unencoded "@" is the shape that defeats a
    # first-"@" split. The tail after the inner "@" must not survive.
    it "c2_an_unencoded_at_in_the_password_leaves_no_tail" do
      message = (begin
        Tina4::DatabaseUrl.new("postgres://tina4:pa@#{SENTINEL_PASSWORD}@dbhost:notaport/appdb")
        raise "expected DatabaseUrl to reject a malformed URL"
      rescue ArgumentError => e
        e.message
      end)

      expect(message).not_to include(SENTINEL_STEM)
      expect(message).not_to include("pa@")
      expect(message).to include("tina4:***@dbhost:notaport/appdb")
    end
  end

  # ── C3 ──────────────────────────────────────────────────────────────────
  #
  # to_safe_string called itself "the ONLY form allowed in a log line" and had
  # ZERO call sites on any real path - Database#safe_connection_target carried a
  # SECOND regex instead, and that regex leaked on two measured shapes.
  describe "the connect-failure path" do
    it "c3_safe_connection_target_routes_through_the_one_redaction_primitive" do
      db = Tina4::Database.allocate
      db.instance_variable_set(:@connection_string,
                               "postgres://tina4:pa@#{SENTINEL_PASSWORD}@dbhost:5432/appdb")

      target = db.safe_connection_target

      # NEGATIVE half - the old `([^:/@]+):[^@]*@` stopped at the FIRST "@" and
      # emitted `postgres://tina4:***@s3ntinel-Pa55 word@dbhost:5432/appdb`.
      expect(target).not_to include(SENTINEL_STEM)
      expect(target).not_to include("pa@")
      # POSITIVE half - it still names the target.
      expect(target).to eq("postgres://tina4:***@dbhost:5432/appdb")
    end

    it "c3_safe_connection_target_redacts_an_odbc_connection_string" do
      db = Tina4::Database.allocate
      db.instance_variable_set(:@connection_string,
                               "odbc:///DRIVER={PostgreSQL};SERVER=dbhost;UID=tina4;PWD=#{SENTINEL_PASSWORD}")

      target = db.safe_connection_target

      # NEGATIVE half - this used to be returned VERBATIM into
      # DatabaseConnectionError, which surfaces in a 500 body.
      expect(target).not_to include(SENTINEL_STEM)
      # POSITIVE half - every non-credential keyword survives.
      expect(target).to eq("odbc:///DRIVER={PostgreSQL};SERVER=dbhost;UID=tina4;PWD=***")
    end

    # LIVE PostgreSQL. The positive half proves the endpoint is real (the right
    # password connects); the negative half proves the WRONG password does not
    # reach the raised message that a route turns into a 500.
    it "c3_a_live_connect_failure_names_the_target_without_the_password" do
      host = LivePostgres.host
      port = LivePostgres.port
      expect(LivePostgres.reachable?).to be(true),
                                         "live PostgreSQL required at #{host}:#{port}"

      # POSITIVE half - the real credentials really do connect here.
      good = Tina4::Database.new(LivePostgres.url)
      expect(good.fetch_one("SELECT 1 AS ok")).not_to be_nil
      good.close

      # NEGATIVE half - a wrong password, carried through the real driver.
      bad = Tina4::Database.new(LivePostgres.url(pass: SENTINEL_PASSWORD.gsub(" ", "%20")))
      message = (begin
        bad.fetch_one("SELECT 1 AS ok")
        raise "expected the wrong password to be rejected by the live server"
      rescue Tina4::DatabaseConnectionError => e
        e.message
      end)

      expect(message).not_to include(SENTINEL_STEM)
      expect(message).to include("postgres")             # the driver
      expect(message).to include(host)                   # the host
      expect(message).to include(port.to_s)              # the port
      expect(message).to include(LivePostgres.database)  # the database
      expect(message).to include("password authentication failed") # the reason
    end
  end

  # ── C5 ──────────────────────────────────────────────────────────────────
  #
  # to_safe_string returned the ODBC connection string verbatim, PWD= included,
  # while the negative test "never leaks the password" was GREEN - it iterates
  # the shared corpus and the corpus had no odbc row. The corpus row added
  # alongside this spec is what makes that existing test a real gate.
  describe "to_safe_string on an ODBC URL" do
    let(:odbc) do
      Tina4::DatabaseUrl.new(
        "odbc:///DRIVER={PostgreSQL};SERVER=dbhost;DATABASE=appdb;UID=tina4;PWD=#{SENTINEL_PASSWORD}"
      )
    end

    it "c5_to_safe_string_never_contains_the_odbc_password" do
      # NEGATIVE half - on every surface, not just to_safe_string.
      expect(odbc.to_safe_string).not_to include(SENTINEL_STEM)
      expect(odbc.inspect).not_to include(SENTINEL_STEM)
      expect(odbc.to_s).not_to include(SENTINEL_STEM)
      expect(odbc.to_json).not_to include(SENTINEL_STEM)

      # POSITIVE half - a redaction that ate the whole string would be useless.
      expect(odbc.to_safe_string).to include("DRIVER={PostgreSQL}")
      expect(odbc.to_safe_string).to include("SERVER=dbhost")
      expect(odbc.to_safe_string).to include("DATABASE=appdb")
      expect(odbc.to_safe_string).to include("UID=tina4")
      expect(odbc.to_safe_string).to include("PWD=***")
    end

    # An ODBC value containing ";" must be braced. A redactor that splits on ";"
    # first stops inside the braces and leaves the rest of the password behind -
    # the same tail-leak shape as C4.
    it "c5_a_braced_odbc_password_containing_a_semicolon_leaves_no_tail" do
      url = Tina4::DatabaseUrl.new("odbc:///DSN=Reports;UID=tina4;PWD={pa;#{SENTINEL_PASSWORD}}")

      expect(url.to_safe_string).not_to include(SENTINEL_STEM)
      expect(url.to_safe_string).not_to include("pa;")
      expect(url.to_safe_string).to eq("odbc:///DSN=Reports;UID=tina4;PWD=***")
    end

    # libpq accepts the password as a QUERY parameter, so the query string is a
    # credential carrier too.
    it "c5_a_password_query_parameter_is_redacted_in_the_raw_scrub" do
      scrubbed = Tina4::DatabaseUrl.redact(
        "postgres://dbhost:notaport/appdb?sslmode=require&password=#{SENTINEL_PASSWORD}"
      )

      expect(scrubbed).not_to include(SENTINEL_STEM)
      expect(scrubbed).to include("sslmode=require")
      expect(scrubbed).to include("password=***")
    end
  end

  # ── C6 ──────────────────────────────────────────────────────────────────
  #
  # Ruby already guarded the console and backtraces through #inspect; PHP leaks
  # through print_r/var_dump and Node through JSON.stringify. Pinned here so
  # Ruby cannot ACQUIRE the bug, and extended to the two surfaces that were
  # merely accidentally safe: interpolation and JSON.
  describe "dump and serialize surfaces" do
    let(:url) { Tina4::DatabaseUrl.new("postgres://tina4:#{SENTINEL_PASSWORD.gsub(' ', '%20')}@dbhost:5432/appdb") }

    it "c6_no_dump_surface_prints_the_password" do
      # The parse really did keep the credential - otherwise this proves nothing.
      expect(url.password).to eq(SENTINEL_PASSWORD)

      dumped = StringIO.new
      PP.pp(url, dumped)

      # NEGATIVE half.
      [url.inspect, url.to_s, url.to_json, dumped.string].each do |surface|
        expect(surface).not_to include(SENTINEL_STEM)
      end
      # POSITIVE half - each surface still identifies the connection.
      [url.inspect, url.to_s, url.to_json, dumped.string].each do |surface|
        expect(surface).to include("postgres://tina4:***@dbhost:5432/appdb")
      end
    end
  end

  # ── C3, found while sweeping the credential paths ───────────────────────
  #
  # MEASURED 2026-08-02: DevAdmin's status payload - served as JSON from
  # GET /__dev/api/status - carried ENV["TINA4_DATABASE_URL"] VERBATIM, so
  # anything that could reach the debug port was answered with the database
  # password. It is a display field with no round trip, so it goes through the
  # same redaction primitive as everything else.
  describe "the dev-admin status payload" do
    it "c3_the_dev_admin_status_payload_redacts_the_database_url" do
      saved = ENV["TINA4_DATABASE_URL"]
      begin
        ENV["TINA4_DATABASE_URL"] = "postgres://tina4:#{SENTINEL_PASSWORD.gsub(' ', '%20')}@dbhost:5432/appdb"
        payload = Tina4::DevAdmin.send(:status_payload)

        # NEGATIVE half.
        expect(payload[:database]).not_to include(SENTINEL_STEM)
        # POSITIVE half - the operator can still see WHICH database is configured.
        expect(payload[:database]).to eq("postgres://tina4:***@dbhost:5432/appdb")
      ensure
        saved.nil? ? ENV.delete("TINA4_DATABASE_URL") : ENV["TINA4_DATABASE_URL"] = saved
      end
    end

    it "c3_the_dev_admin_status_payload_still_reports_an_unconfigured_database" do
      saved = ENV["TINA4_DATABASE_URL"]
      begin
        ENV.delete("TINA4_DATABASE_URL")
        expect(Tina4::DevAdmin.send(:status_payload)[:database]).to eq("not configured")
      ensure
        ENV["TINA4_DATABASE_URL"] = saved unless saved.nil?
      end
    end
  end

  # ── C7 ──────────────────────────────────────────────────────────────────
  #
  # ABSENT and BLANK are different values. MEASURED 2026-08-02: Ruby returns ""
  # for the blank form and correctly does NOT fire the env fallback; Python and
  # Node return None there and DO fire it, so the same .env authenticates with
  # two different passwords depending on the framework. This pins Ruby's side of
  # the settled contract.
  describe "a blank password in the URL" do
    it "c7_a_blank_url_password_is_explicit_and_blocks_the_env_fallback" do
      # NEGATIVE half - blank means explicitly empty, the fallback must NOT fire.
      blank = Tina4::DatabaseUrl.new("postgres://tina4:@dbhost:5432/appdb",
                                     password: SENTINEL_PASSWORD)
      expect(blank.password).to eq("")

      # POSITIVE half - absent DOES take the env value, or the rule above would
      # just be "the fallback never works".
      absent = Tina4::DatabaseUrl.new("postgres://tina4@dbhost:5432/appdb",
                                      password: SENTINEL_PASSWORD)
      expect(absent.password).to eq(SENTINEL_PASSWORD)
    end

    it "c7_the_same_rule_holds_for_a_blank_username" do
      blank = Tina4::DatabaseUrl.new("postgres://:pw@dbhost:5432/appdb", username: "envuser")
      expect(blank.username).to eq("")

      absent = Tina4::DatabaseUrl.new("postgres://dbhost:5432/appdb", username: "envuser")
      expect(absent.username).to eq("envuser")
    end

    # from_env is the path an application actually takes, so the rule is pinned
    # through the real ENV read as well as the constructor.
    it "c7_from_env_honours_the_blank_url_password_over_the_env_variable" do
      saved = ENV.to_h.slice("TINA4_DATABASE_URL", "TINA4_DATABASE_PASSWORD")
      begin
        ENV["TINA4_DATABASE_URL"] = "postgres://tina4:@dbhost:5432/appdb"
        ENV["TINA4_DATABASE_PASSWORD"] = SENTINEL_PASSWORD
        expect(Tina4::DatabaseUrl.from_env.password).to eq("")

        ENV["TINA4_DATABASE_URL"] = "postgres://tina4@dbhost:5432/appdb"
        expect(Tina4::DatabaseUrl.from_env.password).to eq(SENTINEL_PASSWORD)
      ensure
        ENV.delete("TINA4_DATABASE_URL")
        ENV.delete("TINA4_DATABASE_PASSWORD")
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end
end
