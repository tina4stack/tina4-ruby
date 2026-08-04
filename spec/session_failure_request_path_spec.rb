# frozen_string_literal: true

# SESSION CONTRACT: a backend failure is LOUD, then degrades - on the REAL
# request path.
#
# ADR-0021 / session_contract.json #3: a backend that becomes unreachable is
# LOGGED and then degraded - the read yields an empty session, save returns
# false, and the request STILL SERVES. It is never silent. TINA4_SESSION_STRICT
# re-raises instead.
#
# WHY THIS FILE EXISTS, and why it is separate from session_spec.rb and friends.
#
# Those files prove the policy on the Session OBJECT, and the policy there is
# correct: safe_read / safe_write / safe_destroy log via log_backend_error and
# re-raise when strict. This file proves it on the HTTP REQUEST PATH, which is a
# different code path - and that is exactly where the policy was missing.
# Measured at v3 HEAD, lib/tina4/session.rb:107:
#
#     @handler = create_handler
#
# Handler CONSTRUCTION sat OUTSIDE the policy, with no rescue at all. A handler
# whose constructor touches the network - DatabaseHandler#initialize opens its
# connection and issues DDL via ensure_table - raised straight out of
# Tina4::Session.new, out of Tina4::Request#session, and into RackApp's 500
# handler. The real backtrace, captured on this branch before the fix:
#
#     database.rb:459  Tina4::Database#current_driver
#     database_handler.rb:77  ensure_table
#     database_handler.rb:23  DatabaseHandler#initialize
#     session.rb:483   Tina4::Session#create_handler
#     session.rb:107   Tina4::Session#initialize      <- the unguarded line
#     request.rb:214   Tina4::Request#session
#
# So an unreachable backend 500ed the whole request instead of degrading it; the
# deliberate ArgumentError for an unknown TINA4_SESSION_BACKEND did the same;
# and TINA4_SESSION_STRICT was INERT here, because the non-strict path already
# produced the identical 500 an operator chooses strict mode to get.
#
# THE OTHER HALF OF THE RULE, and the easy thing to get wrong when making
# failures loud: a genuinely EMPTY session is NOT an error and must never be
# logged as one. A first-time visitor with no cookie, and a cookie whose session
# the store has never heard of, are both ORDINARY. If those log an error the log
# fills with noise on every new visitor and the real outage becomes invisible -
# the same blindness the fix was meant to cure. Example 3 is that control and it
# is not optional.
#
# NO MOCKS, ANYWHERE. The unreachable backend is a REAL Tina4::Database driving
# the REAL pg driver at a genuinely CLOSED TCP port; the healthy backend is the
# REAL file handler on a real filesystem; the logger is the REAL Tina4::Log
# writing real bytes to a real file which each example reads back off disk (the
# repo's RealLogCapture helper, no Tina4::Log stub anywhere); and every request
# goes through the REAL Tina4::RackApp via TestClient, hitting a REAL route
# registered on the REAL router. Every example carries a DRIVER SANITY check, so
# a "was logged" assertion can never be vacuous and a "logged nothing"
# assertion can never be trivially true.
#
# NOTE ON HANDLER CHOICE: this file never constructs a MongoHandler, because it
# does not need one - the database backend at a closed port exercises the same
# gap. (Historically there was a second reason: MongoHandler had no #close and
# leaked a connection pool per construction, which broke
# docstore_substitutability_spec's connection-count gate. Invariant 4 made the
# Mongo client lazy and added MongoHandler#close, so a construction that never
# operates now opens nothing at all.)
#
# WHAT INVARIANT 4 CHANGED HERE. This file was written when handler CONSTRUCTION
# was where an unreachable backend blew up, so the backtrace above is history,
# not current behaviour: DatabaseHandler#initialize no longer builds a Database
# and no longer issues DDL (see spec/session_handler_construction_spec.rb). The
# guard on session.rb:142 stays - it is what makes a construction-time
# CONFIGURATION error (example 1's unknown backend) degrade instead of 500 - but
# the network failures in examples 2 and 4 now surface on the first READ, inside
# the same policy. The contract each example asserts is unchanged; only the log
# record they match moved from "handler construction" to "read".

require_relative "spec_helper"
require_relative "support/real_log_capture"
require "socket"

