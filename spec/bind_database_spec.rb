# frozen_string_literal: true
#
# Spec for the v3 ORM database-binding rename + named-connection registry.
#
# Python (the reference) exposes bind_database(db, name=None): no name binds
# the global default, a name registers a named connection, and a model with
# _db = "analytics" resolves from that named registry. Ruby mirrors this with:
#
#   Tina4.bind_database(db)                  → sets Tina4.database (default)
#   Tina4.bind_database(db, name: :analytics) → Tina4.databases[:analytics]
#   class M < Tina4::ORM; self.db = :analytics; end → resolves the named conn
#
# There is NO Tina4.database= writer anymore (hard rename, no alias). The
# default still auto-resolves from TINA4_DATABASE_URL via auto_discover_db.
#
# The live two-database example boots real PostgreSQL (tina4_rb as the default,
# tina4_rb2 as the named :analytics connection), creates + inserts into a temp
# table in each, and proves via SELECT current_database() that a default model
# and a `self.db = :analytics` model resolve to different physical databases.
# It skips automatically when the pg gem is missing or PG is unreachable.
# (CI sets TINA4_TEST_PG_DB_2=tina4_rb2 and creates that second database; see
# .github/workflows/test.yml.)

require "spec_helper"
require "socket"

# Named models for the live two-database example. They must be real (named)
# classes, not Class.new anonymous classes, because table_name derives a
# fallback from self.name. The default model has no `db`, so it resolves the
# global default; the analytics model pins itself to the named :analytics
# connection via `self.db = :analytics`.
class BindDbOrder < Tina4::ORM
  table_name "bind_db_orders"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :sku
end

class BindDbEvent < Tina4::ORM
  self.db = :analytics
  table_name "bind_db_events"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

