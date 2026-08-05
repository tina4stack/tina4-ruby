# frozen_string_literal: true

# SESSION CONTRACT: the session key prefix is configurable by env var, on every
# RESP backend.
#
# ADR-0024: swapping one session backend for another changes ONE env var and
# nothing else. Namespacing the keys those backends write is part of that
# configuration surface, and it was present in ONE framework out of four.
#
# WHY THIS FILE EXISTS. Measured 2026-08-05 across all four frameworks:
#
#     TINA4_SESSION_MEMCACHED_PREFIX   python YES  php YES  ruby YES  node YES
#     TINA4_SESSION_VALKEY_PREFIX      python no   php no   ruby YES  node YES
#     TINA4_SESSION_REDIS_PREFIX       python no   php no   ruby no   node YES
#
# Three tiers for one idea, and Ruby was inconsistent WITH ITSELF: ValkeyHandler
# read its prefix variable while RedisHandler read none, so the same .env
# namespaced valkey sessions and silently ignored the redis ones. That
# disagreement is what produced today's failing example - the out-of-band TTL
# probe passed on redis and failed on valkey for one assumed coordinate.
#
# NO MOCKS. Both backends are the real service, and every claim about the key's
# NAME is checked over a RESP client this spec owns, never by asking the handler
# what it thinks it wrote. A handler that lies consistently would pass a
# self-report; it cannot pass this.
#
# THE THREE CASES, and why each is load-bearing:
#   1. positive   - the env var really names the key ON THE SERVER.
#   2. precedence - an explicit option still beats the env var. Without it,
#                   "always read the env var" passes case 1 and breaks every
#                   caller passing prefix: explicitly.
#   3. negative   - with nothing set the default is still "tina4:session:".
#                   Without it, "always prepend the variable, empty or not"
#                   passes cases 1 and 2 and renames every existing key in every
#                   deployment that never asked for a prefix - which on a
#                   session store logs everybody out at once.

require "spec_helper"
require "securerandom"
require "socket"

RSpec.describe "Session key prefix" do
  # A method, NOT a bare constant. A constant assigned inside an RSpec.describe
  # block lands on Object and is GLOBAL - it leaks into every other spec file in
  # the run and clobbers any same-named constant there, which is a cross-file
  # failure that only appears at certain seeds.
  def default_session_prefix
    "tina4:session:"
  end

  def backends
    {
      "redis" => {
        klass: Tina4::SessionHandlers::RedisHandler,
        host: ENV["TINA4_SESSION_REDIS_HOST"] || "127.0.0.1",
        port: (ENV["TINA4_SESSION_REDIS_PORT"] || 6379).to_i,
        db: (ENV["TINA4_SESSION_REDIS_DB"] || 0).to_i,
        env: "TINA4_SESSION_REDIS_PREFIX"
      },
      "valkey" => {
        klass: Tina4::SessionHandlers::ValkeyHandler,
        host: ENV["TINA4_SESSION_VALKEY_HOST"] || "127.0.0.1",
        port: (ENV["TINA4_SESSION_VALKEY_PORT"] || 6380).to_i,
        db: (ENV["TINA4_SESSION_VALKEY_DB"] || 0).to_i,
        env: "TINA4_SESSION_VALKEY_PREFIX"
      }
    }
  end

  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  # The witness. The db goes in the CONSTRUCTOR because RespClient opens one
  # short-lived connection PER COMMAND - a separate SELECT would be closed with
  # its socket before the next command ran, and every read would land on db 0.
  def witness(cfg)
    Tina4::SessionHandlers::RespClient.new(host: cfg[:host], port: cfg[:port], db: cfg[:db])
  end

  def key_on_server?(cfg, key)
    witness(cfg).command("EXISTS", key).to_i == 1
  end

  around do |example|
    saved = %w[TINA4_SESSION_REDIS_PREFIX TINA4_SESSION_VALKEY_PREFIX]
            .to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
    example.run
  ensure
    saved.each { |k, v| v == :__unset__ ? ENV.delete(k) : ENV[k] = v }
  end

  it "session_key_prefix_env_var_names_the_key_on_the_server" do
    backends.each do |name, cfg|
      next skip("#{name} not reachable at #{cfg[:host]}:#{cfg[:port]}") unless reachable?(cfg[:host], cfg[:port])

      configured = "itest#{SecureRandom.hex(4)}:"
      ENV[cfg[:env]] = configured

      handler = cfg[:klass].new(host: cfg[:host], port: cfg[:port], db: cfg[:db], ttl: 60)
      id = "prefix-#{SecureRandom.hex(4)}"

      begin
        handler.write(id, { "seeded" => true })
        expect(key_on_server?(cfg, "#{configured}#{id}")).to be(true),
          "#{name}: #{cfg[:env]}=#{configured} was ignored - nothing at #{configured}#{id} on the server"
        # The DEFAULT name must be ABSENT, or the prefix was appended to rather
        # than used, and two deployments would still collide.
        expect(key_on_server?(cfg, "#{default_session_prefix}#{id}")).to be(false),
          "#{name}: the key was ALSO written under the default prefix"
      ensure
        witness(cfg).command("DEL", "#{configured}#{id}")
        witness(cfg).command("DEL", "#{default_session_prefix}#{id}")
      end
    end
  end

  it "session_key_prefix_option_wins_over_the_env_var" do
    backends.each do |name, cfg|
      next skip("#{name} not reachable at #{cfg[:host]}:#{cfg[:port]}") unless reachable?(cfg[:host], cfg[:port])

      ENV[cfg[:env]] = "fromenv:"
      explicit = "explicit#{SecureRandom.hex(4)}:"

      handler = cfg[:klass].new(host: cfg[:host], port: cfg[:port], db: cfg[:db], prefix: explicit, ttl: 60)
      id = "prefix-#{SecureRandom.hex(4)}"

      begin
        handler.write(id, { "seeded" => true })
        expect(key_on_server?(cfg, "#{explicit}#{id}")).to be(true),
          "#{name}: an explicit prefix: lost to #{cfg[:env]}"
        expect(key_on_server?(cfg, "fromenv:#{id}")).to be(false),
          "#{name}: the env prefix was used even though prefix: was given"
      ensure
        witness(cfg).command("DEL", "#{explicit}#{id}")
        witness(cfg).command("DEL", "fromenv:#{id}")
      end
    end
  end

  it "session_key_prefix_defaults_when_nothing_is_set" do
    backends.each do |name, cfg|
      next skip("#{name} not reachable at #{cfg[:host]}:#{cfg[:port]}") unless reachable?(cfg[:host], cfg[:port])

      ENV.delete(cfg[:env])

      handler = cfg[:klass].new(host: cfg[:host], port: cfg[:port], db: cfg[:db], ttl: 60)
      expect(handler.instance_variable_get(:@prefix)).to eq(default_session_prefix),
        "#{name}: the documented default was lost"

      id = "prefix-#{SecureRandom.hex(4)}"
      begin
        handler.write(id, { "seeded" => true })
        expect(key_on_server?(cfg, "#{default_session_prefix}#{id}")).to be(true),
          "#{name}: nothing at the default key on the server"
      ensure
        witness(cfg).command("DEL", "#{default_session_prefix}#{id}")
      end
    end
  end
end
