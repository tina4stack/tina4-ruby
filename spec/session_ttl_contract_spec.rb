# frozen_string_literal: true
#
# ── SESSION CONTRACT: TINA4_SESSION_TTL is honoured by EVERY backend ─────────
#
# ADR-0024: swapping file for redis, valkey, mongodb, memcached or database
# changes ONE env var and NOTHING ELSE. The configured session lifetime is part
# of that contract. An operator who sets a 15-minute session must GET a
# 15-minute session, whichever backend is selected.
#
# WHY THIS FILE EXISTS. Measured on 2026-08-04 against v3 (b15749c): Ruby read
# TINA4_SESSION_TTL in exactly ONE handler - memcached. file, redis, mongodb and
# database each hard-coded `@ttl = options[:ttl] || 86400`, and valkey read a
# Ruby-only TINA4_SESSION_VALKEY_TTL that exists in none of the other three
# frameworks. Session#save then called safe_write(@id, @data) with NO ttl, so
# even a correct handler default could not be overridden per save. Net effect:
# TINA4_SESSION_TTL=900 produced a cookie that said Max-Age=900 and a stored
# record that lived 86400 seconds - a 96x gap, silently, on five of six
# backends. A session that does not expire when told is an AUTH outcome, not a
# storage one, which is why this is held to a security bar.
#
# NO MOCKS. Every backend here is the real service (real Redis, real Valkey,
# real memcached, real MongoDB, real SQLite file, real files on disk) and every
# expiry is real wall-clock time - no clock stubbing, no travel-to, no doubles.
# A skip is a FAILURE under TINA4_REQUIRE_SERVICES.
#
# THE THREE CASES, and why each is load-bearing:
#   1. positive    - a short TINA4_SESSION_TTL really expires the record.
#   2. negative    - a long TINA4_SESSION_TTL really does NOT expire it. Without
#                    this, "delete the expiry logic" passes case 1 and ships.
#   3. out-of-band - the stored deadline is read back with an INDEPENDENT client
#                    and is now+TTL, not now+86400. Cases 1 and 2 both go
#                    through the code under test; this one does not.

require "spec_helper"
require "tina4"
require "json"
require "socket"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "support/real_env"

