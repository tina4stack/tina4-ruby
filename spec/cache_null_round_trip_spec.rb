# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "securerandom"

# CACHE CONTRACT - a cached null round-trips as null.
#
# Pins `a-cached-null-round-trips-as-null` from
# plan/v3/fixtures/cache_contract.json (ADR-0024):
#
#   A cached value of null/None/nil comes back as that value, not as the storage
#   envelope that wrapped it, and not as a miss.
#
# The measured defect was NODE's: its file backend handed back the storage
# ENVELOPE ({key, value, expiresAt}) instead of the value when the cached value
# was null, because it read `data.value ?? data`. The caller received an object
# where it had stored nothing, so `if (cached)` was TRUE for a cached null and
# the cache turned an absence into a presence. Caching "this lookup found
# nothing" is the single most common reason to cache a null, so the wrong answer
# was served exactly where the feature is used.
#
# MEASURED IN RUBY AT HEAD and confirmed correct on all seven providers, so this
# file is a PARITY LOCK-IN: it exists so Ruby can never regress into Node's bug,
# and it is mutation-proven so it stays a real gate rather than decoration.
#
# A note on what "not as a miss" can mean here. In Ruby, as in Python, nil IS
# the miss sentinel of the backend contract, so a caller cannot separate the two
# from the return value alone. The observable that DOES separate them is the
# backend's own hit/miss accounting, which is public through stats, so that is
# what these examples assert. The stronger form - a distinguishable sentinel or
# a default: parameter, which is what Rails and Django expose - is a contract
# change beyond this invariant and is recorded as owed rather than smuggled in.
#
# Every backend here is REAL. Nothing is simulated.
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheNullContract
  REDIS_URL = ENV.fetch("TINA4_TEST_CACHE_REDIS_URL", "redis://127.0.0.1:6379")
  VALKEY_URL = ENV.fetch("TINA4_TEST_CACHE_VALKEY_URL", "valkey://127.0.0.1:6380")
  MEMCACHED_URL = ENV.fetch("TINA4_TEST_CACHE_MEMCACHED_URL", "memcached://127.0.0.1:11211")
  MONGO_URL = ENV.fetch("TINA4_TEST_CACHE_MONGO_URL", "mongodb://127.0.0.1:27017")

  module_function

  # Every provider the framework offers, each a REAL one.
  def every_backend(tmp, tag)
    {
      "memory" => Tina4::CacheBackends.create_backend(backend: "memory"),
      "file" => Tina4::CacheBackends.create_backend(backend: "file", cache_dir: File.join(tmp, "fc-#{tag}")),
      "database" => Tina4::CacheBackends.create_backend(backend: "database",
                                                        url: "sqlite:///#{File.join(tmp, "c-#{tag}.db")}"),
      "redis" => Tina4::CacheBackends.create_backend(backend: "redis", url: REDIS_URL),
      "valkey" => Tina4::CacheBackends.create_backend(backend: "valkey", url: VALKEY_URL),
      "memcached" => Tina4::CacheBackends.create_backend(backend: "memcached", url: MEMCACHED_URL),
      "mongodb" => Tina4::CacheBackends.create_backend(backend: "mongodb",
                                                       url: "#{MONGO_URL}/tina4_cache_contract_rb")
    }
  end

  def unique_key(prefix)
    "#{prefix}-#{SecureRandom.hex(12)}"
  end
end

RSpec.describe "cache null round trip" do
  around(:each) do |example|
    Dir.mktmpdir("tina4-null") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  it "a cached null comes back as null" do
    CacheNullContract.every_backend(@tmp, "asnull").each do |label, backend|
      key = CacheNullContract.unique_key("null")
      backend.set(key, nil, 300)

      expect(backend.get(key)).to be_nil,
                                  "#{label} (#{backend.name}) returned #{backend.get(key).inspect} for a cached " \
                                  "null - the caller gets something where it stored nothing"
    end
  end

  it "a cached null is not the storage envelope" do
    CacheNullContract.every_backend(@tmp, "envelope").each do |label, backend|
      key = CacheNullContract.unique_key("null")
      backend.set(key, nil, 300)

      got = backend.get(key)

      expect(got).not_to be_a(Hash),
                         "#{label} (#{backend.name}) returned the storage ENVELOPE #{got.inspect} instead of the " \
                         "cached null"
      expect(got).to be_falsey,
                     "#{label} (#{backend.name}) made a cached null TRUTHY, so every `if cached` guard in every " \
                     "application inverts for a value that is absent"
    end
  end

  it "a cached null is a hit not a miss" do
    CacheNullContract.every_backend(@tmp, "hit").each do |label, backend|
      backend.clear
      key = CacheNullContract.unique_key("null")
      backend.set(key, nil, 300)
      before = backend.stats

      backend.get(key)

      after = backend.stats
      expect(after[:hits]).to eq(before[:hits] + 1),
                             "#{label} (#{backend.name}) did not count a cached null as a HIT"
      expect(after[:misses]).to eq(before[:misses]),
                               "#{label} (#{backend.name}) counted a cached null as a MISS - the cache cannot " \
                               "tell 'we looked and found nothing' from 'we never looked', which is the whole " \
                               "reason to cache a null"
    end
  end

  it "a missing key is still a miss" do
    CacheNullContract.every_backend(@tmp, "miss").each do |label, backend|
      backend.clear
      before = backend.stats

      expect(backend.get(CacheNullContract.unique_key("never-written"))).to be_nil

      after = backend.stats
      expect(after[:misses]).to eq(before[:misses] + 1),
                               "#{label} (#{backend.name}) did not count an absent key as a MISS - the obvious " \
                               "wrong fix for the null path is to always report a hit, which satisfies every " \
                               "example above and destroys the cache's accounting"
      expect(after[:hits]).to eq(before[:hits]),
                             "#{label} (#{backend.name}) counted an absent key as a HIT"
    end
  end

  it "other falsy values round trip intact" do
    CacheNullContract.every_backend(@tmp, "falsy").each do |label, backend|
      { "false" => false, "zero" => 0, "empty-string" => "",
        "empty-array" => [], "empty-hash" => {} }.each do |name, value|
        key = CacheNullContract.unique_key("falsy-#{name}")
        backend.set(key, value, 300)

        got = backend.get(key)

        expect(got).to eq(value),
                       "#{label} (#{backend.name}) mangled a cached #{name}: stored #{value.inspect}, got " \
                       "#{got.inspect} - a null fix built on falsiness breaks every one of these, and each is a " \
                       "perfectly ordinary thing to cache"
        expect(got.class).to eq(value.class),
                             "#{label} (#{backend.name}) changed the TYPE of a cached #{name}: stored a " \
                             "#{value.class}, got a #{got.class}"
      end
    end
  end
end
