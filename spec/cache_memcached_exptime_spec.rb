# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# CACHE CONTRACT - memcached's 30-day exptime cliff.
#
# memcached reads the `set` exptime field as RELATIVE seconds at or below
# 2592000 (30 days), and as an ABSOLUTE UNIX TIMESTAMP above it.
# MemcachedBackend#set interpolated the caller's ttl RAW, so any TINA4_CACHE_TTL
# over 30 days made every cache write vanish the instant it landed: the caller
# wrote a number of seconds and the server read a date in 1970. memcached still
# answers STORED, so it presented as a 100% miss rate with nothing logged - a
# cache that looks like it is working and never returns a hit.
#
# MEASURED on the real memcached 1.6.45 used by these examples, before the fix:
#   ttl=60       -> get returns the value
#   ttl=2592000  -> get returns the value
#   ttl=2592001  -> get returns nil   (vanished instantly)
#   ttl=5184000  -> get returns nil   (vanished instantly)
#
# THE FIX IS CONVERT, NEVER CLAMP. Clamping a too-large ttl down to 2592000 also
# makes the entry survive, and is ALSO wrong: it silently discards more than half
# the lifetime the operator explicitly configured - the same class of
# silent-wrong-answer as the bug it replaces.
#
# WHICH IS WHY SURVIVAL ALONE IS NOT A TEST. A case that only checks "the value
# is still there" passes under a CLAMP exactly as it does under a CONVERT, so it
# cannot tell the right fix from the wrong one. These examples read the SERVER's
# own reported remaining lifetime with `mg <key> t v` -> `VA <len> t<seconds>`
# (memcached 1.6+). And the boundary case cannot stand in for it either:
# |2592000 - 2592001| = 1, which is inside any sane tolerance, so a
# just-past-the-cliff value passes a clamp check. The 60-day case is the
# load-bearing one for telling CONVERT from CLAMP.
#
# Nothing here is simulated: every assertion is answered by the real memcached
# over a real socket, and the expiry case uses a real wall-clock sleep.
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheMemcachedExptimeContract
  MEMCACHED_URL = ENV.fetch("TINA4_TEST_CACHE_MEMCACHED_URL", "memcached://127.0.0.1:11211")
  # memcached's own cliff: at or below this many seconds the field is relative,
  # above it the field is an absolute unix timestamp.
  CLIFF = 2_592_000
  SIXTY_DAYS = 5_184_000

  module_function

  def backend
    Tina4::CacheBackends.create_backend(backend: "memcached", url: MEMCACHED_URL)
  end

  def unique_key(label)
    "exptime-#{label}-#{SecureRandom.hex(10)}"
  end

  # Ask the SERVER how much life it thinks the entry has left.
  #
  # `mg <key> t v` returns "VA <len> t<seconds>\r\n<data>\r\n" on memcached 1.6+
  # (t-1 means no expiry). This is the only observable that separates a CONVERT
  # from a CLAMP, because both leave the entry readable.
  def server_remaining_ttl(backend, key)
    reply = backend.send(:command, "mg #{backend.send(:mc_key, key)} t v\r\n", "\r\n")
    match = reply.match(/\bt(-?\d+)/)
    raise "memcached did not report a ttl for #{key} (reply: #{reply.inspect})" unless match

    match[1].to_i
  end

  # The backend's own write log, which stats reads.
  def own_expiry(backend, key)
    backend.instance_variable_get(:@own)[backend.send(:mc_key, key)]
  end
end