RSpec.describe "Session TTL contract" do
  # Locals, never constants: a constant assigned inside RSpec.describe is
  # defined on Object and is therefore GLOBAL, which has twice clobbered other
  # spec files in this repo (see spec_helper.rb:17-35).
  redis_host = ENV["TINA4_SESSION_REDIS_HOST"] || "127.0.0.1"
  redis_port = (ENV["TINA4_SESSION_REDIS_PORT"] || 6379).to_i
  valkey_host = ENV["TINA4_SESSION_VALKEY_HOST"] || "127.0.0.1"
  valkey_port = (ENV["TINA4_SESSION_VALKEY_PORT"] || 6380).to_i
  memcached_host = ENV["TINA4_TEST_MEMCACHED_HOST"] || "127.0.0.1"
  memcached_port = (ENV["TINA4_TEST_MEMCACHED_PORT"] || 11_211).to_i
  mongo_uri = ENV["TINA4_SESSION_MONGO_URI"] || ENV["TINA4_MONGO_URI"] || "mongodb://127.0.0.1:27017"
  mongo_host = mongo_uri[%r{//([^:/]+)}, 1] || "127.0.0.1"
  mongo_port = (mongo_uri[%r{//[^:/]+:(\d+)}, 1] || "27017").to_i

  # A real TCP probe. Under TINA4_REQUIRE_SERVICES an unreachable service is a
  # hard FAILURE, never a quiet skip - a run with skips is not verification.
  reachable = lambda do |host, port|
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  services = {
    "redis" => reachable.call(redis_host, redis_port),
    "valkey" => reachable.call(valkey_host, valkey_port),
    "memcached" => reachable.call(memcached_host, memcached_port),
    "mongodb" => reachable.call(mongo_host, mongo_port)
  }

  if ENV["TINA4_REQUIRE_SERVICES"] && !services.values.all?
    down = services.reject { |_, up| up }.keys.join(", ")
    raise "TINA4_REQUIRE_SERVICES is set but these are not reachable: #{down}"
  end

  define_method(:valkey_host_value) { valkey_host }
  define_method(:valkey_port_value) { valkey_port }

  let(:tmp_dir) { Dir.mktmpdir("tina4-ttl-contract") }
  let(:db_file) { File.join(tmp_dir, "ttl_contract.db") }

  # MongoHandler opens a Mongo::Client in its constructor and never closes it
  # (it has no #close at all), so every handler this file builds would hold a
  # connection pool open for the rest of the process. That is not theoretical:
  # leaving them open pushed the server's connection count high enough to fail
  # docstore_substitutability_spec's "does not grow connections" gate, which is
  # order-dependent and therefore passes or fails on the RSpec seed. Build each
  # backend's handler at most once per example, and close what we opened.
  after(:each) do
    (@built_handlers || {}).each_value do |handler|
      collection = handler.instance_variable_get(:@collection)
      collection.client.close if collection.respond_to?(:client)
    rescue StandardError
      nil # closing a handler we are throwing away must never fail an example
    end
    FileUtils.rm_rf(tmp_dir)
  end

  # ValkeyHandler defaults to port 6379 - REDIS's port - and shares the exact
  # same "tina4:session:" key prefix, so without this the valkey rows land in
  # Redis and the two backends are indistinguishable. Point it at the real
  # Valkey so this file genuinely covers six distinct backends.
  before(:each) do
    set_real_env(
      "TINA4_SESSION_VALKEY_HOST" => valkey_host_value,
      "TINA4_SESSION_VALKEY_PORT" => valkey_port_value.to_s
    )
  end

  # A stored session is ABSENT when the handler returns nil OR an empty hash.
  # The six handlers disagree on which they use for a miss (memcached returns
  # {}, the other five return nil), and {} is TRUTHY in Ruby - so a bare
  # truthiness check silently reports memcached as "still alive" on every miss.
  def stored?(value)
    !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
  end

  # Build the handler the way Tina4::Session builds it, so the test exercises
  # the SAME construction path an operator gets from TINA4_SESSION_BACKEND
  # rather than a hand-configured object that could diverge from it.
  def handler_for(backend, tmp_dir, db_file)
    @built_handlers ||= {}
    @built_handlers[backend] ||= build_handler(backend, tmp_dir, db_file)
  end

  def build_handler(backend, tmp_dir, db_file)
    case backend
    when "file"
      Tina4::SessionHandlers::FileHandler.new(dir: tmp_dir)
    when "database"
      Tina4::SessionHandlers::DatabaseHandler.new(db: Tina4::Database.new("sqlite://#{db_file}"))
    when "redis"
      Tina4::SessionHandlers::RedisHandler.new({})
    when "valkey"
      Tina4::SessionHandlers::ValkeyHandler.new({})
    when "mongodb"
      Tina4::SessionHandlers::MongoHandler.new({})
    when "memcached"
      Tina4::SessionHandlers::MemcachedHandler.new({})
    end
  end

  backends = %w[file database redis valkey mongodb memcached]

  # ── 1. POSITIVE: a short TINA4_SESSION_TTL really expires the record ───────
  #
  # One shared real sleep for all six backends keeps the wall-clock cost at ~4s
  # instead of 24s, and a single sleep cannot accidentally give one backend more
  # grace than another.
  it "session_ttl_env_var_expires_the_record_on_every_backend" do
    set_real_env("TINA4_SESSION_TTL" => "2")

    ids = {}
    backends.each do |backend|
      next if services.key?(backend) && !services[backend]

      handler = handler_for(backend, tmp_dir, db_file)
      ids[backend] = "ttlshort-#{backend}-#{SecureRandom.hex(6)}"
      # NO explicit ttl argument: the handler default is what must come from
      # TINA4_SESSION_TTL. Passing a ttl here would test the argument, not the
      # env var, and the argument already works.
      handler.write(ids[backend], { "seeded" => true })
      expect(handler.read(ids[backend])).to eq({ "seeded" => true }),
                                            "#{backend}: the record was not stored at all"

    end

    sleep 4 # REAL wall clock, past the configured 2s. No clock mocking.

    still_alive = ids.filter_map do |backend, id|
      handler = handler_for(backend, tmp_dir, db_file)
      backend if stored?(handler.read(id))
    end

    expect(still_alive).to be_empty,
                           "TINA4_SESSION_TTL=2 was ignored by: #{still_alive.join(', ')} " \
                           "(the record survived 4 real seconds)"
  end

  # ── 2. NEGATIVE CONTROL: a long TINA4_SESSION_TTL must NOT expire ─────────
  #
  # Without this, deleting all expiry logic passes case 1 and ships a session
  # store that throws every session away.
  it "session_ttl_env_var_keeps_a_long_lived_record_on_every_backend" do
    set_real_env("TINA4_SESSION_TTL" => "3600")

    ids = {}
    backends.each do |backend|
      next if services.key?(backend) && !services[backend]

      handler = handler_for(backend, tmp_dir, db_file)
      ids[backend] = "ttllong-#{backend}-#{SecureRandom.hex(6)}"
      handler.write(ids[backend], { "seeded" => true })
    end

    sleep 4 # the SAME real sleep that reaped everything in case 1

    died = ids.filter_map do |backend, id|
      handler = handler_for(backend, tmp_dir, db_file)
      backend unless stored?(handler.read(id))
    end

    expect(died).to be_empty,
                    "TINA4_SESSION_TTL=3600 still expired the record on: #{died.join(', ')}"
  end

  # ── 3. OUT OF BAND: the stored deadline is now+TTL, read by another client ─
  #
  # Cases 1 and 2 both ask the code under test whether the record is alive. This
  # one asks the SERVER, through a client the handler does not own, so a handler
  # that lies about expiry cannot pass it. memcached is absent by design: its
  # text protocol exposes no per-key TTL to read back, so it is proven
  # behaviourally by cases 1 and 2 instead of being asserted through the very
  # code under test.
  it "session_ttl_env_var_reaches_the_stored_deadline_out_of_band" do
    configured = 1800
    set_real_env("TINA4_SESSION_TTL" => configured.to_s)
    now = Time.now.to_f
    observed = {}

    # file - read the JSON off disk with plain File.read
    file_id = "ttloob-file-#{SecureRandom.hex(6)}"
    handler_for("file", tmp_dir, db_file).write(file_id, { "seeded" => true })
    stored = JSON.parse(File.read(File.join(tmp_dir, "sess_#{Digest::SHA256.hexdigest(file_id)}.json")))
    observed["file"] = stored["_expires"] - now

    # database - read the column with raw SQL on a SEPARATE connection
    db_id = "ttloob-db-#{SecureRandom.hex(6)}"
    handler_for("database", tmp_dir, db_file).write(db_id, { "seeded" => true })
    probe = Tina4::Database.new("sqlite://#{db_file}")
    row = probe.fetch_one("SELECT expires_at FROM tina4_session WHERE session_id = ?", [db_id])
    raise "database: no row was written for #{db_id}" unless row
    observed["database"] = (row[:expires_at] || row["expires_at"]).to_f - now

    # redis / valkey - ask the SERVER for the key's remaining TTL
    { "redis" => [redis_host, redis_port], "valkey" => [valkey_host, valkey_port] }.each do |name, (host, port)|
      next unless services[name]

      id = "ttloob-#{name}-#{SecureRandom.hex(6)}"
      handler_for(name, tmp_dir, db_file).write(id, { "seeded" => true })
      client = Tina4::SessionHandlers::RespClient.new(host: host, port: port)
      observed[name] = client.command("TTL", "tina4:session:#{id}").to_f
    end

    # mongodb - read the document's own deadline with an independent client.
    # expires_at specifically, because that is the field Python (the master),
    # PHP and Node all store: an ABSOLUTE epoch deadline, 0 meaning never. Ruby
    # storing only updated_at + a lazy TTL index is the divergence this asserts
    # away - a 60s-granularity background sweep cannot honour a short TTL, and a
    # store shared between two frameworks must carry one shape.
    if services["mongodb"]
      mongo_id = "ttloob-mongo-#{SecureRandom.hex(6)}"
      handler_for("mongodb", tmp_dir, db_file).write(mongo_id, { "seeded" => true })
      require "mongo"
      probe_client = Mongo::Client.new(mongo_uri, database: ENV["TINA4_SESSION_MONGO_DB"] || "tina4")
      doc = probe_client[ENV["TINA4_SESSION_MONGO_COLLECTION"] || "sessions"].find(_id: mongo_id).first
      probe_client.close
      observed["mongodb"] = doc && doc["expires_at"] ? doc["expires_at"].to_f - now : -1
    end

    wrong = observed.reject { |_, delta| (delta - configured).abs < 60 }
    expect(wrong).to be_empty,
                     "the stored deadline did not come from TINA4_SESSION_TTL=#{configured}: " +
                     wrong.map { |b, d| "#{b} stored now+#{d.round}s" }.join(", ")
  end

  # ── 4. THE PUBLIC Session API forwards its OWN ttl to the store ───────────
  #
  # Cases 1-3 drive the handlers directly, so they gate the handler defaults and
  # nothing else. Session#save called safe_write(@id, @data) with NO ttl, which
  # means an explicit Session.new(ttl:) never reached the backend at all - the
  # cookie carried it and the stored record did not. Without this case the
  # forwarding fix is an INERT mutation: revert it and cases 1-3 stay green.
  it "session_ttl_option_on_the_session_reaches_the_stored_record" do
    # The env says one hour. The Session says two seconds. The Session must win,
    # in the STORE, not just in the cookie.
    set_real_env("TINA4_SESSION_TTL" => "3600")

    session = Tina4::Session.new({}, ttl: 2, handler_options: { dir: tmp_dir })
    sid = session.start
    session.set("seeded", true)
    expect(session.save).to be(true)

    resumed_immediately = Tina4::Session.new({}, ttl: 2, handler_options: { dir: tmp_dir })
    resumed_immediately.start(sid)
    expect(resumed_immediately.get("seeded")).to be(true),
                                                 "the session was not stored at all"

    sleep 4 # REAL wall clock, past the Session's own 2s ttl

    resumed = Tina4::Session.new({}, ttl: 2, handler_options: { dir: tmp_dir })
    resumed.start(sid)
    expect(resumed.get("seeded")).to be_nil,
                                     "Session.new(ttl: 2) never reached the store - the record " \
                                     "outlived its own ttl because save() dropped it"
  end
end
