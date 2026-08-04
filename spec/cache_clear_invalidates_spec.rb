# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# CACHE CONTRACT - clear() really invalidates, on EVERY provider.
#
# Pins `clear-really-invalidates-on-every-provider` from
# plan/v3/fixtures/cache_contract.json (ADR-0024):
#
#   clear() removes every entry this cache can serve, on EVERY provider. It is
#   never a no-op, and never limited to the keys the local process happens to
#   have written.
#
# WHY THIS FILE EXISTS AND THE EXISTING CACHE SPECS DID NOT CATCH IT
#   RedisBackend has TWO transports: the `redis` gem when it is installed, and a
#   raw RESP socket otherwise. The raw path is what a ZERO-DEPENDENCY install
#   runs - every developer's first install, and what ADR-0024 rule 4 says counts
#   double. Its clear() was a comment saying "rely on TTL" and no code at all.
#   MemcachedBackend's clear() deleted only the keys THIS process had written,
#   so a second instance kept serving rows the first had just invalidated.
#
#   Nothing here is mocked. Every assertion is answered by a real Redis / Valkey
#   / Memcached over a real TCP socket. Pinning WHICH of the two shipped
#   transports runs is configuration, not a stand-in.
#
# SERVICE ADDRESSES
#   Default to localhost; override per service so a developer (or a second
#   agent) can point at their own isolated containers:
#       TINA4_TEST_REDIS_URL      (default redis://127.0.0.1:6379)
#       TINA4_TEST_VALKEY_URL     (default valkey://127.0.0.1:6380)
#       TINA4_TEST_MEMCACHED_URL  (default memcached://127.0.0.1:11211)
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheClearContract
  REDIS_URL = ENV.fetch("TINA4_TEST_REDIS_URL", "redis://127.0.0.1:6379")
  VALKEY_URL = ENV.fetch("TINA4_TEST_VALKEY_URL", "valkey://127.0.0.1:6380")
  MEMCACHED_URL = ENV.fetch("TINA4_TEST_MEMCACHED_URL", "memcached://127.0.0.1:11211")

  module_function

  # Pin a redis/valkey backend to the ZERO-DEPENDENCY RESP transport.
  #
  # Not a mock: the backend still opens a real TCP socket to the real server and
  # speaks real RESP. This only selects WHICH of the two shipped transports
  # runs, so the default-install path is covered even on a machine where the
  # `redis` gem happens to be installed.
  def raw(backend)
    backend.instance_variable_set(:@client, nil)
    backend.instance_variable_set(:@use_raw, true)
    backend
  end

  def unique_key
    "contract-#{SecureRandom.hex(16)}"
  end

  # Write `count` entries over ONE real RESP session, using the backend's own
  # encoder and the exact SETEX command its set() issues for a positive TTL.
  #
  # Not a shortcut around the code under test - clear() is what is under test,
  # and these are byte-identical to entries set() writes (the examples read a
  # sample back through backend.get to prove it). Going through set() would open
  # a fresh TCP connection per key: 1500 of them measured 22.9s against 0.1s
  # pipelined, and the point of the volume is the SCAN cursor, not the socket.
  def bulk_set(backend, marker, count, ttl: 300)
    sock = backend.send(:resp_session)
    begin
      count.times do |index|
        sock.write(backend.send(:resp_encode, "SETEX", bulk_key(marker, index), ttl.to_s,
                                JSON.generate({ "i" => index })))
      end
      count.times { backend.send(:resp_read, sock) }
    ensure
      sock.close
    end
  end

  def bulk_key(marker, index)
    "#{Tina4::CacheBackends::RedisBackend::PREFIX}contract-#{marker}-#{index}"
  end

  def bulk_pattern(marker)
    "#{Tina4::CacheBackends::RedisBackend::PREFIX}contract-#{marker}-*"
  end

  # Read/write a key OUTSIDE the tina4 prefix, over the backend's own real
  # connection, so the negative cases can prove another tenant survived.
  def outsider_set(backend, key, value)
    backend.send(:resp_command, "SET", key, value)
  end

  def outsider_get(backend, key)
    backend.send(:resp_command, "GET", key)
  end

  def outsider_delete(backend, key)
    backend.send(:resp_command, "DEL", key)
  end

  def memcached_outsider_set(backend, key, value)
    backend.send(:command, "set #{key} 0 300 #{value.bytesize}\r\n#{value}\r\n", "\r\n")
  end

  def memcached_outsider_get(backend, key)
    backend.send(:command, "get #{key}\r\n", "END\r\n")
  end

  def memcached_outsider_delete(backend, key)
    backend.send(:command, "delete #{key}\r\n", "\r\n")
  end
