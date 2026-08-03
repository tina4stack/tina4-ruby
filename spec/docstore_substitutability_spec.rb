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
  MONGO_URI = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://192.168.88.99:27017")

  # A real connect, not a port probe. A port that merely accepts is not a usable
  # Mongo - the same distinction that turned an intended skip into a hard
  # failure in the MySQL batch tests, where the gate checked reachability and
  # the service then refused the credentials.
  def self.mongo_reachable?
    return @mongo_reachable unless @mongo_reachable.nil?
    @mongo_reachable = begin
      require "mongo"
      Mongo::Logger.logger.level = Logger::FATAL
      client = Mongo::Client.new(MONGO_URI, server_selection_timeout: 3)
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
      skip "no reachable MongoDB at #{MONGO_URI}" unless self.class.mongo_reachable?

      collection = collection_for(MONGO_URI)

      # NEGATIVE: not the fallback masquerading as Mongo.
      expect(collection).not_to be_a(Tina4::DocStore::SqliteCollection)
      # POSITIVE: and it really round-trips through the server.
      collection.insert_one({ "proof" => "real-mongo" })
      expect(collection.find({ "proof" => "real-mongo" }).first["proof"]).to eq("real-mongo")
      collection.delete_many({})
    end

    it "agrees with serverless? about which provider is in use" do
      skip "no reachable MongoDB at #{MONGO_URI}" unless self.class.mongo_reachable?

      collection = collection_for(MONGO_URI)

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
    before { skip "no reachable MongoDB at #{MONGO_URI}" unless self.class.mongo_reachable? }
    let(:collection) { collection_for(MONGO_URI) }
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
      providers["mongo"] = MONGO_URI if self.class.mongo_reachable?

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

      expect(collection_for(MONGO_URI)).not_to respond_to(:find_one) if self.class.mongo_reachable?
    end
  end

  describe "query semantics match on both providers" do
    # docstore_contract.json :: query-semantics-match-on-both-providers
    #
    # OPEN DEFECT. MEASURED in Python against a real MongoDB and reproduced
    # here: array fields do not match on the SQLite fallback while Mongo answers
    # them. An array field on the fallback is effectively write-only.
    it "reports array-query behaviour for each provider" do
      report = {}

      c = collection_for(nil)
      c.insert_one({ "name" => "arr", "tags" => %w[x y] })
      report["fallback"] = { "containment" => c.find({ "tags" => "x" }).to_a.length }
      expect(c.find({ "name" => "arr" }).to_a.length).to eq(1),
                                                         "fallback: the control document is unfindable - the fixture itself is wrong"
      c.delete_many({})

      if self.class.mongo_reachable?
        m = collection_for(MONGO_URI)
        m.insert_one({ "name" => "arr", "tags" => %w[x y] })
        report["mongo"] = { "containment" => m.find({ "tags" => "x" }).to_a.length }
        m.delete_many({})
      else
        report["mongo"] = "skipped (no mongo)"
      end

      warn "\n    array queries: #{report.inspect}"
    end
  end
end
