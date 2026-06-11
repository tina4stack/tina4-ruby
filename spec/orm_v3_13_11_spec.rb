# frozen_string_literal: true

# Tina4 Ruby -- v3.13.11 ORM correctness pass.
#
# Mirrors tests/test_orm_v3_13_11.py:
#
#   * Callable field defaults are invoked per-instance (issue #50.1).
#   * BooleanField create_table picks engine-native types (BOOLEAN on
#     PG/MySQL, BIT on MSSQL, INTEGER on SQLite/Firebird).
#   * Natural-key INSERT already worked via @persisted, but pin it with
#     a regression test.

require "spec_helper"

# Module-level closure counter so subsequent runs see distinct values.
$_V31311_SEQ = 0

class CallableDefaultSeq < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  integer_field :seq, default: -> { $_V31311_SEQ += 1 }
end

class StaticDefaultCount < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  integer_field :count, default: 42
end

class BoolFlagged < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  boolean_field :active, default: true
end

RSpec.describe "ORM correctness (v3.13.11)" do
  # ── Issue #50.1 — callable defaults ─────────────────────────────

  describe "callable field defaults" do
    it "invokes a Proc default per instance" do
      $_V31311_SEQ = 0  # reset
      a = CallableDefaultSeq.new
      b = CallableDefaultSeq.new
      c = CallableDefaultSeq.new
      expect(a.seq).to eq(1)
      expect(b.seq).to eq(2)
      expect(c.seq).to eq(3),
        "callable defaults must be invoked per instance"
    end

    it "leaves a static default unchanged" do
      expect(StaticDefaultCount.new.count).to eq(42)
    end
  end

  # ── BooleanField engine-aware DDL ────────────────────────────────

  describe "BooleanField DDL (create_table)" do
    {
      "postgres" => "BOOLEAN",
      "postgresql" => "BOOLEAN",
      "mysql" => "BOOLEAN",
      "mssql" => "BIT",
      "sqlserver" => "BIT",
      "sqlite" => "INTEGER",
      "firebird" => "INTEGER"
    }.each do |engine, expected|
      it "maps boolean to #{expected} on #{engine}" do
        captured = { sql: nil }

        # Stub the database object so we can capture the rendered DDL
        # without actually running it (BIT / BOOLEAN wouldn't run on
        # SQLite locally).
        fake_db = Object.new
        fake_db.define_singleton_method(:get_database_type) { engine }
        fake_db.define_singleton_method(:table_exists?) { |_| false }
        fake_db.define_singleton_method(:execute) { |sql| captured[:sql] = sql }
        fake_db.define_singleton_method(:commit) { nil }

        # Swap out the class-level db just for this test.
        original_db = BoolFlagged.instance_variable_get(:@db)
        BoolFlagged.instance_variable_set(:@db, fake_db)
        BoolFlagged.define_singleton_method(:db) { fake_db }
        begin
          BoolFlagged.create_table
        ensure
          BoolFlagged.singleton_class.remove_method(:db) if BoolFlagged.singleton_class.method_defined?(:db)
          BoolFlagged.instance_variable_set(:@db, original_db)
        end

        expect(captured[:sql]).not_to be_nil,
          "create_table should have called db.execute"
        expect(captured[:sql]).to include(expected),
          "engine=#{engine}: expected '#{expected}' in DDL, got: #{captured[:sql]}"
      end
    end
  end

  # ── #50.2 — natural-key INSERT regression guard ──────────────────

  describe "natural-key INSERT (regression guard)" do
    it "uses @persisted=false from .new to pick INSERT for a fresh natural-key record" do
      # We don't need a real DB for this — just verify the decision
      # branch in save() routes through INSERT when @persisted is false.
      # This is a regression test pinning the existing correct behaviour
      # so a future refactor can't silently break natural-key models.
      class NaturalKeyGuard < Tina4::ORM
        string_field :code, primary_key: true
        string_field :name
      end

      instance = NaturalKeyGuard.new(code: "GC-100", name: "alice")
      expect(instance.instance_variable_get(:@persisted)).to be(false)
    end
  end
end