end

RSpec.describe "cache clear invalidates" do
  # ---- redis / valkey (raw RESP transport - the zero-dependency default) ----

  it "clear on the raw resp transport is not a no op" do
    backend = CacheClearContract.raw(Tina4::CacheBackends::RedisBackend.new(url: CacheClearContract::REDIS_URL))
    key = CacheClearContract.unique_key

    backend.set(key, { "row" => "before" }, 300)
    expect(backend.get(key)).to eq({ "row" => "before" }),
                                 "precondition failed: the real redis at #{CacheClearContract::REDIS_URL} " \
                                 "did not store the value over the raw RESP transport"

    backend.clear

    expect(backend.get(key)).to be_nil,
                                "clear() left the entry readable on the raw RESP transport - it is a no-op, " \
                                "so a write never invalidates the cache and every instance serves pre-write rows"
  end

  it "clear removes entries written by another instance" do
    writer = CacheClearContract.raw(Tina4::CacheBackends::RedisBackend.new(url: CacheClearContract::REDIS_URL))
    clearer = CacheClearContract.raw(Tina4::CacheBackends::RedisBackend.new(url: CacheClearContract::REDIS_URL))
    key = CacheClearContract.unique_key

    writer.set(key, { "row" => "from-instance-a" }, 300)
    expect(clearer.get(key)).to eq({ "row" => "from-instance-a" }),
                                 "precondition failed: two backends on one redis must see the same key"

    clearer.clear

    expect(writer.get(key)).to be_nil,
                               "clear() on instance B left instance A's entry readable - cross-instance " \
                               "invalidation does not hold, so B serves stale rows after A wrote"
  end

  it "clear leaves another tenants keys untouched" do
    backend = CacheClearContract.raw(Tina4::CacheBackends::RedisBackend.new(url: CacheClearContract::REDIS_URL))
    outsider_key = "someone-elses-app:#{SecureRandom.hex(16)}"

    CacheClearContract.outsider_set(backend, outsider_key, "not-ours")
    backend.set(CacheClearContract.unique_key, { "row" => 1 }, 300)

    backend.clear

    survived = CacheClearContract.outsider_get(backend, outsider_key)
    CacheClearContract.outsider_delete(backend, outsider_key)
    expect(survived).to eq("not-ours"),
                        "clear() destroyed a key OUTSIDE the tina4 prefix - it is flushing the whole server " \
                        "(FLUSHALL/FLUSHDB), which takes every other tenant's data with it"
  end

  it "clear removes many entries not just the first page" do
    backend = CacheClearContract.raw(Tina4::CacheBackends::RedisBackend.new(url: CacheClearContract::REDIS_URL))
    marker = SecureRandom.hex(8)
    # 1500, not a token handful. MEASURED against the real Redis 7.4.10 here:
    # 250 keys come back in ONE SCAN page (cursor 0 on the first call), so a
    # smaller set cannot tell a correct cursor loop from one that stops after
    # the first page - a single-page mutation stayed green at 250. At 1500 the
    # first page returns roughly 300-400 keys with a non-zero cursor, so the
    # loop must actually iterate.
    count = 1500
    backend.clear
    CacheClearContract.bulk_set(backend, marker, count)

    # These really are entries this cache can serve, in its own key shape.
    expect(backend.get("contract-#{marker}-0")).to eq({ "i" => 0 })
    expect(backend.get("contract-#{marker}-#{count - 1}")).to eq({ "i" => count - 1 })

    # Precondition AND the truncation gate: this multi-bulk reply is ~75KB, over
    # the 64KB the old single-recv reader could hold. A reader that truncates
    # returns a SHORT list here and fails before the clear is even attempted,
    # so a truncated reply can never masquerade as a successful clear below.
    before = backend.send(:resp_command, "KEYS", CacheClearContract.bulk_pattern(marker))
    expect(before.size).to eq(count),
                           "the KEYS multi-bulk reply came back with #{before.size} of #{count} entries - " \
                           "a reply larger than one socket read is being truncated instead of assembled"

    backend.clear

    survivors = backend.send(:resp_command, "KEYS", CacheClearContract.bulk_pattern(marker))
    expect(survivors).to be_empty,
                         "#{survivors.size} of #{count} entries survived clear() - the SCAN cursor loop " \
                         "stopped after the first page instead of walking the whole keyspace"
  end

  # Regression test for a parity fix, NOT one of the eight declared invariants -
  # deliberately not in the contract fixture.
  #
  # RedisBackend#stats hardcoded `size = 0` unless the `redis` GEM was loaded, so
  # on the ZERO-DEPENDENCY raw RESP transport - the default install - it reported
  # 0 no matter how many entries were cached. That is the same root cause as the
  # clear() no-op above: the persistent-layer assertions built on stats[:size]
  # could never have been true on a zero-dependency install, and were only ever
  # green because a driver happened to be present. Found in Ruby, present
  # identically in Python.
  it "stats reports a real size on both transports" do
    backend = CacheClearContract.raw(Tina4::CacheBackends::RedisBackend.new(url: CacheClearContract::REDIS_URL))
    backend.clear

    expect(backend.stats[:size]).to eq(0), "a cleared cache must report 0 entries, not a hardcoded constant"

    3.times { |index| backend.set("#{CacheClearContract.unique_key}-#{index}", { "i" => index }, 300) }

    expect(backend.stats[:size]).to eq(3),
                                    "three entries were written and stats reports #{backend.stats[:size]} - the " \
                                    "size is a hardcoded 0 on the raw RESP transport, so every dashboard, " \
                                    "db.cache_stats and operator check reading it is reading a constant"

    backend.clear

    expect(backend.stats[:size]).to eq(0), "stats did not return to 0 after a clear"
  end

  it "clear invalidates on valkey too" do
    backend = CacheClearContract.raw(Tina4::CacheBackends::ValkeyBackend.new(url: CacheClearContract::VALKEY_URL))
    key = CacheClearContract.unique_key

    backend.set(key, { "row" => "before" }, 300)
    expect(backend.get(key)).to eq({ "row" => "before" }),
                                 "precondition failed: the real valkey at #{CacheClearContract::VALKEY_URL} " \
                                 "did not store the value over the raw RESP transport"

    backend.clear

    expect(backend.get(key)).to be_nil, "clear() is a no-op on valkey's raw RESP transport"
  end

  # ---- memcached (namespace generation) ----

  it "memcached clear invalidates for a second instance" do
    writer = Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL)
    clearer = Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL)
    key = CacheClearContract.unique_key

    writer.set(key, { "row" => "from-instance-a" }, 300)
    expect(clearer.get(key)).to eq({ "row" => "from-instance-a" }),
                                 "precondition failed: two backends on one memcached must see the same key"

    clearer.clear

    expect(writer.get(key)).to be_nil,
                               "clear() on instance B left instance A's entry readable - memcached clear() " \
                               "only deletes what the LOCAL process wrote, so a second instance serves stale rows"
  end

  it "memcached clear leaves another tenants keys untouched" do
    backend = Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL)
    outsider_key = "someone-elses-app-#{SecureRandom.hex(16)}"

    CacheClearContract.memcached_outsider_set(backend, outsider_key, "not-ours")
    backend.set(CacheClearContract.unique_key, { "row" => 1 }, 300)

    backend.clear

    survived = CacheClearContract.memcached_outsider_get(backend, outsider_key)
    CacheClearContract.memcached_outsider_delete(backend, outsider_key)
    expect(survived).to include("not-ours"),
                        "clear() destroyed a key outside the tina4 namespace - it is flushing the whole " \
                        "memcached instance (flush_all), not this cache"
  end

  it "memcached entries written before a clear stay invalid" do
    writer = Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL)
    key = CacheClearContract.unique_key

    writer.set(key, { "row" => "before" }, 300)
    writer.clear

    fresh = Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL)
    expect(fresh.get(key)).to be_nil,
                              "a process that started AFTER the clear can still read the cleared entry - " \
                              "the invalidation never reached the shared server"

    # The namespace must stay usable, not be permanently poisoned.
    writer.set(key, { "row" => "after" }, 300)
    expect(Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL).get(key))
      .to eq({ "row" => "after" })
  end

  it "memcached clear does not strand live entries from other keys" do
    backend = Tina4::CacheBackends::MemcachedBackend.new(url: CacheClearContract::MEMCACHED_URL)
    backend.clear
    keys = Array.new(5) { CacheClearContract.unique_key }

    keys.each_with_index { |key, index| backend.set(key, { "i" => index }, 300) }

    keys.each_with_index do |key, index|
      expect(backend.get(key)).to eq({ "i" => index }),
                                   "write and read disagree about the generation after a clear - the bump " \
                                   "left the backend unusable"
    end
    expect(backend.stats[:size]).to eq(keys.size)
  end
end
