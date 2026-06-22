# frozen_string_literal: true

# DocStore - pymongo-style SQLite document store (JSON1 fallback).
#
# Locks the everyday CRUD + filter subset, the built-in ObjectId, value
# round-trip (ObjectId/Time), cursor semantics, and the serverless selection
# (SQLite when no Mongo configured). Mirrors tina4-python/tests/test_docstore.py.

require "spec_helper"
require "tmpdir"

RSpec.describe Tina4::DocStore do
  let(:db) { Tina4::DocStore::SqliteDatabase.new(":memory:") }
  let(:orders) { db.get_collection("orders") }

  after { db.close rescue nil }

  # -- ObjectId --------------------------------------------------------------

  describe Tina4::DocStore::ObjectId do
    it "generates unique 24-hex ids" do
      a = described_class.new
      b = described_class.new
      expect(a).not_to eq(b)
      expect(a.to_s).to match(/\A[0-9a-f]{24}\z/)
    end

    it "round-trips from hex" do
      a = described_class.new
      expect(described_class.new(a.to_s)).to eq(a)
      expect(described_class.new(a.to_s).hash).to eq(a.hash)
    end

    it "validates" do
      expect(described_class.valid?(described_class.new.to_s)).to be true
      expect(described_class.valid?("nope")).to be false
      expect(described_class.valid?("zz" * 12)).to be false
    end

    it "raises InvalidId on a bad value" do
      expect { described_class.new("too-short") }.to raise_error(Tina4::DocStore::InvalidId)
    end

    it "exposes a UTC generation_time" do
      gt = described_class.new.generation_time
      expect(gt).to be_a(Time)
      expect(gt.utc?).to be true
    end
  end

  # -- insert + find -----------------------------------------------------------

  describe "insert + find" do
    it "insert_one returns an ObjectId and rehydrates _id on read" do
      res = orders.insert_one({ "customer_id" => 1, "total" => 9.99 })
      expect(res.inserted_id).to be_a(Tina4::DocStore::ObjectId)
      got = orders.find_one({ "_id" => res.inserted_id })
      expect(got["customer_id"]).to eq(1)
      expect(got["total"]).to eq(9.99)
      expect(got["_id"]).to eq(res.inserted_id)
    end

    it "insert_many" do
      ids = orders.insert_many((0...5).map { |i| { "n" => i } }).inserted_ids
      expect(ids.length).to eq(5)
      expect(orders.count_documents({})).to eq(5)
    end

    it "preserves a custom _id" do
      orders.insert_one({ "_id" => "ORD-1", "x" => 1 })
      expect(orders.find_one({ "_id" => "ORD-1" })["x"]).to eq(1)
    end
  end

  # -- filter operators (pushed to SQL via json_extract) -----------------------

  describe "filters" do
    before do
      orders.insert_many([
        { "customer_id" => 1, "status" => "new", "total" => 10, "tags" => ["a"] },
        { "customer_id" => 2, "status" => "shipped", "total" => 50 },
        { "customer_id" => 3, "status" => "shipped", "total" => 99, "vip" => true }
      ])
    end

    it "equality" do
      expect(orders.count_documents({ "status" => "shipped" })).to eq(2)
    end

    it "$in" do
      got = orders.find({ "customer_id" => { "$in" => [1, 3] } }).to_a
      expect(got.map { |d| d["customer_id"] }.sort).to eq([1, 3])
    end

    it "comparisons" do
      expect(orders.count_documents({ "total" => { "$gt" => 10 } })).to eq(2)
      expect(orders.count_documents({ "total" => { "$gte" => 10, "$lt" => 99 } })).to eq(2)
      expect(orders.count_documents({ "total" => { "$lte" => 10 } })).to eq(1)
    end

    it "$ne" do
      expect(orders.count_documents({ "status" => { "$ne" => "shipped" } })).to eq(1)
    end

    it "$nin" do
      expect(orders.count_documents({ "status" => { "$nin" => ["shipped"] } })).to eq(1)
    end

    it "$exists" do
      expect(orders.count_documents({ "vip" => { "$exists" => true } })).to eq(1)
      expect(orders.count_documents({ "vip" => { "$exists" => false } })).to eq(2)
    end

    it "$regex (registered REGEXP user function)" do
      expect(orders.count_documents({ "status" => { "$regex" => "^ship" } })).to eq(2)
    end

    it "$or" do
      got = orders.find({ "$or" => [{ "customer_id" => 1 }, { "total" => { "$gt" => 90 } }] }).to_a
      expect(got.map { |d| d["customer_id"] }.sort).to eq([1, 3])
    end

    it "$and" do
      got = orders.find({ "$and" => [{ "status" => "shipped" }, { "total" => { "$gt" => 90 } }] }).to_a
      expect(got.map { |d| d["customer_id"] }).to eq([3])
    end

    it "pushdown uses json_extract" do
      where, params = Tina4::DocStore.compile_filter({ "customer_id" => { "$in" => [1, 2] } })
      expect(where).to include("json_extract(doc")
      expect(where).to include("IN (?,?)")
      expect(params).to eq([1, 2])
    end
  end

  # -- cursor: sort / limit / skip / projection --------------------------------

  describe "cursor" do
    before do
      orders.insert_many((0...10).map { |i| { "n" => i, "grp" => "g" } })
    end

    it "sort descending" do
      got = orders.find({ "grp" => "g" }).sort("n", -1).to_a
      expect(got.map { |d| d["n"] }).to eq((0..9).to_a.reverse)
    end

    it "limit + skip" do
      got = orders.find({ "grp" => "g" }).sort("n", 1).skip(2).limit(3).to_a
      expect(got.map { |d| d["n"] }).to eq([2, 3, 4])
    end

    it "projection include" do
      d = orders.find_one({ "n" => 5 }, { "n" => 1, "_id" => 0 })
      expect(d).to eq({ "n" => 5 })
    end

    it "projection exclude" do
      d = orders.find_one({ "n" => 5 }, { "grp" => 0 })
      expect(d).not_to have_key("grp")
      expect(d["n"]).to eq(5)
      expect(d).to have_key("_id")
    end
  end

  # -- datetime (Time) round-trip + sortability --------------------------------

  describe "datetime" do
    it "round-trips and sorts" do
      base = Time.utc(2024, 1, 1)
      orders.insert_many([
        { "k" => "b", "created_at" => Time.utc(2024, 3, 1) },
        { "k" => "a", "created_at" => Time.utc(2024, 1, 1) },
        { "k" => "c", "created_at" => Time.utc(2024, 6, 1) }
      ])
      got = orders.find({}).sort("created_at", -1).to_a
      expect(got.map { |d| d["k"] }).to eq(%w[c b a])
      expect(got.first["created_at"]).to be_a(Time)
      expect(orders.count_documents({ "created_at" => { "$gte" => base } })).to eq(3)
    end
  end

  # -- updates ------------------------------------------------------------------

  describe "updates" do
    it "$set / $inc / $unset" do
      oid = orders.insert_one({ "status" => "new", "count" => 1, "tmp" => "x" }).inserted_id
      orders.update_one({ "_id" => oid }, { "$set" => { "status" => "shipped" } })
      orders.update_one({ "_id" => oid }, { "$inc" => { "count" => 5 } })
      orders.update_one({ "_id" => oid }, { "$unset" => { "tmp" => "" } })
      d = orders.find_one({ "_id" => oid })
      expect(d["status"]).to eq("shipped")
      expect(d["count"]).to eq(6)
      expect(d).not_to have_key("tmp")
    end

    it "update_many" do
      orders.insert_many([{ "s" => "a" }, { "s" => "a" }, { "s" => "b" }])
      res = orders.update_many({ "s" => "a" }, { "$set" => { "s" => "z" } })
      expect(res.matched_count).to eq(2)
      expect(res.modified_count).to eq(2)
      expect(orders.count_documents({ "s" => "z" })).to eq(2)
    end

    it "replace_one keeps the _id" do
      oid = orders.insert_one({ "a" => 1 }).inserted_id
      orders.replace_one({ "_id" => oid }, { "b" => 2 })
      d = orders.find_one({ "_id" => oid })
      expect(d["b"]).to eq(2)
      expect(d).not_to have_key("a")
      expect(d["_id"]).to eq(oid)
    end

    it "upsert" do
      res = orders.update_one({ "sku" => "X1" }, { "$set" => { "qty" => 3 } }, upsert: true)
      expect(res.upserted_id).not_to be_nil
      expect(orders.find_one({ "sku" => "X1" })["qty"]).to eq(3)
    end

    it "nested $set (dotted)" do
      oid = orders.insert_one({ "a" => { "b" => 1 } }).inserted_id
      orders.update_one({ "_id" => oid }, { "$set" => { "a.c" => 2 } })
      d = orders.find_one({ "_id" => oid })
      expect(d["a"]).to eq({ "b" => 1, "c" => 2 })
    end

    it "full-document replace via update_one with no $ ops" do
      oid = orders.insert_one({ "a" => 1, "b" => 2 }).inserted_id
      orders.update_one({ "_id" => oid }, { "c" => 3 })
      d = orders.find_one({ "_id" => oid })
      expect(d["c"]).to eq(3)
      expect(d).not_to have_key("a")
      expect(d["_id"]).to eq(oid)
    end
  end

  # -- deletes + nested filter --------------------------------------------------

  describe "deletes and nested fields" do
    it "delete_one + delete_many" do
      orders.insert_many([{ "s" => "a" }, { "s" => "a" }, { "s" => "b" }])
      expect(orders.delete_one({ "s" => "a" }).deleted_count).to eq(1)
      expect(orders.delete_many({ "s" => "a" }).deleted_count).to eq(1)
      expect(orders.count_documents({})).to eq(1)
    end

    it "nested dotted filter" do
      orders.insert_one({ "addr" => { "city" => "Cape Town" } })
      orders.insert_one({ "addr" => { "city" => "Joburg" } })
      expect(orders.count_documents({ "addr.city" => "Cape Town" })).to eq(1)
    end
  end

  # -- serverless selection -----------------------------------------------------

  describe "serverless selection" do
    around do |example|
      saved = ENV.to_hash.slice("TINA4_MONGO_URI", "TINA4_SESSION_MONGO_URI", "TINA4_DOC_STORE_PATH")
      example.run
      ENV.delete("TINA4_MONGO_URI")
      ENV.delete("TINA4_SESSION_MONGO_URI")
      ENV.delete("TINA4_DOC_STORE_PATH")
      saved.each { |k, v| ENV[k] = v }
      Tina4::DocStore.reset_default_store
    end

    it "is serverless when no Mongo configured" do
      ENV.delete("TINA4_MONGO_URI")
      ENV.delete("TINA4_SESSION_MONGO_URI")
      expect(Tina4::DocStore.serverless?).to be true
    end

    it "get_collection returns a SqliteCollection when serverless" do
      Dir.mktmpdir do |dir|
        ENV.delete("TINA4_MONGO_URI")
        ENV.delete("TINA4_SESSION_MONGO_URI")
        ENV["TINA4_DOC_STORE_PATH"] = File.join(dir, "ds.db")
        Tina4::DocStore.reset_default_store
        col = Tina4::DocStore.get_collection("widgets")
        expect(col).to be_a(Tina4::DocStore::SqliteCollection)
        col.insert_one({ "name" => "bolt" })
        expect(col.find_one({ "name" => "bolt" })["name"]).to eq("bolt")
        Tina4::DocStore.reset_default_store
      end
    end

    it "supports [] item access on the database" do
      db.get_collection("a").insert_one({ "x" => 1 })
      expect(db["a"].count_documents({})).to eq(1)
    end
  end
end
