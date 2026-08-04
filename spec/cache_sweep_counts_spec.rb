# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# CACHE CONTRACT - sweep returns a real count, everywhere.
#
# Pins `sweep-returns-a-real-count-everywhere` from
# plan/v3/fixtures/cache_contract.json (ADR-0024):
#
#   sweep() evicts expired entries and returns how many it evicted, on every
#   provider.
#
# MEASURED IN RUBY AT HEAD, and this is Ruby's headline defect on this contract:
# only FileBackend defined sweep. base_backend, memory, redis, valkey,
# memcached, mongo and database did not, so sweep raised
#
#   NoMethodError: undefined method 'sweep' for an instance of
#   Tina4::CacheBackends::MemoryBackend
#
# on 6 of 7 providers. A method that exists on one provider and blows up on six
# is not a swappable API. ResponseCache#sweep had grown the caller-side
# workaround that always follows - `elsif @backend.respond_to?(:sweep)` with an
# `else 0` - and a caller that has to ask cannot tell "not supported" from
# "evicted nothing".
#
# AND the defect found while proving it, in the reference implementation and
# mirrored here: the DATABASE backend expires nothing by itself. redis, valkey,
# memcached and mongodb expire entries SERVER-SIDE, so 0 is the honest answer
# for them - nothing was evicted because there was nothing left to evict. A SQL
# table is different: rows were only deleted when someone happened to read that
# exact key again, so expired rows accumulated forever and the one API whose job
# is to reclaim them reported 0 and did nothing.
#
# Every backend here is REAL - a real in-process store, a real directory on
# disk, a real SQLite database, and the real network services. Nothing is
# simulated.
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheSweepContract
  REDIS_URL = ENV.fetch("TINA4_TEST_CACHE_REDIS_URL", "redis://127.0.0.1:6379")
  VALKEY_URL = ENV.fetch("TINA4_TEST_CACHE_VALKEY_URL", "valkey://127.0.0.1:6380")
  MEMCACHED_URL = ENV.fetch("TINA4_TEST_CACHE_MEMCACHED_URL", "memcached://127.0.0.1:11211")
  MONGO_URL = ENV.fetch("TINA4_TEST_CACHE_MONGO_URL", "mongodb://127.0.0.1:27017")

  module_function

  # The three providers that hold entries LOCALLY and therefore expire nothing
  # on their own. Their counts must be exact.
  def local_backends(tmp, tag)
    {
      "memory" => Tina4::CacheBackends.create_backend(backend: "memory"),
      "file" => Tina4::CacheBackends.create_backend(backend: "file", cache_dir: File.join(tmp, "fc-#{tag}")),
      "database" => Tina4::CacheBackends.create_backend(backend: "database",
                                                        url: "sqlite:///#{File.join(tmp, "c-#{tag}.db")}")
    }
  end

  # Every provider the framework offers, each a REAL one. The network services
  # are required, not optional: a skip is a failure under
  # TINA4_REQUIRE_SERVICES, and this contract is about EVERY provider.
  def all_backends(tmp, tag)
    local_backends(tmp, tag).merge(
      "redis" => Tina4::CacheBackends.create_backend(backend: "redis", url: REDIS_URL),
      "valkey" => Tina4::CacheBackends.create_backend(backend: "valkey", url: VALKEY_URL),
      "memcached" => Tina4::CacheBackends.create_backend(backend: "memcached", url: MEMCACHED_URL),
      "mongodb" => Tina4::CacheBackends.create_backend(backend: "mongodb",
                                                       url: "#{MONGO_URL}/tina4_cache_contract_rb")
    )
  end
end

RSpec.describe "cache sweep counts" do
  around(:each) do |example|
    Dir.mktmpdir("tina4-sweep") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  it "sweep is available on every provider" do
    CacheSweepContract.all_backends(@tmp, "avail").each do |label, backend|
      # A backend asked for an unreachable service degrades to file by design,
      # so assert on what we actually got rather than the label we asked for.
      result = begin
        backend.sweep
      rescue NoMethodError => e
        raise "#{label} (#{backend.name}) has no sweep at all: #{e.message}"
      end

      expect(result).to be_a(Integer),
                        "#{label} (#{backend.name}).sweep returned #{result.inspect}, not an integer count - " \
                        "a method that exists on one provider and raises on the rest is not a swappable API"
      expect(result).to be >= 0, "#{label} (#{backend.name}).sweep returned a negative count"
    end
  end

  it "sweep returns the number of entries it evicted" do
    CacheSweepContract.local_backends(@tmp, "count").each do |label, backend|
      backend.clear
      3.times { |index| backend.set("doomed-#{index}", { "i" => index }, 1) }
      backend.set("survivor", { "i" => "keep" }, 300)
      sleep 1.2

      evicted = backend.sweep

      expect(evicted).to eq(3),
                         "#{label}.sweep reported #{evicted} evictions, expected 3 - the number a monitoring " \
                         "dashboard reads is not the number of entries actually reclaimed"
      expect(backend.get("survivor")).to eq({ "i" => "keep" }), "#{label}.sweep removed a LIVE entry"
    end
  end

  it "sweep evicts expired entries from the database backend" do
    backend = Tina4::CacheBackends.create_backend(backend: "database",
                                                  url: "sqlite:///#{File.join(@tmp, 'sweep.db')}")
    backend.clear
    4.times { |index| backend.set("expired-#{index}", { "i" => index }, 1) }
    backend.set("live", { "i" => "live" }, 300)
    sleep 1.2
    expect(backend.stats[:size]).to eq(5), "precondition: the expired rows are still on disk"

    evicted = backend.sweep

    expect(evicted).to eq(4), "sweep reported #{evicted}, expected 4 expired rows"
    expect(backend.stats[:size]).to eq(1),
                                    "the expired rows are still in the tina4_cache table - a SQL table does not " \
                                    "expire anything by itself, so rows accumulate forever and the one API whose " \
                                    "job is to reclaim them did nothing"
  end

  it "sweep returns zero when nothing has expired" do
    CacheSweepContract.local_backends(@tmp, "zero").each do |label, backend|
      backend.clear
      3.times { |index| backend.set("live-#{index}", { "i" => index }, 300) }

      expect(backend.sweep).to eq(0),
                               "#{label}.sweep reported evictions with nothing expired - it is returning the " \
                               "number it inspected, or the total entry count, not the number it evicted"
      expect(backend.stats[:size]).to eq(3), "#{label}.sweep deleted live entries"
    end
  end

  it "sweep leaves entries without a ttl alone" do
    CacheSweepContract.local_backends(@tmp, "nottl").each do |label, backend|
      backend.clear
      backend.set("permanent", { "i" => "forever" }, 0)
      sleep 0.2

      expect(backend.sweep).to eq(0), "#{label}.sweep evicted an entry stored with no TTL"
      expect(backend.get("permanent")).to eq({ "i" => "forever" }),
                                          "#{label} lost a permanent entry to sweep - a sweep comparing " \
                                          "now > expires_at without excluding the no-expiry sentinel evicts " \
                                          "every permanent entry on its first run"
    end
  end
end