RSpec.describe "Tina4.bind_database + named connection registry" do
  # Reset module-level binding state around every example so the global
  # default and named registry never leak into (or from) other specs.
  around(:each) do |example|
    saved_default = Tina4.database
    saved_named = Tina4.databases.dup
    Tina4.databases.clear
    example.run
  ensure
    Tina4.bind_database(saved_default)
    Tina4.databases.clear
    Tina4.databases.merge!(saved_named)
  end

  let(:db)  { Object.new }
  let(:db2) { Object.new }

  describe "the global default" do
    it "bind_database(db) sets Tina4.database and returns the db" do
      expect(Tina4.bind_database(db)).to equal(db)
      expect(Tina4.database).to equal(db)
    end

    it "exposes database as a reader that reflects a bind, with no writer (hard rename, no alias)" do
      # The reader must reflect a real bind, not merely exist.
      Tina4.bind_database(db)
      expect(Tina4).to respond_to(:database)
      expect(Tina4.database).to equal(db)

      # There is no public writer (the old Tina4.database= was removed in
      # 3.13.19, with no alias).
      expect(Tina4).not_to respond_to(:database=)

      # And no private writer either: assigning via send must fail
      # behaviourally rather than silently clobbering the binding.
      expect { Tina4.send(:database=, db2) }.to raise_error(NoMethodError)

      # The earlier bind survives the failed assignment attempt.
      expect(Tina4.database).to equal(db)
    end
  end

  describe "named connections" do
    it "bind_database(db2, name: :analytics) registers a named connection" do
      Tina4.bind_database(db2, name: :analytics)
      expect(Tina4.databases[:analytics]).to equal(db2)
    end

    it "a named binding does not clobber the global default" do
      Tina4.bind_database(db)
      Tina4.bind_database(db2, name: :analytics)
      expect(Tina4.database).to equal(db)
      expect(Tina4.databases[:analytics]).to equal(db2)
    end

    it "accepts a String name and resolves it via Symbol key" do
      Tina4.bind_database(db2, name: "analytics")
      expect(Tina4.databases[:analytics]).to equal(db2)
    end
  end

  describe "model self.db = :name resolution" do
    it "resolves a model's Symbol db to the matching named connection" do
      Tina4.bind_database(db2, name: :analytics)
      klass = Class.new(Tina4::ORM) { self.db = :analytics }
      expect(klass.db).to equal(db2)
    end

    it "resolves a String db the same way" do
      Tina4.bind_database(db2, name: :analytics)
      klass = Class.new(Tina4::ORM) { self.db = "analytics" }
      expect(klass.db).to equal(db2)
    end

    it "raises a clear error naming the missing connection" do
      klass = Class.new(Tina4::ORM) { self.db = :missing }
      expect { klass.db }.to raise_error(/named database connection 'missing' is not registered/)
    end

    it "uses a directly-assigned instance without touching the registry" do
      instance = Object.new
      klass = Class.new(Tina4::ORM) { self.db = instance }
      expect(klass.db).to equal(instance)
    end

    it "falls back to the global default when db is unset" do
      Tina4.bind_database(db)
      klass = Class.new(Tina4::ORM)
      expect(klass.db).to equal(db)
    end
  end

  # ------------------------------------------------------------------
  # Live two-database example (default = tina4_rb, named :analytics = tina4_rb2)
  # ------------------------------------------------------------------
  describe "live two-database routing (PostgreSQL)" do
    PGBD_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
    PGBD_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "5432").to_i
    PGBD_USER = ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
    PGBD_PASS = ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
    PGBD_DEFAULT_DB = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")
    PGBD_NAMED_DB   = ENV.fetch("TINA4_TEST_PG_DB_2", "tina4_rb2")

    def self.pg_reachable?
      TCPSocket.new(PGBD_HOST, PGBD_PORT).tap(&:close)
      true
    rescue StandardError
      false
    end

    def self.pg_gem_available?
      require "pg"
      true
    rescue LoadError
      false
    end

    before(:all) do
      @skip_reason = if !self.class.pg_gem_available?
                       "pg gem not installed (skip)"
                     elsif !self.class.pg_reachable?
                       "PostgreSQL not reachable at #{PGBD_HOST}:#{PGBD_PORT} (skip)"
                     end
    end

    before(:each) do
      skip(@skip_reason) if @skip_reason

      @default_db = Tina4::Database.new(
        "postgres://#{PGBD_HOST}:#{PGBD_PORT}/#{PGBD_DEFAULT_DB}",
        username: PGBD_USER, password: PGBD_PASS
      )
      @analytics_db = Tina4::Database.new(
        "postgres://#{PGBD_HOST}:#{PGBD_PORT}/#{PGBD_NAMED_DB}",
        username: PGBD_USER, password: PGBD_PASS
      )

      @default_db.execute("DROP TABLE IF EXISTS bind_db_orders")
      @analytics_db.execute("DROP TABLE IF EXISTS bind_db_events")

      Tina4.bind_database(@default_db)
      Tina4.bind_database(@analytics_db, name: :analytics)
    end

    after(:each) do
      @default_db&.execute("DROP TABLE IF EXISTS bind_db_orders") rescue nil
      @analytics_db&.execute("DROP TABLE IF EXISTS bind_db_events") rescue nil
      @default_db&.close rescue nil
      @analytics_db&.close rescue nil
    end

    it "routes a default model and a :analytics model to different databases" do
      order_model = BindDbOrder  # no per-class db → resolves the global default
      event_model = BindDbEvent  # self.db = :analytics → resolves named conn

      # Each model resolves to its own connection.
      expect(order_model.db).to equal(@default_db)
      expect(event_model.db).to equal(@analytics_db)

      # Create a table + insert in each model's own database.
      expect(order_model.create_table).to be(true)
      expect(event_model.create_table).to be(true)

      order_model.db.execute("INSERT INTO bind_db_orders (sku) VALUES (?)", ["SKU-1"])
      event_model.db.execute("INSERT INTO bind_db_events (name) VALUES (?)", ["signup"])

      # The tables live in different physical databases: each table exists only
      # in its own connection, and current_database() differs.
      expect(@default_db.table_exists?("bind_db_orders")).to be(true)
      expect(@default_db.table_exists?("bind_db_events")).to be(false)
      expect(@analytics_db.table_exists?("bind_db_events")).to be(true)
      expect(@analytics_db.table_exists?("bind_db_orders")).to be(false)

      default_cdb   = order_model.db.fetch_one("SELECT current_database() AS cdb")[:cdb]
      analytics_cdb = event_model.db.fetch_one("SELECT current_database() AS cdb")[:cdb]

      expect(default_cdb).to eq(PGBD_DEFAULT_DB)
      expect(analytics_cdb).to eq(PGBD_NAMED_DB)
      expect(default_cdb).not_to eq(analytics_cdb)
    end
  end
end
