# frozen_string_literal: true

# DocStore substitutability: the SAME code, against BOTH providers.
#
# plan/v3/fixtures/docstore_contract.json is the shared answer key; this is the
# Ruby half of it, ported from tina4-python's
# tests/test_docstore_substitutability.py so the protection exists in every
# framework rather than one.
#
# WHY THIS FILE EXISTS
#   DocStore is the purest test of ADR-0024 in the framework, because
#   substitutability IS its advertised feature: develop against a
#   zero-dependency local SQLite store, switch to MongoDB in production by
#   setting one env var.
#
#   MEASURED 2026-08-01: NO DocStore test in ANY of the four frameworks had ever
#   touched a real Mongo collection. That is how nine defects accumulated behind
#   four green suites.
#
#   Every shared example below runs TWICE - once on the SQLite fallback and once
#   on a REAL MongoDB. A divergence between the two IS the bug, and no assertion
#   here means anything against a single provider.
#
# NO MOCKS. A real SQLite file and a real MongoDB over a real socket. Skips
# loudly when no Mongo is reachable, because a fabricated one would defeat the
# whole point of the file.

require "spec_helper"
require "securerandom"
require "tmpdir"

RSpec.describe "DocStore substitutability" do
  # PREFIXED - see the note in session_handlers_spec.rb. This one reads a
  # DIFFERENT env var and default from that spec, so the collision decided
  # which Mongo each of them used based purely on file load order.
  DOCSTORE_MONGO_URI = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://192.168.88.99:27017")

  # A real connect, not a port probe. A port that merely accepts is not a usable
  # Mongo - the same distinction that turned an intended skip into a hard
  # failure in the MySQL batch tests, where the gate checked reachability and
  # the service then refused the credentials.
  def self.mongo_reachable?
    return @mongo_reachable unless @mongo_reachable.nil?
    @mongo_reachable = begin
      require "mongo"
      Mongo::Logger.logger.level = Logger::FATAL
      client = Mongo::Client.new(DOCSTORE_MONGO_URI, server_selection_timeout: 3)
      client.database.command(ping: 1)
      client.close
      true
    rescue StandardError, LoadError
      false
    end
  end

  # Bind the DocStore to one provider and hand back a fresh collection.
  def collection_for(uri)
    %w[TINA4_MONGO_URI TINA4_SESSION_MONGO_URI TINA4_SESSION_MONGO_URL].each { |k| ENV.delete(k) }
    ENV["TINA4_MONGO_URI"] = uri if uri
    ENV["TINA4_DOC_STORE_PATH"] = File.join(Dir.mktmpdir, "ds.db")
    Tina4::DocStore.get_collection("ds_contract_#{SecureRandom.hex(5)}")
  end

  after do
    %w[TINA4_MONGO_URI TINA4_SESSION_MONGO_URI TINA4_SESSION_MONGO_URL TINA4_DOC_STORE_PATH].each { |k| ENV.delete(k) }
  end

  # ── the ROOT invariant ───────────────────────────────────────────────────

  describe "a real mongo is actually exercised" do
    # docstore_contract.json :: a-real-mongo-is-actually-exercised
    #
    # Listed last in the fixture because it EXPLAINS the other seven: with no
    # real-provider coverage, every other rule could drift unnoticed.
    it "reaches a real mongo collection and round-trips through it" do
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      collection = collection_for(DOCSTORE_MONGO_URI)

      # NEGATIVE: not the fallback masquerading as Mongo.
      expect(collection).not_to be_a(Tina4::DocStore::SqliteCollection)
      # POSITIVE: and it really round-trips through the server.
      collection.insert_one({ "proof" => "real-mongo" })
      expect(collection.find({ "proof" => "real-mongo" }).first["proof"]).to eq("real-mongo")
      collection.delete_many({})
    end

    it "agrees with serverless? about which provider is in use" do
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      collection = collection_for(DOCSTORE_MONGO_URI)

      expect(Tina4::DocStore.serverless?).to be(false)
      expect(collection).not_to be_a(Tina4::DocStore::SqliteCollection)
    end
  end

  # ── the driverless environment (ADR-0033) ────────────────────────────────
  #
  # NO MOCKS, and this is the case where that rule bites hardest: stubbing
  # `require` is exactly the forbidden thing, because the bug being pinned IS
  # how the LoadError is handled. A double would test the double.
  #
  # So the gem is made GENUINELY absent: a child ruby with GEM_HOME and
  # GEM_PATH pointed at an EMPTY directory, and BUNDLE_GEMFILE / RUBYOPT
  # scrubbed so bundler cannot put the bundle's gems back. `require "mongo"`
  # really raises LoadError there. Nothing needs installing, because the raise
  # must happen BEFORE the SQLite store is ever reached - so if sqlite3 is
  # missing too, and the code is correct, we never notice.
  #
  # The child reports whether it really was driverless, so a leaky environment
  # FAILS the spec instead of quietly proving nothing.
  describe "a missing driver has one outcome in all four" do
    # docstore_contract.json :: a-missing-driver-has-one-outcome-in-all-four
    #
    # MEASURED 2026-08-01 and re-measured 2026-08-04 at v3 HEAD: serverless?
    # answered true and get_collection returned a SqliteCollection. Production
    # writes went to a container-local file nobody reads, which vanishes on the
    # next deploy, with no error at any point.
    #
    # ADR-0024 rule 3, settled for DocStore by ADR-0033: a provider that cannot
    # honour an operation must RAISE, naming the provider and what is missing.
    # A method, not a bare constant: a constant declared inside an RSpec
    # example group lands on Object and is visible to every other spec file.
    def driver_absence_probe
      <<~RUBY
        require "json"
        report = {}
        begin
          require "mongo"
          report["driverless"] = false
        rescue LoadError
          report["driverless"] = true
        end
        $LOAD_PATH.unshift(ARGV[0])
        require "tina4/docstore"
        report["serverless"] = Tina4::DocStore.serverless?
        begin
          collection = Tina4::DocStore.get_collection("driver_absence_probe")
          report["outcome"] = "returned"
          report["returned_type"] = collection.class.name
        rescue Exception => e
          report["outcome"] = "raised"
          report["error_type"] = e.class.name.split("::").last
          report["error_ancestors"] = e.class.ancestors.map(&:to_s)
          report["message"] = e.message
        end
        report["store_file_exists"] = File.exist?(ENV.fetch("TINA4_DOC_STORE_PATH"))
        print "__PROBE__" + JSON.generate(report)
      RUBY
    end

    def run_driver_absence_probe(uri)
      require "tmpdir"
      require "json"
      Dir.mktmpdir do |scratch|
        empty_gem_home = File.join(scratch, "gems")
        Dir.mkdir(empty_gem_home)
        probe_path = File.join(scratch, "probe.rb")
        File.write(probe_path, driver_absence_probe)
        store_path = File.join(scratch, "must_not_be_created.db")
        lib_dir = File.expand_path("../lib", __dir__)

        # A CLEAN env. Every BUNDLE*/BUNDLER* key plus RUBYLIB and RUBYOPT is
        # removed, not just BUNDLE_GEMFILE: `bundle exec` also exports RUBYLIB
        # pointing at bundler's own lib, which re-runs bundler/setup in the
        # child and dies resolving the bundle against the empty GEM_HOME.
        child_env = ENV.keys.grep(/\ABUNDLER?_/).to_h { |key| [key, nil] }
        child_env.merge!(
          "RUBYLIB" => nil,
          "RUBYOPT" => nil,
          "GEM_HOME" => empty_gem_home,
          "GEM_PATH" => empty_gem_home,
          "TINA4_MONGO_URI" => uri,
          "TINA4_DOC_STORE_PATH" => store_path
        )
        output = IO.popen(child_env, [RbConfig.ruby, probe_path, lib_dir], err: [:child, :out], &:read)
        expect(output).to include("__PROBE__"), "probe did not report: #{output}"
        JSON.parse(output.split("__PROBE__", 2).last)
      end
    end

    it "a missing driver raises instead of using the local file" do
      # A password in the URI, so the credential-leak expectation has something
      # real to catch.
      report = run_driver_absence_probe("mongodb://docstore_user:s3cr3t-p4ssw0rd@192.0.2.1:27017")

      # The environment must really be driverless, or nothing below means
      # anything. This FAILS rather than skipping, on purpose.
      expect(report["driverless"]).to be(true),
                                      "the probe ruby could require 'mongo', so this spec would have proved nothing"

      # Configuration says Mongo, so serverless? must say Mongo. When it
      # answered true here, get_collection took the local branch and that WAS
      # the silent degradation.
      expect(report["serverless"]).to be(false)

      expect(report["outcome"]).to eq("raised"),
                                   "expected a raise, got #{report['returned_type']}"
      expect(report["error_type"]).to eq("DocStoreDriverMissing")

      message = report["message"]
      expect(message).to include("mongo")
      expect(message).to include("gem install mongo")
      expect(message).to include("TINA4_MONGO_URI")

      # NEGATIVE: naming the variable must not mean printing its value. A Mongo
      # URI routinely carries credentials and an error string is the most-logged
      # text a framework emits.
      expect(message).not_to include("s3cr3t-p4ssw0rd"),
                             "the message does not leak the uri credentials, but it did: #{message}"

      # NEGATIVE, and the one that matters most: nothing was written to the
      # local store.
      expect(report["store_file_exists"]).to be(false),
                                             "the local SQLite store was created even though a Mongo URI was configured"
    end

    it "the same uri with the driver present still selects mongo" do
      # POSITIVE half: the raise must be about the DRIVER, not the URI. Without
      # this, deleting the whole real-Mongo path would satisfy the case above.
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      collection = collection_for(DOCSTORE_MONGO_URI)
      expect(Tina4::DocStore.serverless?).to be(false)
      expect(collection).not_to be_a(Tina4::DocStore::SqliteCollection)
      collection.insert_one({ "proof" => "driver-present" })
      collection.delete_many({})
    end
  end

  # ── the shared round trip, on BOTH providers ─────────────────────────────

  shared_examples "an interchangeable document store" do |provider|
    it "returns what was stored on #{provider}" do
      collection.insert_one({ "name" => "alpha", "n" => 5 })

      found = collection.find({ "name" => "alpha" }).first
      expect(found).not_to be_nil, "#{provider}: the document must be findable"
      expect(found["n"]).to eq(5)
      collection.delete_many({})
    end

    it "makes an update visible to the next read on #{provider}" do
      collection.insert_one({ "name" => "beta", "status" => "new" })
      collection.update_one({ "name" => "beta" }, { "$set" => { "status" => "shipped" } })

      expect(collection.find({ "name" => "beta" }).first["status"]).to eq("shipped")
      collection.delete_many({})
    end

    it "counts what was inserted on #{provider}" do
      3.times { |i| collection.insert_one({ "batch" => "c", "i" => i }) }

      expect(collection.count_documents({ "batch" => "c" })).to eq(3)
      collection.delete_many({})
    end

    it "filters a comparison operator the same way on #{provider}" do
      [1, 5, 9].each { |n| collection.insert_one({ "grp" => "d", "n" => n }) }

      got = collection.find({ "grp" => "d", "n" => { "$gt" => 4 } }).to_a.map { |d| d["n"] }.sort
      expect(got).to eq([5, 9])
      collection.delete_many({})
    end
  end

  context "on the sqlite fallback" do
    let(:collection) { collection_for(nil) }
    include_examples "an interchangeable document store", "fallback"
  end

  context "on a real mongo" do
    before { skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable? }
    let(:collection) { collection_for(DOCSTORE_MONGO_URI) }
    include_examples "an interchangeable document store", "mongo"
  end

  # ── OPEN DEFECTS: measured, reported, deliberately not asserted ───────────

  describe "the call-site surface is identical" do
    # docstore_contract.json :: the-call-site-surface-is-identical
    #
    # ADR-0025, closed 2026-08-03. AMENDED by ADR-0035 on 2026-08-04.
    #
    # The defect: find_one was the accessor the fallback offered and the
    # documented Ruby example used. On a REAL Mongo::Collection it does not
    # exist:
    #
    #   NoMethodError: undefined method 'find_one' for an instance of Mongo::Collection
    #
    # so the swap failed LOUDLY here rather than silently - better than PHP,
    # where the equivalent accessor returned nil - but the code still broke the
    # moment TINA4_MONGO_URI was set.
    #
    # ADR-0025 kept the right goal - no method that works on the fallback and
    # breaks on the driver - and reached it by DELETING find_one. ADR-0035
    # amends the means: Tina4 SUPPLIES the method on both sides through
    # MongoCollection, a SimpleDelegator that forwards the entire driver surface
    # untouched. So the comparison below is against WHAT get_collection RETURNS,
    # not against the raw driver: the returned object is the only surface a call
    # site ever touches.
    #
    # The case names here match tests/DocStoreSubstitutabilityTest.php exactly,
    # because scripts/audit-contract-fixtures.py resolves ONE fixture case
    # against EVERY framework's suite. Renaming one half silently breaks the
    # shared answer key.

    # Every public method the fallback COLLECTION offers, as measured rather
    # than listed - a hand-kept list is the thing that drifts.
    def fallback_collection_methods
      Tina4::DocStore::SqliteCollection.instance_methods(false).sort
    end

    def fallback_cursor_methods
      Tina4::DocStore::Cursor.instance_methods(false).sort
    end

    it "the driver spelling works on both providers" do
      providers = { "fallback" => nil }
      providers["mongo"] = DOCSTORE_MONGO_URI if self.class.mongo_reachable?

      providers.each do |label, uri|
        c = collection_for(uri)
        c.insert_one({ "probe" => "accessor" })

        found = c.find({ "probe" => "accessor" }).first
        expect(found).not_to be_nil, "#{label}: find(...).first must return the document"
        expect(found["probe"]).to eq("accessor"), "#{label}: wrong document came back"
        c.delete_many({})
      end
    end

    # ADR-0035: the uniform Tina4 spelling must ANSWER on both providers, not
    # just on the fallback. This is the half ADR-0025 got backwards - it deleted
    # the method rather than supplying it - and it is asserted by USE (a real
    # document read back) rather than by respond_to?, because a delegator that
    # answers respond_to? and then raises would pass a reflection check.
    it "the uniform spelling works on both providers" do
      providers = { "fallback" => nil }
      providers["mongo"] = DOCSTORE_MONGO_URI if self.class.mongo_reachable?

      providers.each do |label, uri|
        c = collection_for(uri)
        c.insert_one({ "probe" => "uniform" })

        one = c.find_one({ "probe" => "uniform" })
        expect(one).not_to be_nil, "#{label}: find_one must return the document"
        expect(one["probe"]).to eq("uniform"), "#{label}: find_one returned the wrong document"

        listed = c.find({ "probe" => "uniform" }).to_list
        expect(listed.length).to eq(1), "#{label}: cursor.to_list must materialise the documents"
        expect(listed.first["probe"]).to eq("uniform"), "#{label}: to_list returned the wrong document"

        # NEGATIVE: a name that exists on NEITHER half must still fail loudly.
        # Without this the delegator could be swallowing everything.
        expect { c.find_one_upside_down({}) }.to raise_error(NoMethodError),
                                                "#{label}: an unknown method must still raise"

        # The driver's own spellings are untouched - this is ADDITIVE.
        expect(c.find({ "probe" => "uniform" }).to_a.length).to eq(1),
               "#{label}: to_a must keep working alongside to_list"

        c.delete_many({})
      end
    end

    # The measurement ADR-0025 made by hand, now a gate - and pointed at the
    # WRAPPED surface (ADR-0035) rather than the raw driver.
    it "the fallback surface resolves on the wrapped driver" do
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      wrapped = collection_for(DOCSTORE_MONGO_URI)
      missing = fallback_collection_methods.reject { |m| wrapped.respond_to?(m) }
      expect(missing).to eq([]),
                         "fallback-only collection methods (they break the swap): #{missing.inspect}"

      wrapped_cursor = wrapped.find({})
      missing_cursor = fallback_cursor_methods.reject { |m| wrapped_cursor.respond_to?(m) }
      expect(missing_cursor).to eq([]),
                                "fallback-only cursor methods (they break the swap): #{missing_cursor.inspect}"

      # A View is immutable, so every chaining call returns a NEW one. The
      # uniform spelling has to survive that or it works only until you sort.
      # ADR-0036 made the two-argument spelling work on the driver too, so this
      # uses the form the framework DOCUMENTS rather than the one form that
      # happened to survive.
      expect(wrapped.find({}).sort("n", -1).limit(2)).to respond_to(:to_list)

      wrapped.delete_many({})
    end

    # ADR-0036. The chain the framework DOCUMENTS must run on both providers.
    #
    # MEASURED 2026-08-04 against a real MongoDB, before the fix:
    # sort("total", -1) raised ArgumentError on Mongo::Collection::View#sort
    # (which takes ONE spec), and sort([["total", -1]]) reached the server as an
    # ARRAY and came back "[14:TypeMismatch]: Expected field sort to be of type
    # object". Only the hash form worked, so the framework's own documented
    # spelling was the broken one.
    #
    # All three spellings are asserted because fixing only the documented one
    # would MOVE the incompatibility rather than remove it.
    it "the cursor chain works on both providers" do
      providers = { "fallback" => nil }
      providers["mongo"] = DOCSTORE_MONGO_URI if self.class.mongo_reachable?

      providers.each do |label, uri|
        c = collection_for(uri)
        # Inserted OUT of the expected order on purpose: with [9, 7, 3] a sort
        # that silently did NOTHING still returned [9, 7], so the assertion
        # passed on a broken sort.
        [3, 9, 7].each { |total| c.insert_one({ "total" => total, "grp" => "chain" }) }

        spellings = {
          "sort(field, direction)" => -> { c.find({ "grp" => "chain" }).sort("total", -1).limit(2) },
          "sort(hash)"             => -> { c.find({ "grp" => "chain" }).sort({ "total" => -1 }).limit(2) },
          "sort(pairs)"            => -> { c.find({ "grp" => "chain" }).sort([["total", -1]]).limit(2) },
        }

        spellings.each do |spelling, chain|
          expect(chain.call.to_a.map { |d| d["total"] }).to eq([9, 7]),
                                                            "#{label} #{spelling}: to_a over the chain must order and cap"
          expect(chain.call.to_list.map { |d| d["total"] }).to eq([9, 7]),
                                                               "#{label} #{spelling}: to_list over the chain must order and cap"
          collected = []
          chain.call.each { |d| collected << d["total"] }
          expect(collected).to eq([9, 7]), "#{label} #{spelling}: each over the chain must order and cap"
        end

        # skip composes, and ascending is not merely the absence of descending -
        # a direction that is ignored would pass a descending-only test.
        expect(c.find({ "grp" => "chain" }).sort("total", -1).skip(1).limit(1).to_a.map { |d| d["total"] }).to eq([7]),
               "#{label}: skip must compose with sort and limit"
        expect(c.find({ "grp" => "chain" }).sort("total", 1).limit(2).to_a.map { |d| d["total"] }).to eq([3, 7]),
               "#{label}: an ascending sort must actually ascend"

        # LAZY: building the chain must not execute it.
        pending_chain = c.find({ "grp" => "chain" }).sort("total", -1)
        c.insert_one({ "total" => 99, "grp" => "chain" })
        expect(pending_chain.to_a.first["total"]).to eq(99),
                                                    "#{label}: the chain must run at materialisation, not at find()"

        c.delete_many({})
      end
    end
  end

  describe "query semantics match on both providers" do
    # docstore_contract.json :: query-semantics-match-on-both-providers
    #
    # ADR-0025 clause 4, closed 2026-08-03.
    #
    # MEASURED against a real MongoDB: EIGHT array-query behaviours diverged
    # IDENTICALLY in all four frameworks - the signature of a contract nobody had
    # written down. Three were FALSE POSITIVES, where the fallback returned a
    # document Mongo excludes: {"nums" => {"$gt" => 9}} matched [1,2,3], because
    # json_extract of an array returns its JSON TEXT and SQLite sorts any text
    # above any number.
    #
    # MongoDB's rule is one sentence: a condition on an array-valued field
    # matches when ANY ELEMENT matches it (or the whole array equals the
    # operand), and a negation matches when NO element does.
    #
    # What is asserted is not "the fallback returns N" - it is that BOTH
    # PROVIDERS RETURN THE SAME THING. That is ADR-0024 stated directly.
    ARRAY_DOC = { "name" => "w", "tags" => %w[x y], "nums" => [1, 2, 3],
                  "empty" => [], "scalar" => "x", "obj" => { "city" => "x" } }.freeze
    ARRAY_CASES = [
      ["equality containment", { "tags" => "x" }],
      ["equality no match", { "tags" => "z" }],
      ["exact array, right order", { "tags" => %w[x y] }],
      ["exact array, wrong order", { "tags" => %w[y x] }],
      ["$in hits one element", { "tags" => { "$in" => %w[x q] } }],
      ["$in hits nothing", { "tags" => { "$in" => %w[q] } }],
      ["$nin excludes a present element", { "tags" => { "$nin" => %w[x] } }],
      ["$nin with an absent element", { "tags" => { "$nin" => %w[q] } }],
      ["$ne a present element", { "tags" => { "$ne" => "x" } }],
      ["$ne an absent element", { "tags" => { "$ne" => "q" } }],
      ["numeric containment", { "nums" => 1 }],
      ["$gt any element", { "nums" => { "$gt" => 2 } }],
      ["$gt no element", { "nums" => { "$gt" => 9 } }],
      ["$lt any element", { "nums" => { "$lt" => 2 } }],
      ["$exists on an array", { "tags" => { "$exists" => true } }],
      ["empty array exact", { "empty" => [] }],
      ["$regex on an array element", { "tags" => { "$regex" => "^x$" } }],
      ["scalar still works", { "scalar" => "x" }],
      ["object field is not matched by its value", { "obj" => "x" }],
      ["object field matches the whole object", { "obj" => { "city" => "x" } }]
    ].freeze

    it "array queries match identically on both providers" do
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      results = {}
      { "fallback" => nil, "mongo" => DOCSTORE_MONGO_URI }.each do |provider, uri|
        c = collection_for(uri)
        c.delete_many({})
        c.insert_one(ARRAY_DOC.dup)
        results[provider] = ARRAY_CASES.to_h { |name, q| [name, c.find(q).to_a.length] }
        c.delete_many({})
      end

      mismatched = ARRAY_CASES.filter_map do |name, _|
        next if results["fallback"][name] == results["mongo"][name]

        [name, [results["fallback"][name], results["mongo"][name]]]
      end.to_h

      expect(mismatched).to eq({}),
                            "array-query semantics diverge between the providers " \
                            "(fallback, mongo): #{mismatched.inspect}"
    end
  end

  # ── ADR-0025 / client-lifecycle-is-bounded (ASSERTED) ────────────────────

  describe "client lifecycle is bounded" do
    # docstore_contract.json :: client-lifecycle-is-bounded
    #
    # MEASURED 2026-08-03 against a real MongoDB: get_collection built a NEW
    # Mongo::Client on every call and never closed it. 20 calls left 60 server
    # connections open, growing linearly and without bound. Invisible in
    # development, because the SQLite fallback opens no connections at all - the
    # leak existed ONLY after the swap to the real provider.
    #
    # What is asserted is the SHAPE of the growth, not its size. A pool
    # legitimately opens several connections and then PLATEAUS; a leak keeps
    # climbing.
    #
    # EVERY COUNT HERE IS SCOPED TO THE CONNECTIONS THIS TEST OWNS.
    # serverStatus.connections.current, which this spec used to read, is a
    # SERVER-GLOBAL counter across every client on that mongod, so any other
    # process moves it and the assertion becomes a coin flip rather than a
    # gate. Measured 2026-08-04 against the shared lab MongoDB 7.0.39 with the
    # docstore code UNCHANGED and correct, the global count read [88, 89, 90]
    # with one other agent connected and [193, 194, 195] with 45 further real
    # clients held open, against an idle baseline near 6.
    #
    # $currentOp with idleConnections is the per-client view: an appName in the
    # connection string tags every socket this test's client opens, and nobody
    # else's carry it. That also lets close_doc_store be asserted at its real
    # strength - OUR connections must reach exactly ZERO, not merely "fewer
    # than before", which another tenant disconnecting could satisfy alone.
    # A `let`, not a bare constant: a constant declared inside an RSpec
    # example group lands on Object and is visible to every other spec file.
    let(:lifecycle_app_name) { "tina4_docstore_lifecycle_#{SecureRandom.hex(5)}" }

    def tagged_uri
      mongo_uri_with_option(DOCSTORE_MONGO_URI, "appName=#{lifecycle_app_name}")
    end

    # Append one connection-string option to a MongoDB URI of ANY shape.
    #
    # The separator depends on whether the URI already has a PATH, not merely
    # whether it has a query string. A mongodb URI needs a "/" before its
    # query, but appending "/?" to a URI that already carries a database gives
    # ".../tina4_rb/?x=1" -- the driver then reads the database name as
    # "tina4_rb/" and rejects the whole string.
    #
    # MEASURED: the hand-rolled `include?("?") ? "&" : "/?"` join this replaces
    # broke 3 of 6 real URI shapes -- host/db, a bare trailing slash, and
    # mongodb+srv://.../db, the ordinary Atlas connection string. It only ever
    # looked correct because the test Mongo URI happened to be the bare
    # host:port form; the moment per-framework test isolation pointed it at a
    # URI carrying a database, every caller failed at once. Fixed in all four.
    def mongo_uri_with_option(uri, option)
      return "#{uri}&#{option}" if uri.include?("?")

      after_scheme = uri.split("://", 2).last.to_s

      "#{uri}#{after_scheme.include?('/') ? '?' : '/?'}#{option}"
    end

    def own_connections
      probe = Mongo::Client.new(DOCSTORE_MONGO_URI)
      rows = probe.database.aggregate([
                                        { "$currentOp" => { "allUsers" => true, "idleConnections" => true,
                                                            "localOps" => true } },
                                        { "$match" => { "appName" => lifecycle_app_name } },
                                        { "$count" => "n" }
                                      ]).to_a
      # $count emits NO document when nothing matched, which is 0.
      rows.empty? ? 0 : rows.first["n"]
    ensure
      probe&.close
    end

    it "repeated get collection does not grow connections" do
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      ENV["TINA4_MONGO_URI"] = tagged_uri
      ENV["TINA4_DOC_STORE_PATH"] = File.join(Dir.mktmpdir, "ds.db")

      # The measurement must be able to SEE this client, or every expectation
      # below is vacuously true and proves nothing.
      Tina4::DocStore.get_collection("lifecycle_probe").count_documents({})
      expect(own_connections).to be > 0,
                                 "appName scoping saw none of our own connections - the probe is blind"

      rounds = (1..3).map do
        20.times { Tina4::DocStore.get_collection("lifecycle_probe").count_documents({}) }
        own_connections
      end

      settled = rounds.last
      100.times { Tina4::DocStore.get_collection("lifecycle_probe").count_documents({}) }
      after_hundred = own_connections

      # POSITIVE: 100 further calls on a settled pool add nothing. Under the old
      # one-client-per-call code this was roughly +300.
      expect(after_hundred).to be <= settled,
                               "connections still growing: settled=#{settled} after=#{after_hundred}"
      # And the growth flattened rather than tracking the call count. Both
      # halves are scoped, so the ceiling measures OUR pool.
      expect(rounds[2] - rounds[1]).to be <= 2, "rounds=#{rounds.inspect}"
      expect(rounds[2]).to be <= 10, "our own pool is not bounded: rounds=#{rounds.inspect}"

      # NEGATIVE: after close there must be NONE of ours left, not merely fewer.
      Tina4::DocStore.close_doc_store
      sleep 1
      expect(own_connections).to eq(0), "close_doc_store released nothing"
    end
  end
end
