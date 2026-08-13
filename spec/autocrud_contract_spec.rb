# frozen_string_literal: true

# Shared contract suite for feature 27 -- AutoCrud (REST from ORM models).
#
# Fixture: tina4-documentation/plan/v3/fixtures/autocrud_contract.json
# Decisions: CRUD-DEC-01 (a consistent 422 with field errors on an invalid
# create/update -- fixes the POST `.create` + `.persisted?` NoMethodError ->
# stray 500 bug) + CRUD-DEC-02 (allow-list writable columns -- guard
# is_deleted, strip the PK on create/update -- and add wire tests,
# CRUD-WRITE-TESTS).
#
# NO MOCKS: real SQLite, a real AutoCrud-registered model, real RSA-signed
# JWTs via Tina4::Auth.get_token, dispatched through the REAL Tina4::RackApp
# via Tina4::TestClient. TestClient is not a stand-in here -- its own doc
# comment: "both the live RackApp#handle_route and the in-process TestClient
# call [enforce_route_auth], so the test surface enforces the identical gate
# as production" -- and this repo's own auto_crud_paginate_envelope_spec.rb
# (a promoted, proven-in-CONTRACT-MAP fixture for this SAME subsystem) uses
# exactly this client for its "no mocks" real-dispatch proof. Every existing
# AutoCrud spec in this repo (auto_crud_spec.rb) instead hand-builds a Rack
# env and calls route.handler.call(...) directly, bypassing the Router AND
# the auth gate entirely -- this is the first AutoCrud spec that goes through
# the real gate with a real token.
require "spec_helper"
require "tmpdir"

# Declared at TOP LEVEL, never inside RSpec.describe: a class/constant
# assigned in a describe block lands on Object (global) and clobbers other
# spec files. Unique name + unique table so it can never collide with
# CrudItem / PaginateRestItem / SecureNote et al. used by sibling AutoCrud
# specs.
#
# Soft-delete enabled + is_deleted DECLARED as a real field -- the worst case
# for CRUD-MASS-ASSIGNMENT (a genuine writable-looking column, not merely
# framework-injected DDL a client would never guess).
class AutocrudContractItem < Tina4::ORM
  table_name "autocrud_contract_item"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, required: true, max_length: 20
  integer_field :is_deleted, default: 0
end

RSpec.describe "Feature 27 - AutoCrud contract (CRUD-DEC-01 / CRUD-DEC-02)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_autocrud_contract") }
  let(:db_path) { File.join(tmp_dir, "autocrud_contract.db") }
  let(:db)      { Tina4::Database.new("sqlite:///" + db_path) }
  let(:client)  { Tina4::TestClient.new }

  before(:each) do
    Tina4.bind_database(db)
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!

    # A real RSA key pair for this test (parity with test_client_auth_spec.rb)
    # -- a blank TINA4_SECRET + a fresh .keys/ dir selects RS256.
    @prior_secret = ENV.delete("TINA4_SECRET")
    @prior_api_key = ENV.delete("TINA4_API_KEY")
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)

    db.execute(
      "CREATE TABLE IF NOT EXISTS autocrud_contract_item " \
      "(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER DEFAULT 0)"
    )

    # Secure-by-default: register() defaults public: false.
    Tina4::AutoCrud.register(AutocrudContractItem)
    Tina4::AutoCrud.generate_routes
  end

  after(:each) do
    ENV["TINA4_SECRET"] = @prior_secret if @prior_secret
    ENV["TINA4_API_KEY"] = @prior_api_key if @prior_api_key
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  def mint_token
    Tina4::Auth.get_token({ "sub" => "autocrud-contract-tester" })
  end

  def row(id)
    db.fetch_one("SELECT * FROM autocrud_contract_item WHERE id = ?", [id])
  end

  it "tokenless_write_returns_401" do
    post = client.post("/api/autocrud_contract_item", json: { name: "no-token" })
    expect(post.status).to eq(401)

    put = client.put("/api/autocrud_contract_item/1", json: { name: "no-token" })
    expect(put.status).to eq(401)

    del = client.delete("/api/autocrud_contract_item/1")
    expect(del.status).to eq(401)
  end

  it "valid_authenticated_post_returns_201" do
    token = mint_token
    r = client.post(
      "/api/autocrud_contract_item",
      json: { name: "widget-1" },
      headers: { "Authorization" => "Bearer #{token}" },
    )
    expect(r.status).to eq(201)
    expect(r.json["data"]["name"]).to eq("widget-1")
    expect(r.json["data"]["id"]).not_to be_nil
    expect(row(r.json["data"]["id"])[:name]).to eq("widget-1")
  end

  it "invalid_post_returns_422_with_field_errors" do
    token = mint_token
    before_count = db.fetch_one("SELECT COUNT(*) AS c FROM autocrud_contract_item")[:c]

    r = client.post(
      "/api/autocrud_contract_item",
      json: {},
      headers: { "Authorization" => "Bearer #{token}" },
    )
    expect(r.status).to eq(422)
    expect(r.json["errors"]).to be_a(Array)
    expect(r.json["errors"].any? { |e| e.to_s.include?("name") }).to be true

    after_count = db.fetch_one("SELECT COUNT(*) AS c FROM autocrud_contract_item")[:c]
    expect(after_count).to eq(before_count)
  end

  it "invalid_put_is_rejected" do
    token = mint_token
    created = client.post(
      "/api/autocrud_contract_item",
      json: { name: "put-target" },
      headers: { "Authorization" => "Bearer #{token}" },
    )
    id = created.json["data"]["id"]

    r = client.put(
      "/api/autocrud_contract_item/#{id}",
      json: { name: "x" * 100 }, # exceeds max_length: 20
      headers: { "Authorization" => "Bearer #{token}" },
    )
    expect(r.status).to eq(422)

    # Unchanged in the DB -- the invalid PUT never wrote through.
    expect(row(id)[:name]).to eq("put-target")
  end

  it "mass_assignment_is_blocked" do
    token = mint_token
    r = client.post(
      "/api/autocrud_contract_item",
      json: { name: "mass-assign", is_deleted: 1, id: 999_999 },
      headers: { "Authorization" => "Bearer #{token}" },
    )
    expect(r.status).to eq(201)
    id = r.json["data"]["id"]
    # The client-supplied PK never won -- a fresh id was assigned, not an
    # overwrite of (or a claim on) row 999999.
    expect(id).not_to eq(999_999)
    expect(row(id)[:is_deleted].to_i).to eq(0)

    put = client.put(
      "/api/autocrud_contract_item/#{id}",
      json: { is_deleted: 1 },
      headers: { "Authorization" => "Bearer #{token}" },
    )
    expect(put.status).to eq(200)
    expect(row(id)[:is_deleted].to_i).to eq(0)
  end

  it "list_is_the_seven_key_envelope" do
    r = client.get("/api/autocrud_contract_item")
    expect(r.status).to eq(200)
    expect(r.json.keys.sort).to eq(%w[limit offset page per_page records total total_pages])

    total_row = db.fetch_one("SELECT COUNT(*) AS c FROM autocrud_contract_item")
    expect(r.json["total"]).to eq(total_row[:c])
  end
end
