# frozen_string_literal: true

# SESSION CONTRACT: a handler constructor performs NO network I/O.
#
# ADR-0021 / session_contract.json #4: connection happens on FIRST USE, inside
# the log-loud-and-degrade policy. A constructor sits OUTSIDE that policy, so
# anything it does cannot be logged, cannot be degraded, and cannot be re-raised
# by TINA4_SESSION_STRICT.
#
# WHY THIS MATTERS, stated as the operator sees it: the one place the failure
# policy cannot protect is the FIRST thing that runs. An unreachable backend
# takes the app down at construction instead of degrading per-request as
# designed - so the very scenario the policy exists for is the one it never
# sees. Ruby closed invariant 3 by GUARDING handler construction on the request
# path (session.rb:142); this invariant removes the reason that guard fires.
#
# MEASURED at v3 HEAD, against the real counting listener below:
#
#   lib/tina4/session_handlers/mongo_handler.rb:21-23
#       client = Mongo::Client.new(@uri, database: @database)   <- SDAM handshake
#       @collection = client[@collection_name]
#       ensure_ttl_index                                        <- createIndexes
#     THREE accepted connections, in a constructor. On an IndexOptionsConflict
#     it also drops and recreates the index, so it can be more.
#
#   lib/tina4/session_handlers/database_handler.rb:22-23
#       @db = options[:db] || Tina4::Database.new(ENV["TINA4_DATABASE_URL"])
#       ensure_table
#     Tina4::Database#initialize ends in `connect` (database.rb:405), so the
#     driver DIALS - ONE accepted connection - and ensure_table then issues real
#     DDL on it. Because Request#session builds a Session per request, that was
#     a CREATE TABLE on EVERY request.
#
# The other three socket-speaking handlers were ALREADY correct and are asserted
# here as regression cover, not as fixes: RespClient opens one short-lived
# socket per command (resp_client.rb:54, inside #command), MemcachedHandler does
# the same (memcached_handler.rb:154), and the `redis` gem 5.4.1 is lazy in
# Redis.new - all three MEASURED at zero accepts on construction.
#
# HOW THIS IS PROVED WITHOUT MOCKS.
#
#   * A real TCP listener this file starts, which COUNTS accepted connections.
#     It speaks no protocol and pretends to be nothing - it is a socket, and the
#     only thing it reports is a fact the KERNEL decided: whether anybody
#     actually connected. No test double can answer that honestly. Construct a
#     handler pointed at it and the count must still be zero; do one real
#     operation and the count must rise.
#
#   * For the database backend, which owns no socket of its own to watch when it
#     is handed a Database, the constructor is measured by its SIDE EFFECT
#     against a REAL engine: drop tina4_session, construct the handler, and ask
#     a SECOND, INDEPENDENT connection whether the table exists. That is an
#     out-of-band observation, not an assertion about code shape.
#
# EVERY example carries a DRIVER SANITY check first, because this file's central
# assertion is a ZERO. A listener that counted nothing, or a database probe that
# could not see a table at all, would make "nothing happened" trivially true.
# The sanity check makes a broken instrument fail loudly instead of passing.
#
# The negative control matters as much: deferring the connection must not break
# the connection. A healthy Redis, a healthy MongoDB and a real SQLite file all
# have to round-trip after the change, or "do nothing in the constructor" has
# been satisfied by doing nothing at all.

require_relative "spec_helper"
require "socket"
require "tmpdir"
require "fileutils"
require "securerandom"

