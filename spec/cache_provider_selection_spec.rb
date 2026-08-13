# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require "stringio"

# CACHE CONTRACT - an explicit provider is honoured, and an unreachable one
# degrades visibly.
#
# Pins TWO invariants from plan/v3/fixtures/cache_contract.json (ADR-0024),
# because they are the two halves of one question: which provider did I actually
# get, and was I told?
#
#   an-explicit-provider-is-honoured
#       A provider requested explicitly is the provider used. It may not be
#       overridden by ambient state such as another middleware instance already
#       existing.
#
#   an-unreachable-backend-degrades-visibly
#       A backend whose driver is missing or whose service is unreachable logs a
#       warning and falls back to a REAL persistent cache (the file backend),
#       never to a silent no-op.
#
# MEASURED for the first: in NODE an explicitly-requested response-cache
# provider was silently IGNORED once any responseCache middleware existed,
# because the module-level backend was memoised and returned before the config
# was read. The developer names a backend, the framework quietly uses a
# different one, and the only symptom is cache behaviour that does not match the
# configuration.
#
# The second is the guard that keeps every other rule honest: a cache that
# silently stops caching looks identical to a cache that is working, right up
# until the load arrives.
#
# MEASURED IN RUBY AT HEAD and confirmed correct on both, so this file is a
# PARITY LOCK-IN. Every example is mutation-proven so it stays a real gate
# rather than decoration.
#
# UNREACHABILITY IS REAL HERE. The examples point a backend at a genuinely
# closed port on localhost - a real connect that really fails - never a
# simulated outage.
#
# A constant assigned inside an RSpec.describe block is defined on Object, i.e.
# GLOBAL, and clobbers every other spec file that uses the same name. Everything
# this file needs therefore lives in a uniquely named module.
module CacheProviderContract
  REDIS_URL = ENV.fetch("TINA4_TEST_REDIS_URL", "redis://127.0.0.1:6379")

  KEYS = %w[
    TINA4_CACHE_BACKEND TINA4_CACHE_URL TINA4_CACHE_TTL TINA4_CACHE_MAX_ENTRIES
    TINA4_CACHE_DIR TINA4_CACHE_USERNAME TINA4_CACHE_PASSWORD
  ].freeze

  module_function

  def around(example)
    saved = KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    begin
      example.run
    ensure
      KEYS.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
    end
  end

  # A port nothing is listening on. Bind it, read it, release it.
  #
  # The bind proves the port was free at that instant; the release means a
  # connect to it really fails at the OS level. That is a genuine unreachable
  # service, not a stand-in for one.
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Capture what Tina4::Log actually writes. Log emits through $stdout.puts, so
  # this reads the REAL log output - it does not replace the logger.
  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    begin
      yield
    ensure
      $stdout = original
    end
    buffer.string
  end
end

