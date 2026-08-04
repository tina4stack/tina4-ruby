# frozen_string_literal: true

require "securerandom"
require "socket"
require "tina4"

# SESSION CONTRACT: a TTL is expressed in ONE unit by the caller, whatever the
# provider.
#
# ADR-0024: the developer writes against the CONTRACT, never the PROVIDER. A ttl
# is a number of SECONDS. Each backend converts that to whatever its own wire
# protocol needs. Providers differ; the contract must not.
#
# WHY THIS FILE EXISTS - the memcached 30-day cliff, MEASURED, not read.
#
# memcached's `set` command takes an `exptime` field with a documented dual
# meaning: a value up to 2592000 (30 days) is RELATIVE seconds, and ANY LARGER
# VALUE IS AN ABSOLUTE UNIX TIMESTAMP. Tina4 interpolated the caller's ttl into
# that field raw, in all four frameworks, with no conversion anywhere - grep for
# 2592000 across python, php, ruby and nodejs returned ZERO hits on 2026-08-04.
#
# So TINA4_SESSION_TTL=2592001 - "about a month", an entirely ordinary
# remember-me setting - was sent as the absolute timestamp 2592001, which is
# 1970-01-31. The item was already expired at the moment it was stored.
# memcached still answers STORED, so the write looks successful and the very
# next read is a miss. Measured against real memcached 1.6.45:
#
#     ttl=60        read -> {"seeded" => true}   SURVIVES
#     ttl=2592000   read -> {"seeded" => true}   SURVIVES
#     ttl=2592001   read -> {}                   VANISHED INSTANTLY
#     ttl=4000000   read -> {}                   VANISHED INSTANTLY
#
# That is a silent logout on every request, from a config value that looks
# perfectly reasonable, and nothing anywhere reports it.
#
# THE FIX under test converts a ttl past the boundary into the absolute stamp
# the protocol is asking for (now + ttl), rather than CLAMPING to 2592000 -
# clamping would silently shorten a session the operator explicitly asked to be
# longer, which is the same class of lie in the other direction.
#
# NO MOCKS. Every assertion here runs against a real memcached, and the
# out-of-band checks open their own socket rather than asking the code under
# test.
RSpec.describe "session ttl units" do
  # Locals, not constants: a bare constant assigned inside RSpec.describe is
  # defined on Object and is GLOBAL - it has twice clobbered other spec files
  # here. The boundary constant that the FIX uses lives on the handler class
  # (Tina4::SessionHandlers::MemcachedHandler::MAX_RELATIVE_EXPTIME).
  host = ENV["TINA4_TEST_MEMCACHED_HOST"] || "127.0.0.1"
  port = (ENV["TINA4_TEST_MEMCACHED_PORT"] || 11_211).to_i

  # The protocol boundary itself. Anything at or below this is relative seconds;
  # anything above it is read as an absolute unix timestamp.
  relative_ttl_ceiling = 2_592_000

  reachable = begin
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  if !reachable && ENV["TINA4_REQUIRE_SERVICES"]
    raise "TINA4_REQUIRE_SERVICES is set but memcached is not reachable at #{host}:#{port}"
  end

  before do
    skip("memcached not reachable at #{host}:#{port}") unless reachable
  end

  # Read from a socket until +terminator+ arrives. Bounded, so a wedged server
  # fails the example instead of hanging the suite.
  read_until = lambda do |sock, terminator, seconds = 5|
    buffer = +""
    deadline = Time.now + seconds
    until buffer.include?(terminator)
      raise "timed out waiting for #{terminator.inspect}; got #{buffer.inspect}" if Time.now > deadline

      chunk = begin
        sock.read_nonblock(4096)
      rescue IO::WaitReadable
        sock.wait_readable(1)
        next
      rescue EOFError
        raise "connection closed before #{terminator.inspect}; got #{buffer.inspect}"
      end
      buffer << chunk
    end
    buffer
  end

  # Read the key over a socket THIS SPEC owns, not the handler's.
  #
  # A handler that lied about what it stored could not be caught by asking that
  # same handler to read it back.
  raw_get = lambda do |key|
    Socket.tcp(host, port, connect_timeout: 3) do |sock|
      sock.write("get #{key}\r\n")
      read_until.call(sock, "END\r\n")
    end
  end

  # Ask the SERVER how long it thinks the key has left, over our own socket.
  #
  # memcached 1.6's meta-get reports the remaining ttl: `mg <key> t v` answers
  # `VA <size> t<seconds>`. This is what makes the difference between CONVERTING
  # a long ttl and CLAMPING it visible - both survive a round trip, but only one
  # of them still has the lifetime the caller asked for.
  raw_remaining_ttl = lambda do |key|
    reply = Socket.tcp(host, port, connect_timeout: 3) do |sock|
      sock.write("mg #{key} t v\r\n")
      read_until.call(sock, "\r\n")
    end
    token = reply.split.find { |candidate| candidate.match?(/\At-?\d+\z/) }
    raise "no ttl in meta-get reply for #{key}: #{reply.inspect}" if token.nil?

    token[1..].to_i
  end

  let(:handler) do
    Tina4::SessionHandlers::MemcachedHandler.new(
      host: host, port: port, prefix: "tina4:test:ttlunits:"
    )
  end

  # A ttl past 30 days must still mean "that many SECONDS from now".
  #
  # This is the headline gate. Before the fix the record vanished the instant it
  # was written, because 2592001 was read as a moment in 1970.
  #
  # The 60-day case is what stops a CLAMP being mistaken for a fix. Clamping to
  # 2592000 also survives the round trip, so a survival-only assertion cannot
  # tell the two apart - but a clamp silently turns the 60-day session the
  # operator asked for into a 30-day one. Asking the server for the remaining
  # ttl makes that visible: convert reports ~5184000, clamp reports 2592000.
  it "session_ttl_above_the_memcached_thirty_day_boundary_survives" do
    [relative_ttl_ceiling + 1, 5_184_000].each do |over_the_boundary|
      session_id = "units-over-#{SecureRandom.hex(4)}"
      key = handler.send(:key, session_id)

      handler.write(session_id, { "seeded" => true }, over_the_boundary)
      begin
        expect(handler.read(session_id)).to(
          eq({ "seeded" => true }),
          "a ttl of #{over_the_boundary}s expired the session instantly - " \
          "memcached read it as an absolute timestamp in 1970"
        )

        # Out of band: the server really holds it, on a socket we opened.
        expect(raw_get.call(key)).to(
          start_with("VALUE"),
          "the handler claimed the session was stored but the server does not have it"
        )

        remaining = raw_remaining_ttl.call(key)
        expect((remaining - over_the_boundary).abs).to(
          be < 60,
          "asked for a #{over_the_boundary}s session; the server says #{remaining}s " \
          "remain. A clamp to the 30-day ceiling silently shortens a lifetime the " \
          "operator explicitly asked to be longer."
        )
      ensure
        handler.destroy(session_id)
      end
    end
  end

  # BOUNDARY CONTROL: exactly 2592000 is still legal relative seconds.
  #
  # Pins which side of the cliff the conversion starts on. A fix that converted
  # at or below the boundary would still be wrong, just less obviously.
  it "session_ttl_at_the_memcached_thirty_day_boundary_survives" do
    session_id = "units-at-#{SecureRandom.hex(4)}"

    handler.write(session_id, { "seeded" => true }, relative_ttl_ceiling)
    begin
      expect(handler.read(session_id)).to(
        eq({ "seeded" => true }),
        "a ttl of exactly #{relative_ttl_ceiling}s is the largest legal RELATIVE " \
        "exptime and must round-trip untouched"
      )
    ensure
      handler.destroy(session_id)
    end
  end

  # NEGATIVE CONTROL: a short ttl must still expire, for real.
  #
  # Without this, "never send an expiry at all" passes both cases above and
  # ships a session store where nothing ever expires - which on a session store
  # is a security defect, not a convenience.
  it "session_ttl_below_the_boundary_still_really_expires" do
    session_id = "units-short-#{SecureRandom.hex(4)}"
    key = handler.send(:key, session_id)

    handler.write(session_id, { "seeded" => true }, 1)
    expect(handler.read(session_id)).to(eq({ "seeded" => true }), "the record was never stored")

    sleep 3 # REAL wall clock, past the 1s ttl. No clock stubbing.

    expect(handler.read(session_id)).to(
      eq({}),
      "a 1-second ttl did not expire - the conversion turned every ttl into 'never expires'"
    )
    expect(raw_get.call(key)).to(
      eq("END\r\n"),
      "the server still holds the key after it should have expired"
    )
  end
end