RSpec.describe "Session handler construction performs no network I/O" do
  # NO BARE CONSTANTS IN HERE - not even a helper class. A constant assigned
  # inside an RSpec.describe block takes its cref from the enclosing LEXICAL
  # scope, which is top level, so it is defined on Object and is GLOBAL. That
  # has already clobbered other spec files in this repo (see the PORT incident
  # documented in spec/spec_helper.rb, and the PREFIXED note in
  # session_handlers_spec.rb). Everything below is a local, a let, or a method -
  # which is also why the counting listener is a METHOD that yields a handle
  # rather than a class.

  let(:redis_host) { ENV["TINA4_SESSION_REDIS_HOST"] || "127.0.0.1" }
  let(:redis_port) { (ENV["TINA4_SESSION_REDIS_PORT"] || "6379").to_i }
  let(:mongo_uri)  { ENV["TINA4_MONGO_URI"] || "mongodb://127.0.0.1:27017" }

  # --- The instrument: a REAL server, not a double --------------------------

  # Start a real TCP server that COUNTS the connections it accepts, yield the
  # port and a reader for the count, then kill the thread and close the socket.
  # It accepts, counts, and hangs up; it never speaks a protocol.
  def with_counting_listener
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepted = 0
    lock = Mutex.new
    running = true

    thread = Thread.new do
      while running
        begin
          next unless IO.select([server], nil, nil, 0.1)

          socket = server.accept_nonblock(exception: false)
          next if socket.nil? || socket == :wait_readable

          lock.synchronize { accepted += 1 }
          begin
            socket.close # accept, count, hang up
          rescue StandardError
            nil
          end
        rescue IOError, Errno::EBADF
          break # the socket was closed under us during teardown
        rescue StandardError
          next
        end
      end
    end

    yield(port, -> { lock.synchronize { accepted } })
  ensure
    running = false
    thread&.join(2)
    begin
      server&.close
    rescue StandardError
      nil
    end
  end

  # Poll until the count reaches `minimum` (or give up). Used only where a RISE
  # is expected - an absence cannot be polled for and gets a settle sleep.
  def wait_for_count(accepted, minimum, timeout: 3.0)
    deadline = Time.now + timeout
    sleep(0.02) while accepted.call < minimum && Time.now < deadline
    accepted.call
  end

  # How long to let a background connect land before declaring that none did.
  # Generous on purpose: a too-short wait would turn a real eager connect into a
  # false green.
  def settle
    sleep(0.5)
  end

  def mongo_gem_available?
    require "mongo"
    true
  rescue LoadError
    false
  end

  def service_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2).close
    true
  rescue StandardError
    false
  end

  # Every handler that speaks over a socket, all pointed at ONE endpoint. Each
  # entry is a lambda so nothing is constructed until the example asks for it.
  def socket_handlers(port)
    {
      "redis" => -> { Tina4::SessionHandlers::RedisHandler.new(host: "127.0.0.1", port: port, ttl: 60) },
      "valkey" => -> { Tina4::SessionHandlers::ValkeyHandler.new(host: "127.0.0.1", port: port, ttl: 60) },
      "memcached" => -> { Tina4::SessionHandlers::MemcachedHandler.new(host: "127.0.0.1", port: port, ttl: 60) },
      "mongodb" => lambda {
        Tina4::SessionHandlers::MongoHandler.new(
          uri: "mongodb://127.0.0.1:#{port}/?serverSelectionTimeoutMS=500&connectTimeoutMS=500",
          ttl: 60
        )
      }
    }
  end

  # --- 1. THE CONSTRUCTOR TOUCHES NOTHING -----------------------------------

  it "a_session_handler_constructor_performs_no_network_io" do
    # The mongodb handler is the one this invariant was opened for, so an
    # example that quietly omitted it would be a false green. Skip rather than
    # pretend; TINA4_REQUIRE_SERVICES turns this skip into a hard failure
    # (spec_helper.rb), which is exactly right on any machine that provisions it.
    skip "mongo gem not installed" unless mongo_gem_available?

    with_counting_listener do |port, accepted|
      # DRIVER SANITY. This example's whole assertion is a ZERO, so first prove
      # the instrument can produce a ONE. Without this, a listener whose thread
      # died would pass every assertion below while measuring nothing at all.
      TCPSocket.new("127.0.0.1", port).close
      expect(wait_for_count(accepted, 1)).to be >= 1,
                                             "the counting listener never counted a REAL connection it definitely " \
                                             "received - the instrument is broken, so every 'accepted zero' " \
                                             "assertion in this example would be vacuous"

      socket_handlers(port).each do |name, build|
        before = accepted.call
        build.call
        settle

        expect(accepted.call).to eq(before),
                                 "#{name}: the CONSTRUCTOR opened a connection " \
                                 "(#{accepted.call - before} accepted). Connection belongs on first use, " \
                                 "inside the log-loud-and-degrade policy - a constructor sits outside it, " \
                                 "so nothing it does can be logged, degraded, or re-raised by " \
                                 "TINA4_SESSION_STRICT."
      end
    end

    # The database backend owns no socket of its own to watch here - it is handed
    # a Database that is already connected - so its constructor is measured by
    # its SIDE EFFECT instead, against a real engine. It used to run a CREATE
    # TABLE IF NOT EXISTS: drop the table, construct the handler, and the table
    # must still be absent. A SECOND, INDEPENDENT connection asks, so this is a
    # real out-of-band observation rather than an assertion about code shape.
    #
    # SQLite is the engine because no service has to be reachable for the DDL
    # question to be meaningful; the same code path serves every engine.
    directory = Dir.mktmpdir("tina4-session-construction")
    begin
      database_path = File.join(directory, "construction.db")
      database = Tina4::Database.new("sqlite:///#{database_path}")
      database.execute("DROP TABLE IF EXISTS tina4_session")

      # DRIVER SANITY for the side-effect probe: a fresh connection must be able
      # to SEE a table in this file, or "the table is absent" proves nothing.
      database.execute("CREATE TABLE tina4_session_probe (id INTEGER)")
      expect(Tina4::Database.new("sqlite:///#{database_path}").table_exists?("tina4_session_probe")).to be(true),
                                                                                                       "an independent connection cannot see a table that definitely exists - the " \
                                                                                                       "probe below could not detect the DDL it is looking for"

      Tina4::SessionHandlers::DatabaseHandler.new(db: database)

      probe = Tina4::Database.new("sqlite:///#{database_path}")
      expect(probe.table_exists?("tina4_session")).to be(false),
                                                      "the DatabaseHandler CONSTRUCTOR created its table - real DDL on a real " \
                                                      "connection, outside the failure policy. Because Request#session builds a " \
                                                      "Session per request, that ran on EVERY request."
    ensure
      FileUtils.remove_entry(directory) if Dir.exist?(directory)
    end
  end

  # --- 2. DEFERRED IS NOT THE SAME AS NEVER ---------------------------------

  it "the_backend_connection_happens_on_first_use_not_construction" do
    # THE CASE THAT STOPS A FALSE FIX. "No I/O in the constructor" is trivially
    # satisfied by a handler that does no I/O at all, and example 1 would pass on
    # a store that never talks to anything. The FIRST OPERATION must dial.
    #
    # Deliberately symmetric with example 1: EVERY handler example 1 asserts is
    # silent at construction is asserted LIVE here. Asserting the two on
    # different sets would leave whichever handler only example 1 covers free to
    # be inert, which is the exact failure this example exists to catch.
    skip "mongo gem not installed" unless mongo_gem_available?

    with_counting_listener do |port, accepted|
      TCPSocket.new("127.0.0.1", port).close
      expect(wait_for_count(accepted, 1)).to be >= 1,
                                             "the counting listener never counted a REAL connection - the instrument is broken"

      socket_handlers(port).each do |name, build|
        handler = build.call
        settle
        before_operation = accepted.call

        begin
          # One real operation against the listener. It answers nothing useful,
          # so the handler will fail - that is fine and expected. We are
          # measuring the DIAL, not the conversation.
          begin
            handler.read("connection-probe-#{SecureRandom.hex(4)}")
          rescue StandardError
            nil
          end

          expect(wait_for_count(accepted, before_operation + 1)).to be > before_operation,
                                                                    "#{name}: the first operation opened NO connection - the handler is not " \
                                                                    "lazy, it is INERT, and example 1 would pass on a store that never talks " \
                                                                    "to anything."
        ensure
          # Mongo::Client owns a pool of real sockets and a background monitor
          # thread. #close exists precisely so a lazily-built client can still be
          # released; leaking one would break docstore_substitutability_spec's
          # connection-count gate. The socket-per-command handlers own nothing
          # to release and expose no #close.
          handler.close if handler.respond_to?(:close)
        end
      end
    end
  end

  # --- 3. NEGATIVE CONTROL: lazy must not mean broken -----------------------

  it "a_healthy_backend_still_works_after_lazy_connection" do
    # Deferring the connection must not BREAK the connection. Real Redis, real
    # MongoDB and a real SQLite file, all driven end to end. "No I/O in the
    # constructor" is not an achievement if the handler no longer works - and
    # this is where a deferred ensure_table / ensure_ttl_index that never runs
    # shows up.
    skip "mongo gem not installed" unless mongo_gem_available?

    mongo_host = mongo_uri[%r{//([^:/]+)}, 1] || "127.0.0.1"
    mongo_port = (mongo_uri[%r{//[^:/]+:(\d+)}, 1] || "27017").to_i

    unless service_reachable?(redis_host, redis_port)
      skip "redis is not reachable at #{redis_host}:#{redis_port}"
    end
    skip "mongodb is not reachable at #{mongo_host}:#{mongo_port}" unless service_reachable?(mongo_host, mongo_port)

    session_id = "lazyok-#{SecureRandom.hex(6)}"

    redis_handler = Tina4::SessionHandlers::RedisHandler.new(host: redis_host, port: redis_port, ttl: 60)
    begin
      redis_handler.write(session_id, { "seeded" => true })
      expect(redis_handler.read(session_id)).to eq({ "seeded" => true }),
                                                "the redis round-trip broke"
    ensure
      begin
        redis_handler.destroy(session_id)
      rescue StandardError
        nil
      end
    end

    mongo_handler = Tina4::SessionHandlers::MongoHandler.new(uri: mongo_uri, ttl: 60)
    begin
      mongo_handler.write(session_id, { "seeded" => true })
      expect(mongo_handler.read(session_id)).to eq({ "seeded" => true }),
                                                 "the mongodb round-trip broke - the client and the TTL index are now built on " \
                                                 "first use, so a lazy path that never runs shows up exactly here"
    ensure
      begin
        mongo_handler.destroy(session_id)
      rescue StandardError
        nil
      end
      mongo_handler.close
    end

    directory = Dir.mktmpdir("tina4-session-lazyok")
    begin
      database = Tina4::Database.new("sqlite:///#{File.join(directory, 'lazy.db')}")
      database_handler = Tina4::SessionHandlers::DatabaseHandler.new(db: database)
      database_handler.write(session_id, { "seeded" => true })

      expect(database_handler.read(session_id)).to eq({ "seeded" => true }),
                                                   "the database round-trip broke - the table is created on first use, so a " \
                                                   "deferred ensure_table that never runs shows up exactly here"
    ensure
      FileUtils.remove_entry(directory) if Dir.exist?(directory)
    end
  end
end