RSpec.describe "cache provider selection" do
  around(:each) { |example| CacheProviderContract.around(example) }
  around(:each) do |example|
    Dir.mktmpdir("tina4-provider") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  # ---- an explicit provider is honoured ----

  # NAMED "an explicitly named provider is used", NOT "an explicit provider is
  # honoured". The contract auditor matches a case name as a SUBSTRING of the
  # suite file, and the shorter wording is a PREFIX of the next example's name -
  # so deleting this example would still audit GREEN, which is the exact
  # vanished-test failure the fixture exists to catch. Do not shorten it back.
  it "an explicitly named provider is used" do
    ENV["TINA4_CACHE_BACKEND"] = "memory"
    ENV["TINA4_CACHE_DIR"] = File.join(@tmp, "explicit")

    # Build one first, so a memoised module-level backend would already exist.
    ambient = Tina4::ResponseCache.new
    explicit = Tina4::ResponseCache.new(backend: "file")

    expect(explicit.backend_name).to eq("file"),
                                     "asked for the 'file' provider and got '#{explicit.backend_name}' - the " \
                                     "explicit request was overridden by ambient state"
    expect(ambient.backend_name).to eq("memory"), "building an explicit instance changed the ambient one"
  end

  it "an explicit provider is honoured after another instance exists" do
    ENV["TINA4_CACHE_BACKEND"] = "memory"
    ENV["TINA4_CACHE_DIR"] = File.join(@tmp, "second")

    first = Tina4::ResponseCache.new
    expect(first.backend_name).to eq("memory"), "precondition: the ambient provider is memory"

    second = Tina4::ResponseCache.new(backend: "file")

    expect(second.backend_name).to eq("file"),
                                   "the second middleware asked for 'file' and was handed the first instance's " \
                                   "memoised backend instead - the measured Node defect, stated directly"
  end

  it "two explicit providers do not share a backend" do
    ENV["TINA4_CACHE_DIR"] = File.join(@tmp, "shared-dir")
    memory_cache = Tina4::ResponseCache.new(backend: "memory")
    file_cache = Tina4::ResponseCache.new(backend: "file")

    memory_cache.send(:backend_set, "only-in-memory", { "v" => 1 }, 300)

    expect(file_cache.send(:backend_get, "only-in-memory")).to be_nil,
                                                               "the two explicitly-named providers are the same " \
                                                               "store - a fix that records the requested name but " \
                                                               "still hands back the memoised object would pass a " \
                                                               "name assertion and change nothing observable"
  end

  it "an unrecognised provider raises" do
    expect { Tina4::CacheBackends.create_backend(backend: "redsi") }
      .to raise_error(ArgumentError, /redsi/) { |error|
        expect(error.message).to include("redis"),
                                 "the error does not list the valid backends"
      }
    # Falling through to memory turned TINA4_CACHE_BACKEND=redsi into a running
    # app with a per-process cache while the operator believed it was in Redis.
  end

  # ---- an unreachable backend degrades visibly ----

  it "an unreachable backend falls back to the file backend" do
    ENV["TINA4_CACHE_DIR"] = File.join(@tmp, "fallback")
    port = CacheProviderContract.closed_port

    {
      "redis" => "redis://127.0.0.1:#{port}",
      "valkey" => "valkey://127.0.0.1:#{port}",
      "memcached" => "memcached://127.0.0.1:#{port}",
      "mongodb" => "mongodb://127.0.0.1:#{port}/tina4_cache_contract_rb"
    }.each do |backend, url|
      resolved = Tina4::CacheBackends.create_backend(backend: backend, url: url)

      expect(resolved.name).to eq("file"),
                               "an unreachable '#{backend}' resolved to '#{resolved.name}', not 'file' - the " \
                               "fallback must be a real persistent cache, never memory (which silently loses " \
                               "cross-process sharing) and never a no-op"
    end
  end

  it "the fallback backend actually caches" do
    cache_dir = File.join(@tmp, "reallyworks")
    ENV["TINA4_CACHE_DIR"] = cache_dir
    resolved = Tina4::CacheBackends.create_backend(
      backend: "redis", url: "redis://127.0.0.1:#{CacheProviderContract.closed_port}"
    )

    resolved.set("degraded", { "v" => "still cached" }, 300)

    expect(resolved.get("degraded")).to eq({ "v" => "still cached" }),
                                        "the fallback backend accepted a write and lost it - the cache silently " \
                                        "stopped caching, which passes a name check and looks identical to a " \
                                        "working cache until the load arrives"
    expect(Dir.glob(File.join(cache_dir, "*.json"))).not_to be_empty,
                                                            "nothing reached the filesystem, so the 'file' " \
                                                            "fallback is a no-op wearing the file backend's name"
  end

  it "an unreachable backend logs a warning" do
    ENV["TINA4_CACHE_DIR"] = File.join(@tmp, "warned")
    port = CacheProviderContract.closed_port

    # Tina4::Log memoises its console threshold in @snapshot, and
    # spec_helper.rb pins the WHOLE suite to TINA4_LOG_LEVEL=NONE (console
    # silent) so unrelated specs stay quiet. Raise it locally for this one
    # assertion instead of depending on ambient state some earlier spec left
    # behind - mirrors with_console_logging in
    # spec/database_connect_timeout_spec.rb. Without this the warning is
    # real (Tina4::Log.warning does fire) but NEVER reaches stdout under the
    # suite's own baseline, so capture_stdout always returns "" - a false
    # negative that only an isolation fix (not a flaky leak) can produce.
    logged = begin
      Tina4::Log.configure(output: "stdout", level: "debug")
      CacheProviderContract.capture_stdout do
        Tina4::CacheBackends.create_backend(backend: "redis", url: "redis://127.0.0.1:#{port}")
      end.downcase
    ensure
      Tina4::Log.reset
    end

    expect(logged).to include("redis"),
                      "the fallback was silent, or the warning does not say WHICH backend went away. " \
                      "Captured: #{logged.inspect}"
    expect(logged).to include("file"),
                      "the warning does not say what replaced the failed backend. Captured: #{logged.inspect}"
    expect(logged).to include("unavailable"),
                      "the warning does not say the backend was unavailable. Captured: #{logged.inspect}"
  end

  it "a reachable backend is not replaced" do
    ENV["TINA4_CACHE_DIR"] = File.join(@tmp, "notreplaced")

    resolved = Tina4::CacheBackends.create_backend(backend: "redis", url: CacheProviderContract::REDIS_URL)

    expect(resolved.name).to eq("redis"),
                             "a REACHABLE redis was replaced by the file backend - the availability probe fails " \
                             "open, so every deployment silently loses its shared cache. That is the same " \
                             "invisible degradation as a silent no-op, from the other direction."
  end
end