RSpec.describe "cache memcached exptime" do
  it "a ttl beyond the thirty day cliff survives" do
    backend = CacheMemcachedExptimeContract.backend
    key = CacheMemcachedExptimeContract.unique_key("beyond")

    backend.set(key, { "row" => "long lived" }, CacheMemcachedExptimeContract::SIXTY_DAYS)

    expect(backend.get(key)).to eq({ "row" => "long lived" }),
                                "a ttl over 30 days was sent to memcached RAW, so the server read it as an " \
                                "absolute unix timestamp (a date in 1970) and dropped the entry the instant it " \
                                "landed. memcached still answers STORED, so this presents as a 100% miss rate " \
                                "with nothing logged."
  end

  it "a ttl beyond the cliff keeps its full lifetime" do
    backend = CacheMemcachedExptimeContract.backend
    key = CacheMemcachedExptimeContract.unique_key("fulllife")
    asked = CacheMemcachedExptimeContract::SIXTY_DAYS

    backend.set(key, { "row" => "long lived" }, asked)

    remaining = CacheMemcachedExptimeContract.server_remaining_ttl(backend, key)
    expect(remaining).to be_within(60).of(asked),
                         "the server reports #{remaining}s left but #{asked}s was configured. This is the case " \
                         "that separates CONVERT from CLAMP: clamping to the 30-day cliff also leaves the entry " \
                         "readable, and silently discards more than half the lifetime the operator asked for."
  end

  it "the thirty day boundary itself stays relative" do
    backend = CacheMemcachedExptimeContract.backend
    key = CacheMemcachedExptimeContract.unique_key("boundary")
    asked = CacheMemcachedExptimeContract::CLIFF

    # ASSERT ON THE COMPUTED EXPTIME, not only on the round trip.
    #
    # A RELATIVE 2592000 and an ABSOLUTE Time.now.to_i + 2592000 produce the
    # SAME deadline, so memcached reports an identical t2592000 for both. Any
    # boundary assertion built only on the server's reported remaining lifetime
    # is blind to this off-by-one BY CONSTRUCTION - MEASURED: mutating
    # `ttl > MAX_RELATIVE_EXPTIME` to `ttl >= MAX_RELATIVE_EXPTIME` applied
    # cleanly and left this whole file GREEN until these three lines existed.
    #
    # exptime is a pure function over its inputs, so this needs no service and
    # uses no stand-in.
    expect(backend.send(:exptime, asked)).to eq(asked),
                                             "exptime(#{asked}) returned #{backend.send(:exptime, asked)} - " \
                                             "exactly 2592000 is still RELATIVE to memcached, so converting AT " \
                                             "the boundary instead of ABOVE it is an off-by-one"
    expect(backend.send(:exptime, asked - 1)).to eq(asked - 1), "just below the cliff must stay relative"
    expect(backend.send(:exptime, asked + 1)).to be > Time.now.to_i,
                                                  "just above the cliff must become an absolute unix timestamp"

    # And the real round trip still has to work.
    backend.set(key, { "row" => "exactly thirty days" }, asked)

    expect(backend.get(key)).to eq({ "row" => "exactly thirty days" })
    remaining = CacheMemcachedExptimeContract.server_remaining_ttl(backend, key)
    expect(remaining).to be_within(60).of(asked),
                         "the boundary value lost lifetime: asked #{asked}s, server reports #{remaining}s"
  end

  it "a short ttl still expires" do
    backend = CacheMemcachedExptimeContract.backend
    key = CacheMemcachedExptimeContract.unique_key("short")

    backend.set(key, { "row" => "brief" }, 1)
    expect(backend.get(key)).to eq({ "row" => "brief" }), "precondition: the entry was stored"

    # 3.0s, not 2.2s. memcached compares against its own `current_time`, which a
    # clock event advances once a SECOND, so an item written with exptime=1 can
    # legitimately survive nearly 2s of wall clock. A 2.2s sleep leaves 0.2s of
    # margin and FAILED once in three runs here; 3.0s leaves a full second.
    sleep 3.0

    expect(backend.get(key)).to be_nil,
                                "NEGATIVE CONTROL: a 1 second ttl must really expire. A fix that converted every " \
                                "ttl to an absolute stamp, or that stopped sending an expiry at all, would make " \
                                "every entry immortal and still pass every case above."
  end

  it "the local write log uses the raw ttl" do
    backend = CacheMemcachedExptimeContract.backend
    key = CacheMemcachedExptimeContract.unique_key("writelog")
    asked = CacheMemcachedExptimeContract::SIXTY_DAYS
    before = Time.now.to_f

    backend.set(key, { "row" => "long lived" }, asked)

    recorded = CacheMemcachedExptimeContract.own_expiry(backend, key)
    expect(recorded).to be_within(60).of(before + asked),
                        "the shadow map recorded #{recorded} (#{Time.at(recorded).utc.year}) instead of roughly " \
                        "#{(before + asked).to_i}. Handing the CONVERTED absolute stamp to `Time.now.to_f + " \
                        "exptime` computes now + (now + ttl) - about twice the current epoch, a date in 2076. It " \
                        "fails SILENTLY: the shadow map never expires anything, so the local bookkeeping stops " \
                        "matching what the server holds and stats reports expired entries as live forever."
  end
end
