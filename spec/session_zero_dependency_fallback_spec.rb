# frozen_string_literal: true

# SESSION CONTRACT invariant 6: a zero-dependency transport in EVERY framework.
#
# ADR-0024 / session_contract.json #6: "Where three frameworks ship a
# zero-dependency transport for a backend, the fourth does too. A backend must
# not hard-require a third-party client in one framework and not the others."
#
# WHY THIS MATTERS, stated as the operator sees it: the SAME .env works in three
# frameworks and raises in the fourth. Nothing about the configuration hints at
# it, there is no warning to read, and the failure lands at Session construction
# on the first request. An asymmetric broken promise is worse than a consistent
# one, because nobody can plan around it.
#
# MEASURED at v3 HEAD, in a REAL subprocess with no gems resolvable at all
# (see run_with_no_gems below), driving Tina4::Session per backend exactly as a
# request does:
#
#   file       ok   redis      ok   valkey     ok   memcached  ok
#   mongodb    RuntimeError: MongoDB session handler requires the 'mongo' gem.
#              Install with: gem install mongo
#
#   lib/tina4/session_handlers/mongo_handler.rb:28  require "mongo"
#   lib/tina4/session_handlers/mongo_handler.rb:38  rescue LoadError
#   lib/tina4/session_handlers/mongo_handler.rb:39  raise "MongoDB session ..."
#
# Python (tina4_python/session_handlers/mongodb_handler.py), PHP
# (Tina4/Session/MongoSessionHandler.php) and Node
# (packages/core/src/sessionHandlers/mongoClient.ts) have all shipped a raw
# OP_MSG fallback the whole time. Ruby now does too, via MongoWireClient.
#
# HOW THE GEM IS MADE GENUINELY UNAVAILABLE, WITHOUT ANY DOUBLE.
#
#   A REAL subprocess whose RubyGems has nowhere to look. GEM_HOME and GEM_PATH
#   are pointed at an EMPTY directory and every bundler variable that would
#   re-inject the bundle's load paths (RUBYOPT, RUBYLIB, BUNDLE_GEMFILE,
#   BUNDLE_BIN_PATH, BUNDLE_PATH, BUNDLER_SETUP, BUNDLER_VERSION) is REMOVED
#   from the child's environment. The framework itself is reachable only through
#   -I<repo>/lib.
#
#   Nothing is shimmed, stubbed, monkeypatched or faked. `require` is the REAL
#   Kernel#require, `mongo.rb` genuinely does not exist anywhere the process can
#   see, and the LoadError is the one RubyGems really raises. It is not a
#   MongoDB-shaped hole either: NO third-party gem resolves in that process at
#   all, which is the strongest possible statement of the zero-dependency claim
#   and is why one subprocess can answer for five backends at once.
#
#   Every subprocess SELF-VERIFIES the instrument and reports it: whether
#   `require "mongo"` really failed, whether `require "redis"` really failed,
#   and how many gem directories are on $LOAD_PATH. Each example asserts those
#   FIRST. Without that check a subprocess that quietly inherited the bundle
#   would pass every assertion below while measuring nothing at all - the same
#   trap the counting listener in session_handler_construction_spec.rb guards.
#
# TINA4_SESSION_STRICT=true IS SET IN EVERY SUBPROCESS, and it is load-bearing.
# Session#safe_read and #safe_write RESCUE StandardError, log, and degrade to an
# empty session (ADR-0021). Without strict mode a genuinely dead backend would
# be swallowed into a clean-looking {} and case 1 would go green against nothing
# at all. Strict mode makes a real failure re-raise, so "it completed" is a fact
# rather than a shrug.
#
# WHAT EACH CASE IS FOR, and why three are needed:
#   1. the transport EXISTS for every backend and can be constructed and driven
#      with no third-party client. On its own this is satisfiable by a transport
#      that does nothing, which is exactly why case 2 exists.
#   2. the transport really WORKS: a session written through it is really in
#      MongoDB, confirmed OUT OF BAND by an independent client (the real `mongo`
#      gem, in this process, which shares no code with the wire client).
#   3. NEGATIVE CONTROL: with the gem present the GEM path is still the one
#      taken. Without this, deleting the gem path entirely passes 1 and 2.
#
# THE BOUND, STATED RATHER THAN HIDDEN: the `database` backend. Its third-party
# client is the SQL driver, and Ruby's runtime ships no SQL engine at all -
# unlike Python (stdlib sqlite3), Node (builtin node:sqlite) and PHP (bundled
# PDO_SQLite) - so tina4ruby declares `sqlite3` as a RUNTIME dependency
# (tina4ruby.gemspec:59), present in every install exactly as PDO is in PHP.
# Case 1 therefore proves what is actually in scope for THIS invariant: the
# DatabaseHandler itself pulls in no client of its own and constructs with zero
# gems available, and its real read/write round trip is measured here against a
# real SQLite file. That gap is a language fact, not this invariant.

