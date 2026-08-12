# frozen_string_literal: true

require "spec_helper"
require "socket"

# Feature 26 - ORM instance loading / hydration: the shared conformance
# contract, parity with tina4-python/tests/test_instance_loading_contract.py.
#
# LOAD-DEC-01 (LOAD-RUBY-ASYMMETRY + LOAD-RUBY-SIGNATURE): Ruby had TWO read
# paths with different coercion -- from_hash (the primary finder path)
# JSON-decoded json columns, but the instance load() fed the raw driver value
# straight to the setter, so Model.find(id).payload returned a parsed Hash
# while model.load(id).payload stayed a raw JSON String, same row, different
# type, purely by which read path you called. Fixed: load() now hydrates via
# from_hash -- ONE hydration path, not two -- and its signature is aligned to
# load(filter, params, include:) matching Python/PHP exactly (the old
# load(id) scalar-primary-key shortcut is REMOVED, a breaking change).
#
# Ruby's dynamic typing means it never had Python's LOAD-PY-REVALIDATE
# footgun (no property type to violate, and from_hash/load never re-run
# required/length/range) -- the constraint_violating_stored_row_still_hydrates
# case below is expected to be a no-op / already-correct proof for Ruby.
#
# LOAD-JSON-ONLY (LOAD-DEC-02): the scalar read-coercion contract is PINNED as
# JSON-only (OWNER-DECISIONS.md Batch 5) -- Ruby already coerces ONLY JSON
# columns on read (from_hash, unchanged); non-JSON scalars stay driver-typed.
#
# Case names are shared verbatim across all four frameworks and gated by
# scripts/audit-contract-fixtures.py.
#
# NO MOCKS: real SQLite (always) + real PostgreSQL :55432 tina4/tina4 (gated --
# skips cleanly when unreachable locally, a hard failure under
# TINA4_REQUIRE_SERVICES, e.g. on the lab).

# V1 ("loose"): defines the table's DDL. `name` carries no `required:` -- the
# column stays nullable, so a legitimate pre-existing row CAN hold NULL.
class LoadContractItemV1 < Tina4::ORM
  table_name "load_contract_item"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  json_field :payload
  boolean_field :active, default: true
end

# V2 ("tight"): the SAME table, but `name` is `required: true` -- simulating a
# constraint TIGHTENED after the row already existed (LOAD-PY-REVALIDATE).
# Only V2 is used to prove the read-hydrate-still-works / write-still-rejects
# split. Ruby's dynamic typing means this never crashes -- the point of this
# case for Ruby is to prove it STAYS that way (a regression lock, not a fix).
class LoadContractItemV2 < Tina4::ORM
  table_name "load_contract_item"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, required: true
  json_field :payload
  boolean_field :active, default: true
end

RSpec.describe "ORM instance loading (feature 26)" do
  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 3) { true }
  rescue StandardError
    false
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def run_cases
    LoadContractItemV1.create_table

    # ── json_column_round_trips_via_finder ──────────────────────────────
    saved = LoadContractItemV1.new(name: "alice", payload: { "tags" => %w[a b], "n" => 1 })
    expect(saved.save).not_to eq(false)

    got = LoadContractItemV1.find(saved.id)
    expect(got.payload).to be_a(Hash), "expected a native Hash, got #{got.payload.class}"
    expect(got.payload).to eq({ "tags" => %w[a b], "n" => 1 })

    # ── json_column_round_trips_via_load ─────────────────────────────────
    # THE case that catches LOAD-RUBY-ASYMMETRY: load() must coerce JSON
    # identically to the finder path above, not leave it as a raw String.
    reloaded = LoadContractItemV1.new
    reloaded.id = saved.id
    expect(reloaded.load).to be true
    expect(reloaded.payload).to be_a(Hash), "expected a native Hash, got #{reloaded.payload.class}"
    expect(reloaded.payload).to eq({ "tags" => %w[a b], "n" => 1 })

    # ── constraint_violating_stored_row_still_hydrates ───────────────────
    # V1 (no `required` on `name`) legitimately stores a nil name -- an
    # ordinary nullable-column row, saved through the NORMAL write path.
    stored = LoadContractItemV1.new(name: nil, payload: { "k" => "v" })
    expect(stored.save).not_to eq(false)

    # V2 (SAME table, `name` now `required: true`) reads it back. Ruby's
    # dynamic typing means this was NEVER at risk of raising -- this proves
    # it stays that way.
    still_readable = LoadContractItemV2.find(stored.id)
    expect(still_readable).not_to be_nil, "a required-but-nil stored row must still hydrate via find"
    expect(still_readable.name).to be_nil

    # The SAME row must also survive a full select (not just a single find),
    # proving one non-conforming row does not abort a page of results.
    all_rows = LoadContractItemV2.all
    expect(all_rows.map(&:id)).to include(stored.id)

    # Prove the write path is UNCHANGED: V2's OWN save still rejects a NEW
    # row missing the now-required `name` -- feature 19's richer validate(),
    # untouched by this feature.
    rejected = LoadContractItemV2.new(payload: {})
    result = rejected.save
    expect(result).to eq(false), "save must still reject a missing required field"
    expect(rejected.get_error).not_to be_nil
    expect(rejected.get_error.downcase).to include("required")

    # ── partial_select_yields_partial_instance ────────────────────────────
    full = LoadContractItemV1.new(name: "partial-target", payload: { "z" => 9 })
    expect(full.save).not_to eq(false)

    partial = LoadContractItemV1.select(
      "SELECT id, name FROM load_contract_item WHERE id = ?", [full.id]
    )
    expect(partial.length).to eq(1)
    inst = partial.first
    expect(inst.name).to eq("partial-target")
    # `payload` and `active` were NOT selected -- they must sit at their
    # declared class defaults, not crash and not carry a stale/wrong value.
    expect(inst.active).to be true
    expect(inst.payload).to be_nil
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  context "on sqlite" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_instance_loading") }
    let(:db_path) { File.join(tmp_dir, "test.db") }
    let(:db) { Tina4::Database.new("sqlite:///#{db_path}") }

    before(:each) { Tina4.bind_database(db) }

    after(:each) do
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    it "json_column_round_trips_via_finder_and_via_load, and every other shared case" do
      run_cases
    end
  end

  context "on postgres" do
    let(:pg_host) { ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1") }
    let(:pg_port) { ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i }

    before(:each) do
      skip "postgres unreachable at #{pg_host}:#{pg_port} (set TINA4_TEST_PG_*)" unless reachable?(pg_host, pg_port)
      db_name = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")
      @db = Tina4::Database.new(
        "postgres://#{pg_host}:#{pg_port}/#{db_name}",
        username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
        password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
      )
      Tina4.bind_database(@db)
      begin
        @db.execute("DROP TABLE IF EXISTS load_contract_item")
      rescue StandardError
        nil
      end
    end

    after(:each) do
      next unless @db

      begin
        @db.execute("DROP TABLE IF EXISTS load_contract_item")
      rescue StandardError
        nil
      end
      @db.close
    end

    it "json_column_round_trips_via_finder_and_via_load, and every other shared case" do
      run_cases
    end
  end
end