RSpec.describe "Session backend failure on the REAL request path" do
  # NO BARE CONSTANTS IN HERE. A constant assigned inside an RSpec.describe
  # block is defined on Object and is therefore GLOBAL - it has already clobbered
  # other spec files in this repo (see the PORT incident documented in
  # spec/spec_helper.rb). Everything below is a local, a let, or a method.

  let(:probe_path) { "/session-failure-probe" }

  # A well-formed session id for a session the store has never heard of. WITHOUT
  # a cookie the request path takes the "brand new session" branch
  # (adopt_or_mint short-circuits on a nil id) and never touches the backend at
  # all, so an "unreachable backend" case would pass while proving nothing. That
  # exact trap produced a false green in the Python port of this suite.
  let(:existing_session_cookie) { { "Cookie" => "tina4_session=#{'a1b2c3d4' * 8}" } }

  # Routes that completed. The probe pushes here as its LAST act, so an empty
  # array means the handler did not finish - i.e. something raised out of it.
  let(:handler_completions) { [] }

  let(:client) { Tina4::TestClient.new }

  before(:each) do
    completions = handler_completions
    Tina4::Router.get(probe_path) do |request, response|
      session = request.session
      body = { "session_present" => !session.nil?, "data" => session.all }
      completions << :completed
      response.json(body)
    end
  end

  # --- Real, no-mock plumbing -----------------------------------------------

  # Bind a port, learn its number, close it. Nothing is listening afterwards.
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def nothing_answers?(host, port)
    TCPSocket.new(host, port).close
    false
  rescue SystemCallError
    true
  end

  # Set real env vars for the block and put every one of them back.
  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.key?(key) ? ENV[key] : :__unset__] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value == :__unset__ ? ENV.delete(key) : ENV[key] = value }
  end

  # Bind a real default database for the block, then restore whatever was bound
  # before. Saving and restoring the module's own real state is not a double -
  # no collaborator is substituted.
  def with_bound_database(database)
    saved = Tina4.instance_variable_get(:@database)
    Tina4.bind_database(database)
    yield
  ensure
    Tina4.bind_database(saved)
  end

  # Split the REAL error.log into RECORDS. A record starts at a timestamped
  # level line; a stack trace continues the record it belongs to. Splitting on
  # records rather than lines matters: a backtrace frame reading "session.rb"
  # would otherwise be miscounted as a session error and make the negative
  # control pass for the wrong reason.
  def error_records(log_text)
    records = []
    log_text.each_line do |line|
      if line.match?(/\A\d{4}-\d{2}-\d{2}T[\d:.]+Z \[[A-Z]+\s*\]/)
        records << +line
      elsif !records.empty?
        records.last << line
      end
    end
    records
  end

  def session_error_records(log_text)
    error_records(log_text).select { |record| record.match?(/session/i) }
  end

  # Run `block` with the REAL Tina4::Log writing to a real file, and hand back
  # the real bytes of the real error.log.
  #
  # DRIVER SANITY: a known record is written through the REAL logger first and
  # asserted present. Without it, every "was logged" assertion in this file
  # would be meaningless and every "logged nothing" assertion trivially true.
  # The token deliberately contains no substring matching /session/i, so it can
  # never satisfy a session-error assertion by itself.
  def real_error_log
    text = nil
    with_real_log_dir do |dir|
      Tina4::Log.error("sink-selftest-marker")
      yield
      text = read_real_log(dir, error_log: true)
    end
    expect(text).to include("sink-selftest-marker"),
                    "the REAL logger wrote nothing to error.log - every log assertion " \
                    "in this file would be meaningless"
    text
  end

  # A real, unreachable Tina4::Database plus proof that it is genuinely
  # unreachable BEFORE it is handed to the session layer. This is the driver
  # sanity check for the backend itself: if the pg driver were missing, or the
  # port answered, this fails loudly here instead of quietly weakening the case.
  def unreachable_database
    port = closed_port
    expect(nothing_answers?("127.0.0.1", port)).to be(true),
                                                   "127.0.0.1:#{port} answered - it was supposed to be CLOSED, so this " \
                                                   "example would not be testing an unreachable backend at all"

    database = Tina4::Database.new("postgres://127.0.0.1:#{port}/tina4",
                                   username: "tina4", password: "tina4")
    expect { database.execute("SELECT 1") }
      .to raise_error(StandardError, /refused|connect/i),
          "the database at the closed port did NOT fail - the backend under test is not unusable"
    database
  end

  # --- 1. LOUD --------------------------------------------------------------

  it "a_backend_failure_on_the_request_path_is_logged_not_silent" do
    # TINA4_SESSION_BACKEND is set to a name the framework deliberately refuses.
    # That refusal is a loud ArgumentError by design (see validate_backend!),
    # and the request path used to let it escape as a bare 500 with nothing from
    # the session layer in any log - the operator saw a crash, not a diagnosis.
    log_text = nil
    result = nil

    with_env("TINA4_SESSION_BACKEND" => "redsi") do # a real typo, deliberately refused
      client.app # build the real RackApp before the bad config is exercised
      log_text = real_error_log { result = client.get(probe_path, headers: existing_session_cookie) }
    end

    offenders = session_error_records(log_text)
    expect(offenders).not_to be_empty,
                             "an unusable session backend produced NO session error record on the real " \
                             "request path - the operator has no signal at all"
    # It must be the SESSION LAYER's own record. RackApp#handle_500 logs
    # "500 Internal Server Error: <message>" for any crash, and that message
    # happens to contain the word "session" here - so asserting merely that
    # "something mentioning session was logged" would be satisfied by the very
    # unhandled crash this fix exists to prevent.
    expect(offenders.join).to match(/Session handler construction failed \(redsi\)/),
                              "the session layer did not log the failure itself; only a generic crash was " \
                              "recorded, which diagnoses nothing"
    expect(offenders.join).to include("Unknown session backend"),
                              "the log names no cause - an operator cannot act on it"
    expect(result.status).to eq(200)
  end

  # --- 2. THEN DEGRADE ------------------------------------------------------

  it "a_backend_failure_on_the_request_path_still_serves_the_request" do
    # Loud is only half the rule: the request must still be SERVED. Degrading
    # means the user gets their page without a session, not a 500. That is what
    # separates a degrade from an outage.
    log_text = nil
    result = nil

    database = unreachable_database
    with_env("TINA4_SESSION_BACKEND" => "database", "TINA4_SESSION_STRICT" => nil) do
      client.app # real RackApp built before the unreachable DB is bound
      with_bound_database(database) do
        log_text = real_error_log { result = client.get(probe_path, headers: existing_session_cookie) }
      end
    end

    expect(result.status).to eq(200),
                             "an unreachable session backend returned #{result.status} instead of serving " \
                             "the request without a session"
    expect(handler_completions).to eq([:completed]),
                                   "the route handler never finished, so the request did not really serve"
    expect(result.json["data"]).to eq({}),
                                   "a degraded session must read as EMPTY, not carry stale or partial data"
    # WHERE the failure surfaces moved, and that is the point of invariant 4
    # (session_contract.json #4, spec/session_handler_construction_spec.rb).
    # DatabaseHandler#initialize used to build a Tina4::Database (which DIALS)
    # and issue CREATE TABLE, so an unreachable backend failed at CONSTRUCTION
    # and was logged as "Session handler construction failed (database)". Both
    # are now deferred to first use, so the SAME outage surfaces on the first
    # READ instead - from the REAL handler, which is why the record now names
    # the handler class rather than the configured backend name. The contract
    # asserted here is unchanged: served, empty, and LOUD.
    expect(session_error_records(log_text).join)
      .to match(/Session read failed \(Tina4::SessionHandlers::DatabaseHandler\)/),
          "the request served, but the unreachable backend was not logged - degrading " \
          "SILENTLY is the defect, not the fix"
    expect(session_error_records(log_text).join).to match(/refused|connect/i),
                                                    "the log records that something failed but not WHAT - the real driver cause is missing"
  end

  # --- 3. NEGATIVE CONTROL: an empty session is ORDINARY --------------------

  it "an_empty_session_on_the_request_path_is_not_logged_as_a_failure" do
    # THE ONE MOST LIKELY TO BE GOT WRONG. A first-time visitor has no cookie and
    # therefore an empty session; a visitor holding a cookie the store has never
    # heard of also gets an empty session. Both are ORDINARY, not failures. If
    # making failures loud also makes these loud, the log fills with noise on
    # every new visitor and the real outage becomes invisible.
    #
    # Without this example, "log an error unconditionally on every read" passes
    # examples 1 and 2 and ships.
    log_text = nil
    fresh = nil
    unknown = nil

    with_env("TINA4_SESSION_BACKEND" => "file", "TINA4_SESSION_STRICT" => nil) do
      client.app
      log_text = real_error_log do
        fresh   = client.get(probe_path)                                        # (a) no cookie at all
        unknown = client.get(probe_path, headers: existing_session_cookie)      # (b) cookie the store never issued
      end
    end

    expect(fresh.status).to eq(200)
    expect(unknown.status).to eq(200)
    expect(fresh.json["data"]).to eq({})
    expect(unknown.json["data"]).to eq({})
    offenders = session_error_records(log_text)
    expect(offenders).to be_empty,
                         "a HEALTHY backend with an EMPTY session logged an error. An empty session is " \
                         "not a failure - logging it buries the real outages under one line per new " \
                         "visitor. Logged: #{offenders.inspect}"
  end

  # --- 4. STRICT MODE REFUSES -----------------------------------------------

  it "strict_mode_on_the_request_path_refuses_instead_of_degrading" do
    # TINA4_SESSION_STRICT must actually REACH the request path. Strict mode
    # exists so an operator can choose "fail the request" over "serve it without
    # a session". Before the fix it was INERT here in the worst possible way: the
    # non-strict path ALSO crashed with a 500, so setting the flag changed
    # nothing an operator could observe.
    #
    # HOW THE RAISE IS OBSERVED. Tina4::RackApp#call rescues every exception by
    # design (rack_app.rb:128 -> handle_500), so wrapping a TestClient call in
    # `expect { }.to raise_error` would be asserting that the Rack app FAILS to
    # do its job. The raise is therefore observed at the two real boundaries the
    # framework itself provides:
    #   * the route handler never completed - it was unwound by the raise
    #     (handler_completions stays empty, where every other example here has it
    #     filled), and the response is a 500 rather than the degraded 200;
    #   * the REAL exception object arrives on the REAL "tina4.request.error"
    #     event, which is the framework's own observability hook (the one an APM
    #     subscribes to) carrying the actual raised error, not a copy.
    log_text = nil
    result = nil
    raised = []

    listener = Tina4::Events.on("tina4.request.error") { |payload| raised << payload[:exception] }
    database = unreachable_database

    begin
      with_env("TINA4_SESSION_BACKEND" => "database", "TINA4_SESSION_STRICT" => "true") do
        client.app
        with_bound_database(database) do
          log_text = real_error_log { result = client.get(probe_path, headers: existing_session_cookie) }
        end
      end
    ensure
      Tina4::Events.off("tina4.request.error", listener)
    end

    expect(handler_completions).to be_empty,
                                   "strict mode did NOT refuse: the route handler ran to completion, which is the " \
                                   "degraded outcome strict mode is chosen to prevent"
    expect(result.status).to eq(500),
                             "strict mode served #{result.status} - a cheerful degraded response is exactly " \
                             "what the operator set TINA4_SESSION_STRICT to avoid"
    expect(raised).not_to be_empty,
                          "nothing raised out of the request path at all"

    # It must surface the REAL driver error, not a generic wrapper. A strict mode
    # that raises something opaque tells the operator no more than silence did.
    surfaced = "#{raised.first.class}: #{raised.first.message}"
    expect(surfaced).to match(/refused|connect/i),
                        "strict mode raised, but not with the real backend failure: #{surfaced}"

    # Loud must mean logged AND raised. A strict mode that raises without logging
    # first leaves a hole in the log exactly where the outage is.
    records = error_records(log_text)
    # Same move as example 2: with the constructor no longer touching the
    # network (invariant 4), the unreachable database surfaces on the first READ
    # and strict mode re-raises from safe_read/existing_session_data instead of
    # from the construction rescue. Loud-then-raise is unchanged.
    session_index = records.index { |record| record.match?(/Session read failed/) }
    crash_index   = records.index { |record| record.include?("500 Internal Server Error") }
    expect(session_index).not_to be_nil,
                                 "strict mode raised without the session layer logging first"
    expect(crash_index).not_to be_nil
    expect(session_index).to be < crash_index,
                             "the session failure was logged AFTER the crash it caused - the log reads " \
                             "backwards from the operator's point of view"
  end
end