require_relative "spec_helper"
require "open3"
require "json"
require "socket"
require "tmpdir"
require "fileutils"
require "securerandom"
require "rbconfig"

RSpec.describe "Every session backend ships a zero-dependency transport" do
  # NO BARE CONSTANTS IN HERE. A constant assigned inside an RSpec.describe
  # block takes its cref from the enclosing LEXICAL scope, which is top level,
  # so it is defined on Object and is GLOBAL - it has already clobbered other
  # spec files in this repo. Everything below is a local, a let, or a method.

  let(:repository_root) { File.expand_path("..", __dir__) }
  let(:mongo_host) { ENV["TINA4_TEST_MONGO_HOST"] || "127.0.0.1" }
  let(:mongo_port) { (ENV["TINA4_TEST_MONGO_PORT"] || 27_017).to_i }
  let(:mongo_uri) { "mongodb://#{mongo_host}:#{mongo_port}" }
  let(:mongo_database) { "tina4_zero_dependency" }
  let(:redis_host) { ENV["TINA4_SESSION_REDIS_HOST"] || "127.0.0.1" }
  let(:redis_port) { (ENV["TINA4_SESSION_REDIS_PORT"] || 6379).to_i }
  let(:valkey_host) { ENV["TINA4_SESSION_VALKEY_HOST"] || "127.0.0.1" }
  let(:valkey_port) { (ENV["TINA4_SESSION_VALKEY_PORT"] || 6380).to_i }
  let(:memcached_host) { ENV["TINA4_TEST_MEMCACHED_HOST"] || "127.0.0.1" }
  let(:memcached_port) { (ENV["TINA4_TEST_MEMCACHED_PORT"] || 11_211).to_i }

  # A collection nobody else is using, so an index or a document left by an
  # earlier run can never make an assertion true for the wrong reason.
  let(:mongo_collection) { "sessions_#{SecureRandom.hex(8)}" }

  # --- The instrument: a real subprocess with nowhere to find a gem ---------

  # Run +source+ in a REAL ruby subprocess that cannot resolve ANY third-party
  # gem, and return the JSON object it reported.
  #
  # A nil value in the environment hash REMOVES that variable from the child, so
  # bundler cannot re-inject the bundle's load paths through RUBYOPT. This is a
  # genuine environment change: no `require` is patched, nothing is faked, and
  # the child's RubyGems really has an empty directory to search.
  def run_with_no_gems(source, extra_environment = {})
    Dir.mktmpdir("tina4-no-gems") do |sandbox|
      empty_gem_home = File.join(sandbox, "gems")
      FileUtils.mkdir_p(empty_gem_home)
      script = File.join(sandbox, "case.rb")
      File.write(script, source)

      environment = {
        "GEM_HOME" => empty_gem_home,
        "GEM_PATH" => empty_gem_home,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "BUNDLE_GEMFILE" => nil,
        "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_PATH" => nil,
        "BUNDLER_SETUP" => nil,
        "BUNDLER_VERSION" => nil,
        # Strict mode is what stops a dead backend degrading into a green {}.
        "TINA4_SESSION_STRICT" => "true",
        "TINA4_DEBUG" => "false"
      }.merge(extra_environment)

      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        "-I#{File.join(repository_root, "lib")}",
        script
      )
      parse_subprocess_report(stdout, stderr, status)
    end
  end

  # The subprocess reports exactly one line prefixed with a marker, so ordinary
  # framework logging on stdout cannot be mistaken for the result.
  def parse_subprocess_report(stdout, stderr, status)
    line = stdout.lines.find { |candidate| candidate.start_with?("TINA4_REPORT ") }
    raise "the zero-gem subprocess reported nothing.\nstatus: #{status.exitstatus}\n" \
          "stdout:\n#{stdout}\nstderr:\n#{stderr}" if line.nil?

    JSON.parse(line.sub("TINA4_REPORT ", ""))
  end

  # The preamble every subprocess runs: prove the gem really is gone, and say so
  # in the report, BEFORE anything is measured.
  def instrument_self_check_source
    <<~RUBY
      require "json"
      def gem_gone?(name)
        require name
        false
      rescue LoadError
        true
      end
      instrument = {
        "mongo_gem_gone" => gem_gone?("mongo"),
        "redis_gem_gone" => gem_gone?("redis"),
        "gem_load_paths" => $LOAD_PATH.grep(/gems/).length
      }
    RUBY
  end

  # Assert the subprocess really had no gems. Every example calls this first:
  # the whole file's meaning depends on it.
  def expect_gems_really_unavailable(report)
    instrument = report["instrument"]
    expect(instrument["mongo_gem_gone"]).to be(true),
                                            "the subprocess could still load the `mongo` gem, so it measured the GEM " \
                                            "path while claiming to measure the zero-dependency one. Every assertion " \
                                            "in this example would be vacuous."
    expect(instrument["redis_gem_gone"]).to be(true),
                                            "the subprocess could still load the `redis` gem, so its environment is " \
                                            "not the gem-free one this file claims to run in."
    expect(instrument["gem_load_paths"]).to eq(0),
                                            "the subprocess had #{instrument["gem_load_paths"]} gem directories on " \
                                            "$LOAD_PATH - bundler re-injected the bundle, so no third-party client " \
                                            "was actually unavailable."
  end

  def service_reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 2).close
    true
  rescue StandardError
    false
  end

  # TINA4_REQUIRE_SERVICES turns these skips into a hard FAILURE (spec_helper),
  # which is exactly right on any machine that provisions the services. The
  # messages carry the gate's own keywords on purpose.
  def require_mongo!
    skip "mongo not reachable at #{mongo_host}:#{mongo_port}" unless service_reachable?(mongo_host, mongo_port)
  end

  def require_all_services!
    require_mongo!
    skip "redis not reachable at #{redis_host}:#{redis_port}" unless service_reachable?(redis_host, redis_port)
    skip "valkey not reachable at #{valkey_host}:#{valkey_port}" unless service_reachable?(valkey_host, valkey_port)
    unless service_reachable?(memcached_host, memcached_port)
      skip "memcached not reachable at #{memcached_host}:#{memcached_port}"
    end
  end

  # An INDEPENDENT client, sharing no code with the transport under test. Used
  # only to observe MongoDB from outside, never to drive the framework.
  def with_independent_mongo_client
    require "mongo"
    client = Mongo::Client.new(mongo_uri, database: mongo_database, server_selection_timeout: 5)
    yield client
  ensure
    # Ruby trap: a Mongo::Client owns a REAL connection pool. Leak one per
    # example and docstore_substitutability_spec's connection-count gate starts
    # failing somewhere else entirely.
    begin
      client&.close
    rescue StandardError
      nil
    end
  end

  def drop_mongo_collection
    with_independent_mongo_client do |client|
      client[mongo_collection].drop
    end
  rescue StandardError
    nil # never let cleanup mask the example's own result
  end

  def service_environment(session_directory)
    {
      "TINA4_SESSION_PATH" => session_directory,
      "TINA4_SESSION_REDIS_HOST" => redis_host,
      "TINA4_SESSION_REDIS_PORT" => redis_port.to_s,
      "TINA4_SESSION_VALKEY_HOST" => valkey_host,
      "TINA4_SESSION_VALKEY_PORT" => valkey_port.to_s,
      "TINA4_SESSION_MEMCACHED_HOST" => memcached_host,
      "TINA4_SESSION_MEMCACHED_PORT" => memcached_port.to_s,
      "TINA4_SESSION_MONGO_URI" => mongo_uri,
      "TINA4_SESSION_MONGO_DB" => mongo_database,
      "TINA4_SESSION_MONGO_COLLECTION" => mongo_collection
    }
  end

  # --- 1. EVERY BACKEND HAS A ZERO-DEPENDENCY TRANSPORT ---------------------

  it "every_backend_has_a_zero_dependency_transport" do
    require_all_services!

    Dir.mktmpdir("tina4-zero-dep-sessions") do |session_directory|
      source = <<~RUBY
        #{instrument_self_check_source}
        require "tina4"
        require "securerandom"

        backends = {}
        # Driven through Tina4::Session, NOT through a directly-constructed
        # handler, because Session#create_handler is the code a REQUEST runs.
        # A fallback that is correct on the object and bypassed on the request
        # path is the failure mode this file exists to catch.
        %w[file redis valkey mongodb memcached].each do |name|
          ENV["TINA4_SESSION_BACKEND"] = name
          session_id = "zero-dep-\#{name}-\#{SecureRandom.hex(8)}"
          begin
            writer = Tina4::Session.new({})
            transport = writer.instance_variable_get(:@handler).class.name
            writer.write(session_id, { "backend" => name }, 120)
            reader = Tina4::Session.new({})
            reader.read(session_id)
            # gc too, so the sweep really goes over the zero-dependency wire
            # rather than shipping as the one operation nothing ever runs. It
            # deletes only records whose deadline has already passed, so the
            # 120s session just written is never a candidate. Session#gc is a
            # no-op for a handler that does not implement it.
            writer.gc(3600)
            wire = nil
            if name == "mongodb"
              wire = writer.instance_variable_get(:@handler).send(:collection).class.name
            end
            backends[name] = { "ok" => true, "handler" => transport, "transport" => wire }
          rescue Exception => error
            backends[name] = { "ok" => false, "error" => "\#{error.class}: \#{error.message}" }
          end
        end

        # The database backend's client is the SQL DRIVER, and Ruby's runtime
        # ships no SQL engine at all. What IS in scope for this invariant is
        # that the handler itself pulls in no client of its own, so it must
        # CONSTRUCT with zero gems available. Its real round trip runs in the
        # parent, against a real SQLite file.
        database_handler = begin
          Tina4::SessionHandlers::DatabaseHandler.new(ttl: 120)
          { "ok" => true }
        rescue Exception => error
          { "ok" => false, "error" => "\#{error.class}: \#{error.message}" }
        end

        # The ONE URI form the zero-dependency transport genuinely cannot serve:
        # mongodb+srv:// is a DNS SRV lookup plus mandatory TLS, not a host. It
        # must say so and name the remedy, because parsing it as a hostname
        # would dial a name that does not exist and report a bare connection
        # refused. A capability that is missing must fail loudly at the point of
        # use, never half-work.
        srv = begin
          Tina4::SessionHandlers::MongoHandler.new(
            uri: "mongodb+srv://cluster0.example.mongodb.net", ttl: 120
          ).read("probe")
          { "raised" => false }
        rescue Exception => error
          { "raised" => true, "message" => error.message }
        end

        puts "TINA4_REPORT " + JSON.generate(
          "instrument" => instrument,
          "backends" => backends,
          "database_handler" => database_handler,
          "srv" => srv
        )
      RUBY

      report = run_with_no_gems(source, service_environment(session_directory))
      expect_gems_really_unavailable(report)

      failures = report["backends"].reject { |_name, outcome| outcome["ok"] }
      expect(failures).to be_empty,
                          "with NO third-party client available, these session backends could not be " \
                          "constructed and used at all: " +
                          failures.map { |name, outcome| "#{name} (#{outcome["error"]})" }.join("; ") +
                          ". Three frameworks ship a zero-dependency transport for every one of these; " \
                          "the fourth must too, or the same .env works in three and raises in one."

      # The mongodb leg must have resolved to the ZERO-DEPENDENCY transport. If
      # it somehow reached the gem here the example would be measuring the wrong
      # path while reporting a green.
      expect(report["backends"]["mongodb"]["transport"])
        .to eq("Tina4::SessionHandlers::MongoWireClient"),
            "the mongodb backend resolved to #{report["backends"]["mongodb"]["transport"].inspect} in a " \
            "process with no gems at all - the zero-dependency transport is not the one the request " \
            "path actually took."

      expect(report["srv"]["raised"]).to be(true),
                                         "a mongodb+srv:// URI silently reached the zero-dependency transport, which " \
                                         "cannot do the DNS SRV lookup or the TLS that scheme requires. It would dial " \
                                         "a hostname that does not exist and report a bare connection refused."
      expect(report["srv"]["message"]).to include("gem install mongo"),
                                          "the mongodb+srv:// refusal does not name the remedy: " \
                                          "#{report["srv"]["message"].inspect}"

      expect(report["database_handler"]["ok"]).to be(true),
                                                  "the database session handler could not even be CONSTRUCTED with no gems " \
                                                  "available (#{report["database_handler"]["error"]}), so it carries a " \
                                                  "third-party client requirement of its own rather than deferring to the " \
                                                  "Database layer."
    end

    # The database backend's real read/write, against a REAL SQLite file. Ruby's
    # SQL driver is a declared runtime dependency of the framework (present in
    # every install, exactly as PDO is in PHP), so this half is measured with it
    # present and the bound is stated rather than hidden.
    Dir.mktmpdir("tina4-zero-dep-database") do |directory|
      database = Tina4::Database.new("sqlite:///#{File.join(directory, "sessions.db")}")
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: database, ttl: 120)
      session_id = "zero-dep-database-#{SecureRandom.hex(8)}"
      begin
        handler.write(session_id, { "backend" => "database" }, 120)
        expect(handler.read(session_id)).to eq({ "backend" => "database" }),
                                            "the database session backend did not round-trip against a real SQLite engine"
      ensure
        begin
          handler.destroy(session_id)
          database.close
        rescue StandardError
          nil
        end
      end
    end
  end

  # --- 2. THE ZERO-DEPENDENCY TRANSPORT REALLY WORKS ------------------------
  #
  # Case 1 is satisfiable by a transport that accepts every call and does
  # nothing. This is the case that is not. It writes through the wire protocol,
  # reads back through a FRESH handler, and then asks MongoDB itself - through
  # an independent client that shares no code with the transport under test -
  # whether the document is really there.

  it "the_zero_dependency_transport_really_round_trips" do
    require_mongo!

    session_id = "zero-dep-roundtrip-#{SecureRandom.hex(12)}"
    payload = {
      "user" => "andre",
      "roles" => %w[admin editor],
      "visits" => 42,
      "score" => 9.5,
      "verified" => true,
      "note" => "unicode: éèê and a quote \" inside"
    }

    begin
      source = <<~RUBY
        #{instrument_self_check_source}
        require "tina4"

        ENV["TINA4_SESSION_BACKEND"] = "mongodb"
        session_id = #{session_id.inspect}
        payload = JSON.parse(#{JSON.generate(payload).inspect})

        result = begin
          writer = Tina4::Session.new({})
          transport = writer.instance_variable_get(:@handler).send(:collection).class.name
          writer.write(session_id, payload, 300)

          # A FRESH Session, therefore a FRESH handler and a FRESH socket. A
          # transport that only remembers what it was just handed cannot pass
          # this; the value has to come back off the wire.
          reader = Tina4::Session.new({})
          { "ok" => true, "transport" => transport, "read" => reader.read(session_id) }
        rescue Exception => error
          { "ok" => false, "error" => "\#{error.class}: \#{error.message}" }
        end

        puts "TINA4_REPORT " + JSON.generate("instrument" => instrument, "result" => result)
      RUBY

      report = Dir.mktmpdir("tina4-zero-dep-roundtrip") do |session_directory|
        run_with_no_gems(source, service_environment(session_directory))
      end
      expect_gems_really_unavailable(report)

      result = report["result"]
      expect(result["ok"]).to be(true),
                              "the zero-dependency MongoDB transport failed outright: #{result["error"]}"
      expect(result["transport"]).to eq("Tina4::SessionHandlers::MongoWireClient"),
                                     "the session did not resolve to the zero-dependency transport at all " \
                                     "(got #{result["transport"].inspect}), so this example proved nothing about it"
      expect(result["read"]).to eq(payload),
                                "a session written through the zero-dependency MongoDB transport did not read back " \
                                "through a FRESH handler. Got #{result["read"].inspect}. A transport that accepts " \
                                "writes and answers reads with nothing looks identical to a working one until this " \
                                "assertion runs."

      # OUT OF BAND. The framework is no longer involved: this is the real
      # `mongo` gem asking the real server what is actually stored. It is the
      # only assertion here that a stub cannot satisfy by lying consistently.
      with_independent_mongo_client do |client|
        document = client[mongo_collection].find(_id: session_id).first
        expect(document).not_to be_nil,
                                "an INDEPENDENT MongoDB client cannot find _id=#{session_id} in " \
                                "#{mongo_database}.#{mongo_collection}. The framework reported a successful " \
                                "round trip, so the zero-dependency transport is not talking to MongoDB at all."
        expect(document["data"]).to eq(payload),
                                    "the document really in MongoDB does not carry the payload that was written: " \
                                    "#{document["data"].inspect}"
        expect(document["expires_at"].to_f).to be > Time.now.to_f,
                                               "the stored absolute deadline is not in the future, so the wire transport wrote a " \
                                               "record that is already expired"
      end
    ensure
      drop_mongo_collection
    end
  end

  # --- 3. NEGATIVE CONTROL: THE GEM IS STILL PREFERRED ----------------------
  #
  # Without this, "delete the gem path entirely" passes cases 1 and 2. The
  # zero-dependency transport is a FALLBACK: where the real driver is installed
  # it stays in charge, with its connection pool, its topology monitoring and
  # its TTL index.

  it "the_third_party_client_is_still_used_when_present" do
    require_mongo!
    # Guard the premise. If the gem is missing here the example must say so, not
    # quietly assert that the fallback was used and call that a pass.
    gem_present = begin
      require "mongo"
      defined?(::Mongo::VERSION) ? true : false
    rescue LoadError
      false
    end
    skip "mongo gem not installed, so the gem path cannot be the one under test" unless gem_present

    session_id = "gem-path-#{SecureRandom.hex(12)}"
    payload = { "user" => "andre", "path" => "gem" }
    handler = nil
    request_session = nil

    begin
      handler = Tina4::SessionHandlers::MongoHandler.new(
        uri: mongo_uri, database: mongo_database, collection: mongo_collection, ttl: 300
      )
      # Resolving the transport is what triggers ensure_ttl_index on the gem
      # path, so the out-of-band evidence below exists by the next line.
      transport = handler.send(:collection)

      # The round trip runs FIRST so the collection definitely exists by the
      # time the index is inspected. Either transport creates it on write, so
      # the index probe below reports a real index list rather than raising
      # NamespaceNotFound - which would still be a failure, but one whose
      # message explained nothing.
      handler.write(session_id, payload, 300)
      expect(handler.read(session_id)).to eq(payload),
                                          "the gem path no longer round-trips a session"

      # OUT OF BAND, and the assertion a code-shape check cannot make: the TTL
      # index on updated_at is created by the GEM path only (ensure_ttl_index
      # needs the gem's own index API, and Python, PHP and Node create no index
      # on any transport). The collection name is unique per example, so this
      # index can only exist because THIS run created it - a leftover from an
      # earlier run cannot make it true.
      with_independent_mongo_client do |client|
        index_names = client[mongo_collection].indexes.map { |index| index["name"] }
        expect(index_names).to include("updated_at_1"),
                               "the gem path did not create its TTL index (indexes: #{index_names.inspect}). " \
                               "Only the gem path creates it, so its absence means the zero-dependency fallback " \
                               "ran on a machine where the real driver is installed."
      end

      expect(transport.class.name).to start_with("Mongo::"),
                                      "the `mongo` gem is installed and the handler still resolved to " \
                                      "#{transport.class.name} - the third-party client is no longer used when it is " \
                                      "present, so the zero-dependency fallback has REPLACED the working path " \
                                      "instead of backing it up."

      # The SAME resolution on the REQUEST path. A handler built directly by a
      # spec is not proof about the path a request takes; Session#create_handler
      # is that path, and it is where a wrong default would actually bite.
      previous_backend = ENV["TINA4_SESSION_BACKEND"]
      previous_uri = ENV["TINA4_SESSION_MONGO_URI"]
      previous_database = ENV["TINA4_SESSION_MONGO_DB"]
      previous_collection = ENV["TINA4_SESSION_MONGO_COLLECTION"]
      begin
        ENV["TINA4_SESSION_BACKEND"] = "mongodb"
        ENV["TINA4_SESSION_MONGO_URI"] = mongo_uri
        ENV["TINA4_SESSION_MONGO_DB"] = mongo_database
        ENV["TINA4_SESSION_MONGO_COLLECTION"] = mongo_collection
        request_session = Tina4::Session.new({})
        request_transport = request_session.instance_variable_get(:@handler).send(:collection)
        expect(request_transport.class.name).to start_with("Mongo::"),
                                                "the REQUEST path resolved to #{request_transport.class.name} while the gem is " \
                                                "installed. A policy that is right on a directly-constructed handler and wrong " \
                                                "on the path a request takes is not a policy at all."
      ensure
        ENV["TINA4_SESSION_BACKEND"] = previous_backend
        ENV["TINA4_SESSION_MONGO_URI"] = previous_uri
        ENV["TINA4_SESSION_MONGO_DB"] = previous_database
        ENV["TINA4_SESSION_MONGO_COLLECTION"] = previous_collection
      end
    ensure
      # Ruby trap: MongoHandler holds a Mongo::Client with a REAL pool. Close
      # every handler this example opened, or the connection-count gate in
      # docstore_substitutability_spec starts failing for reasons that have
      # nothing to do with the doc store.
      begin
        handler&.destroy(session_id)
      rescue StandardError
        nil
      end
      begin
        handler&.close
      rescue StandardError
        nil
      end
      begin
        request_session&.instance_variable_get(:@handler)&.close
      rescue StandardError
        nil
      end
      drop_mongo_collection
    end
  end
end
