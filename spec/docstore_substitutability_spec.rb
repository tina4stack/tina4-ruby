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
    # ADR-0025, closed 2026-08-03. This was an OPEN DEFECT reported rather than
    # asserted; it is now a gate.
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
    # ADR-0025 settles it: the fallback imitates the DRIVER, because the driver
    # is the half that cannot be changed. The spelling that works on BOTH is
    # find(filter).first, and these two examples pin that outcome.

    # The case names here match tests/DocStoreSubstitutabilityTest.php exactly,
    # because scripts/audit-contract-fixtures.py resolves ONE fixture case
    # against EVERY framework's suite. Renaming one half silently breaks the
    # shared answer key.
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

    # The NEGATIVE half, and the one that keeps the rule honest. ADR-0025
    # corollary 1 is "no fallback-only public method": a second spelling that
    # works ONLY on the fallback is exactly how the original defect shipped,
    # because it let the documentation settle on a method the real driver had
    # never heard of.
    it "the fallback only spelling is gone" do
      expect(collection_for(nil)).not_to respond_to(:find_one)

      expect(collection_for(DOCSTORE_MONGO_URI)).not_to respond_to(:find_one) if self.class.mongo_reachable?
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
    def server_connections
      probe = Mongo::Client.new(DOCSTORE_MONGO_URI)
      probe.database.command(serverStatus: 1).first["connections"]["current"]
    ensure
      probe&.close
    end

    it "repeated get collection does not grow connections" do
      skip "no reachable MongoDB at #{DOCSTORE_MONGO_URI}" unless self.class.mongo_reachable?

      ENV["TINA4_MONGO_URI"] = DOCSTORE_MONGO_URI
      ENV["TINA4_DOC_STORE_PATH"] = File.join(Dir.mktmpdir, "ds.db")

      rounds = (1..3).map do
        20.times { Tina4::DocStore.get_collection("lifecycle_probe").count_documents({}) }
        server_connections
      end

      settled = rounds.last
      100.times { Tina4::DocStore.get_collection("lifecycle_probe").count_documents({}) }
      after_hundred = server_connections

      # POSITIVE: 100 further calls on a settled pool add nothing. Under the old
      # one-client-per-call code this was roughly +300.
      expect(after_hundred).to be <= (settled + 2),
                               "connections still growing: settled=#{settled} after=#{after_hundred}"
      expect(rounds[2] - rounds[1]).to be <= 2, "rounds=#{rounds.inspect}"
      expect(rounds[2]).to be < 60, "rounds=#{rounds.inspect}"

      before = server_connections
      Tina4::DocStore.close_doc_store
      sleep 1
      expect(server_connections).to be < before, "close_doc_store released nothing"
    end
  end
end
