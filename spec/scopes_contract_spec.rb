# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "socket"

# Feature 23 - ORM scopes: the shared conformance contract, parity with
# tina4-python/tests/test_scopes_contract.py.
#
# SCOPE-DEC-01 (OWNER-DECISIONS.md Batch 4): fix PHP's scope global-registry
# collision. Ruby's `scope` runs inside `class << self` on the ORM base, but a
# class method's implicit receiver is the CALLING class, so
# `define_singleton_method` lands on the CALLER's own singleton class -- Ruby
# was ALREADY per-class. This suite proves it; Ruby's framework code is
# UNCHANGED for this feature.
#
# SCOPE-DEC-02: scopes stay TERMINAL LISTS (no compose/rebind/global-scope --
# the ledger did not separately ratify it).
#
# NO MOCKS: real SQLite AND real PostgreSQL (:55432, tina4/tina4). Positive AND
# negative throughout. Under TINA4_REQUIRE_SERVICES a postgres skip is a hard
# failure.

# Model classes are TOP LEVEL on purpose (a bare constant inside RSpec.describe
# lands on Object and clobbers another spec file).

# Two models sharing the SAME scope name with DIFFERENT filters -- the collision case.
class ScopeUserRb < Tina4::ORM
  table_name "scope_users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  integer_field :active, default: 0
end

class ScopeProductRb < Tina4::ORM
  table_name "scope_products"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  integer_field :discontinued, default: 0
end

# Soft-delete model: proves a scope respects the soft-delete filter.
class ScopeArticleRb < Tina4::ORM
  table_name "scope_articles"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :category
end

# Plain model with more rows than any single page -- proves limit/offset pushdown.
class ScopeWidgetRb < Tina4::ORM
  table_name "scope_widgets"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

SCOPE_ENGINES = %w[sqlite postgres].freeze

RSpec.describe "ORM scopes (feature 23)" do
  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 3) { true }
  rescue StandardError
    false
  end

  def engine_db(engine)
    if engine == "postgres"
      h = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
      p = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
      skip "postgres unreachable at #{h}:#{p} (set TINA4_TEST_PG_*)" unless reachable?(h, p)
      db = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")
      Tina4::Database.new("postgres://#{h}:#{p}/#{db}",
                          username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                          password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
    else
      Tina4::Database.new("sqlite:///#{Tempfile.new(["scopes", ".db"]).path}")
    end
  end

  def fresh(db, tables)
    Tina4.bind_database(db)
    tables.each do |t|
      begin
        db.execute("DROP TABLE IF EXISTS #{t}")
      rescue StandardError
        nil
      end
    end
  end

  def raw_count(db, table)
    row = db.fetch_one("SELECT COUNT(*) AS c FROM #{table}")
    (row[:c] || row["c"]).to_i
  end

  SCOPE_ENGINES.each do |engine|
    context "on #{engine}" do
      # ── SCOPE-DEC-01: two models, SAME scope name, DIFFERENT filters -- no collision ─
      it "two_models_same_scope_name_return_different_rows" do
        db = engine_db(engine)
        fresh(db, %w[scope_users scope_products])
        begin
          ScopeUserRb.create_table
          ScopeProductRb.create_table

          ScopeUserRb.new(name: "Alice", active: 1).save
          ScopeUserRb.new(name: "Bob", active: 0).save
          ScopeUserRb.new(name: "Carol", active: 1).save

          ScopeProductRb.new(name: "Widget", discontinued: 0).save
          ScopeProductRb.new(name: "Gadget", discontinued: 1).save
          ScopeProductRb.new(name: "Gizmo", discontinued: 0).save

          # SAME scope name ("active") registered on TWO different models with
          # DIFFERENT filters -- the exact SCOPE-PHP-COLLISION scenario. The
          # second registration must never overwrite or leak into the first
          # model's filter.
          ScopeUserRb.scope(:active, "active = ?", [1])
          ScopeProductRb.scope(:active, "discontinued = ?", [0])

          users = ScopeUserRb.active
          products = ScopeProductRb.active

          expect(users.map(&:name).sort).to eq(%w[Alice Carol]), "ScopeUserRb.active collided"
          expect(products.map(&:name).sort).to eq(%w[Gizmo Widget]), "ScopeProductRb.active collided"
        ensure
          db.close
        end
      end

      # ── SCOPE-DEC-02: a scope respects the soft-delete filter (via where) ───
      it "scope_excludes_a_soft_deleted_row" do
        db = engine_db(engine)
        fresh(db, %w[scope_articles])
        begin
          ScopeArticleRb.create_table

          one = ScopeArticleRb.new(name: "One", category: "news").save
          ScopeArticleRb.new(name: "Two", category: "news").save
          ScopeArticleRb.new(name: "Three", category: "news").save

          ScopeArticleRb.scope(:news, "category = ?", ["news"])
          expect(ScopeArticleRb.news.length).to eq(3)

          expect(one.delete).to be true

          visible = ScopeArticleRb.news
          expect(visible.length).to eq(2)
          expect(visible.map(&:name)).not_to include("One")

          # Negative: the row is still PHYSICALLY present (raw, unfiltered).
          expect(raw_count(db, "scope_articles")).to eq(3)
        ensure
          db.close
        end
      end

      # ── SCOPE-DEC-02: a scope pushes limit/offset to the database ───────────
      it "scope_honours_limit_and_offset" do
        db = engine_db(engine)
        fresh(db, %w[scope_widgets])
        begin
          ScopeWidgetRb.create_table

          15.times { |i| ScopeWidgetRb.new(name: "w#{i}").save }

          ScopeWidgetRb.scope(:everything, "1=1")

          # Negative: an explicit smaller limit is honoured exactly (proves the
          # argument reaches the DB rather than being silently discarded -- the
          # 2026-07-28 audit's Ruby finding).
          small = ScopeWidgetRb.everything(limit: 3)
          expect(small.length).to eq(3)

          # Two pages of the SAME scope, from the SAME 15-row set, are DISJOINT
          # -- proves offset reaches the database, not a client-side no-op.
          page1 = ScopeWidgetRb.everything(limit: 5, offset: 0)
          page2 = ScopeWidgetRb.everything(limit: 5, offset: 5)
          expect(page1.length).to eq(5)
          expect(page2.length).to eq(5)
          expect(page1.map(&:id) & page2.map(&:id)).to be_empty
        ensure
          db.close
        end
      end
    end
  end
end
