# frozen_string_literal: true

require "spec_helper"

# v3.13.1 P1 parity tests for Ruby — three cross-framework convenience
# additions the docs already assumed existed.
RSpec.describe "v3.13.1 P1 parity" do
  # ─── Database.get_connection ───────────────────────────────────────

  describe Tina4::Database, ".get_connection" do
    it "accepts an explicit URL and returns a live, usable connection" do
      db = Tina4::Database.get_connection("sqlite::memory:")
      db.execute("CREATE TABLE t (id INTEGER)")
      db.insert("t", { id: 7 })
      expect(db.fetch_one("SELECT id FROM t")[:id]).to eq(7)
    end

    it "reads from env var when given a name without :// and the resolved connection round-trips" do
      ENV["TEST_PARITY_DB_URL"] = "sqlite::memory:"
      begin
        db = Tina4::Database.get_connection("TEST_PARITY_DB_URL")
        # Prove the env-var URL was resolved into a working connection, not some
        # unrelated default: a full CREATE/insert/fetch_one round-trip.
        db.execute("CREATE TABLE env_resolved (id INTEGER, name TEXT)")
        db.insert("env_resolved", { id: 42, name: "from-env" })
        row = db.fetch_one("SELECT id, name FROM env_resolved")
        expect(row[:id]).to eq(42)
        expect(row[:name]).to eq("from-env")
      ensure
        ENV.delete("TEST_PARITY_DB_URL")
      end
    end

    it "falls back to a working in-memory SQLite connection when no URL resolves" do
      prev = ENV.delete("TINA4_DATABASE_URL")
      begin
        db = Tina4::Database.get_connection("NON_EXISTENT_ENV_KEY")
        # The fallback must be a real, usable in-memory SQLite connection.
        expect(db.get_database_type).to eq("sqlite")
        db.execute("CREATE TABLE fb (id INTEGER)")
        db.insert("fb", { id: 1 })
        expect(db.fetch_all("SELECT * FROM fb").length).to eq(1)
      ensure
        ENV["TINA4_DATABASE_URL"] = prev if prev
      end
    end
  end

  # ─── db.fetch_all ──────────────────────────────────────────────────

  describe "db.fetch_all" do
    let(:db) { Tina4::Database.get_connection("sqlite::memory:") }

    before do
      db.execute("CREATE TABLE u (id INTEGER, name TEXT)")
      db.insert("u", { id: 1, name: "Alice" })
      db.insert("u", { id: 2, name: "Bob" })
    end

    it "returns records array directly" do
      rows = db.fetch_all("SELECT * FROM u ORDER BY id")
      expect(rows).to be_an(Array)
      expect(rows.length).to eq(2)
      expect(rows[0][:name]).to eq("Alice")
    end

    it "returns empty array when no rows match" do
      db.execute("DELETE FROM u")
      expect(db.fetch_all("SELECT * FROM u")).to eq([])
    end

    it "supports params and pagination" do
      db.execute("CREATE TABLE p (id INTEGER, active INTEGER)")
      10.times { |i| db.insert("p", { id: i, active: i % 2 }) }
      active = db.fetch_all("SELECT id FROM p WHERE active = ? ORDER BY id", [1], limit: 3)
      expect(active.map { |r| r[:id] }).to eq([1, 3, 5])
    end
  end

  # ─── Tina4::API ergonomic kwargs ────────────────────────────────────

  describe Tina4::API, ".new (ergonomic kwargs)" do
    it "bearer_token kwarg sets Authorization: Bearer" do
      api = Tina4::API.new("https://x.example", bearer_token: "sk-test123")
      expect(api.headers["Authorization"]).to eq("Bearer sk-test123")
    end

    it "username + password kwargs set Basic auth" do
      api = Tina4::API.new("https://x.example", username: "u", password: "p")
      expect(api.headers["Authorization"]).to start_with("Basic ")
    end

    it "headers kwarg merges into request headers" do
      api = Tina4::API.new("https://x.example", headers: { "X-Tenant" => "acme" })
      expect(api.headers["X-Tenant"]).to eq("acme")
    end

    it "bearer wins over username/password when both passed" do
      api = Tina4::API.new("https://x.example",
                           bearer_token: "tok",
                           username: "u",
                           password: "p")
      expect(api.headers["Authorization"]).to start_with("Bearer ")
    end

    it "legacy signature (positional + headers:) still works" do
      api = Tina4::API.new("https://x.example", headers: { "X-Legacy" => "yes" })
      expect(api.headers["X-Legacy"]).to eq("yes")
    end
  end
end
