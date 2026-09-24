# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# ADR-0069 - identifiers that reach SQL come from the model, never the request.
#
# Three surfaces, one rule:
#   A. AutoCrud list route: every filter[KEY] and every sort part must resolve to
#      a DECLARED model field (attribute name or its mapped DB column), otherwise
#      400 UNKNOWN_FIELD before any SQL runs.
#   B. ORM find(hash): every key resolves through the same resolver, otherwise
#      ArgumentError before any SQL runs.
#   C. DocStore SQLite fallback: every dot segment of a field path must match
#      [A-Za-z0-9_-]+, otherwise ArgumentError before any SQL is built; the paths
#      it accepts return the same documents as a real MongoDB.
#
# NO MOCKS: real SQLite, real PostgreSQL / MySQL / MSSQL / Firebird for the ORM
# find case, real MongoDB for the DocStore parity case, real dispatch through
# Tina4::TestClient for AutoCrud. Under TINA4_REQUIRE_SERVICES the spec_helper
# gate fails the run on an unreachable engine (only Firebird carries a
# [needs:firebird] tag, excused solely while TINA4_TEST_FIREBIRD_URL is unset),
# and the engine list is a plain loop, not an RSpec `if:` filter, so nothing
# vanishes from the count.

require "spec_helper"
require "securerandom"
require "socket"
require "tmpdir"

# Top-level on purpose: a constant assigned inside RSpec.describe lands on
# Object and can clobber other spec files.
class IdentifierAllowListItem < Tina4::ORM
  table_name "ident_allow_item"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :category
  integer_field :rank
  string_field :owner_name
  self.field_mapping = { "owner_name" => "owner_col" }
end

# Same shape without auto-increment, so one raw DDL runs on every engine.
class IdentifierFindItem < Tina4::ORM
  table_name "ident_find_item"
  integer_field :id, primary_key: true
  string_field :name
  string_field :owner_name
  self.field_mapping = { "owner_name" => "owner_col" }
end

# Tina4::Crud (Ruby-only HTML CRUD component) sort model, with a mapped field.
class IdentifierCrudSortItem < Tina4::ORM
  table_name "ident_crud_sort"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :owner_name
  self.field_mapping = { "owner_name" => "owner_col" }
end

# A model bound to its OWN connection, not the global default.
class IdentifierBoundConnectionItem < Tina4::ORM
  table_name "ident_bound_item"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

# A natural (non-integer) primary key, addressed by AutoCrud's id routes.
class IdentifierCodeItem < Tina4::ORM
  table_name "ident_code_item"
  string_field :code, primary_key: true
  string_field :name
end

# Generated GraphQL CRUD over a real SQLite table.
class IdentGqlItem < Tina4::ORM
  table_name "ident_gql_item"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

IDENT_ALLOW_SAFE_DOCS = [
  { "_id" => "doc1", "a_b" => 1, "a-b" => 30, "A1" => "x", "nested" => { "key" => "v1" } },
  { "_id" => "doc2", "a_b" => 2, "a-b" => 10, "A1" => "y", "nested" => { "key" => "v2" } },
  { "_id" => "doc3", "a_b" => 1, "a-b" => 20, "A1" => "z", "nested" => { "key" => "v1" } }
].freeze

# Every accepted key shape, as filters and as sort keys.
IDENT_ALLOW_SAFE_QUERIES = {
  "a_b" => [{ "a_b" => 1 }, nil],
  "a-b" => [{ "a-b" => { "$gte" => 20 } }, nil],
  "A1" => [{ "A1" => { "$in" => %w[x y] } }, nil],
  "nested.key" => [{ "nested.key" => "v1" }, nil],
  "_id" => [{ "_id" => "doc2" }, nil],
  "$or" => [{ "$or" => [{ "a_b" => 2 }, { "nested.key" => { "$ne" => "v1" } }, { "A1" => "z" }] }, nil],
  "sort a-b desc" => [{}, [["a-b", -1]]],
  "sort nested.key, A1" => [{}, [["nested.key", 1], ["A1", -1]]],
  "sort _id" => [{ "a_b" => { "$exists" => true } }, [["_id", 1]]]
}.freeze

RSpec.describe "ADR-0069 identifier allow-list contract" do
  # ── A. AutoCrud list route ────────────────────────────────────────────────
  describe "AutoCrud list filter and sort" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_ident_allow") }
    let(:db)      { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "ident.db")) }
    let(:client)  { Tina4::TestClient.new }

    before(:each) do
      Tina4.bind_database(db)
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      # secret_note is a REAL column the model does not declare.
      db.execute(
        "CREATE TABLE ident_allow_item (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, " \
        "category TEXT, rank INTEGER, owner_col TEXT, secret_note TEXT)"
      )
      [
        [1, "alpha", "x", 3, "ann", "s1"],
        [2, "bravo", "y", 1, "bob", "s2"],
        [3, "charlie", "x", 2, "ann", "s3"],
        [4, "delta", "y", 4, "cat", "s4"]
      ].each do |row|
        db.execute("INSERT INTO ident_allow_item (id, name, category, rank, owner_col, secret_note) " \
                   "VALUES (?, ?, ?, ?, ?, ?)", row)
      end
      Tina4::AutoCrud.register(IdentifierAllowListItem)
      Tina4::AutoCrud.generate_routes
    end

    after(:each) do
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    def list(query)
      client.get("/api/ident_allow_item?#{query}")
    end

    def names(response)
      response.json["records"].map { |r| r["name"] }
    end

    def expect_unknown(response, kind, key)
      expect(response.status).to eq(400), "expected 400 for #{kind} #{key.inspect}, got #{response.status}: #{response.body}"
      expect(response.json).to eq(
        "error" => true, "code" => "UNKNOWN_FIELD",
        "message" => "Unknown #{kind} field '#{key}'", "status" => 400
      )
    end

    it "unknown_filter_field_returns_400" do
      # An undeclared-but-real column.
      expect_unknown(list("filter[secret_note]=s1"), "filter", "secret_note")
      # Keys that are not identifiers: a space, a quote, a bracket.
      expect_unknown(list("filter[na%20me]=alpha"), "filter", "na me")
      expect_unknown(list("filter[name%27]=alpha"), "filter", "name'")
      expect_unknown(list("filter[name%5Bx]=alpha"), "filter", "name[x")
      # One bad key rejects the request even alongside a good one.
      expect_unknown(list("filter[name]=alpha&filter[secret_note]=s1"), "filter", "secret_note")
    end

    it "unknown_sort_field_returns_400" do
      expect_unknown(list("sort=secret_note"), "sort", "secret_note")
      expect_unknown(list("sort=-secret_note"), "sort", "secret_note")
      expect_unknown(list("sort=na%20me"), "sort", "na me")
      expect_unknown(list("sort=name%27"), "sort", "name'")
      expect_unknown(list("sort=name,-secret_note"), "sort", "secret_note")
      # With a valid filter the sort is still checked.
      expect_unknown(list("filter[category]=x&sort=secret_note"), "sort", "secret_note")
    end

    it "declared_filter_and_sort_still_work" do
      # Declared field filter.
      r = list("filter[category]=x&sort=name")
      expect(r.status).to eq(200)
      expect(names(r)).to eq(%w[alpha charlie])
      expect(r.json["total"]).to eq(2)

      # Mapped field: by attribute name AND by its DB column.
      by_attribute = list("filter[owner_name]=ann&sort=name")
      expect(by_attribute.status).to eq(200)
      expect(names(by_attribute)).to eq(%w[alpha charlie])
      by_column = list("filter[owner_col]=ann&sort=name")
      expect(by_column.status).to eq(200)
      expect(names(by_column)).to eq(%w[alpha charlie])

      # -field is DESC, a bare field is ASC; sort without any filter.
      expect(names(list("sort=-rank"))).to eq(%w[delta alpha charlie bravo])
      expect(names(list("sort=rank"))).to eq(%w[bravo charlie alpha delta])

      # Multi-field sort, empty parts skipped, a mapped field sortable by attribute.
      expect(names(list("sort=category,-rank"))).to eq(%w[alpha charlie delta bravo])
      expect(names(list("sort=,-owner_name,name,"))).to eq(%w[delta bravo alpha charlie])
      expect(names(list("sort=-owner_col,name"))).to eq(%w[delta bravo alpha charlie])

      # Filter and sort together.
      expect(names(list("filter[category]=y&sort=-rank"))).to eq(%w[delta bravo])
    end

    it "odd_typed_query_values_return_400" do
      invalid = lambda do |message|
        { "error" => true, "code" => "INVALID_QUERY_PARAMETER", "message" => message, "status" => 400 }
      end

      # sort must be one comma-separated string, never a list or a map.
      ["sort[]=name", "sort[a]=name", "sort[]=name&sort[]=rank", "filter[category]=x&sort[0]=name"].each do |query|
        response = list(query)
        expect(response.status).to eq(400), "#{query}: #{response.status} #{response.body}"
        expect(response.json).to eq(invalid.call("Query parameter 'sort' must be a single comma-separated string"))
      end

      # A filter value must be a single value, never a list or a nested map.
      ["filter[name][]=alpha", "filter[name][x]=alpha", "filter[name][gt]=a", "filter[category]=x&filter[name][]=alpha"].each do |query|
        response = list(query)
        expect(response.status).to eq(400), "#{query}: #{response.status} #{response.body}"
        expect(response.json).to eq(invalid.call("Filter value for 'name' must be a single value"))
      end

      # The plain forms still work.
      plain = list("filter[name]=alpha&sort=name")
      expect(plain.status).to eq(200)
      expect(names(plain)).to eq(%w[alpha])
    end

    def authorised
      prior = { secret: ENV.delete("TINA4_SECRET"), api_key: ENV.delete("TINA4_API_KEY") }
      Tina4::Auth.instance_variable_set(:@private_key, nil)
      Tina4::Auth.instance_variable_set(:@public_key, nil)
      Tina4::Auth.instance_variable_set(:@keys_dir, nil)
      Tina4::Auth.setup(tmp_dir)
      yield({ "Authorization" => "Bearer #{Tina4::Auth.get_token({ 'sub' => 'write-tester' })}" })
    ensure
      ENV["TINA4_SECRET"] = prior[:secret] if prior[:secret]
      ENV["TINA4_API_KEY"] = prior[:api_key] if prior[:api_key]
    end

    def stored(id)
      db.fetch_one("SELECT * FROM ident_allow_item WHERE id = ?", [id])
    end

    it "autocrud_write_body_accepts_only_declared_fields" do
      authorised do |auth|
        # POST: declared fields by attribute AND by mapped column are written;
        # an undeclared-but-real column, non-identifier keys and the PK are dropped.
        created = client.post("/api/ident_allow_item", headers: auth, json: {
          "name" => "echo", "category" => "z", "owner_col" => "dan",
          "secret_note" => "written", "na me" => "x", "rank'" => 7, "id" => 999
        })
        expect(created.status).to eq(201), created.body
        id = created.json["data"]["id"]
        expect(id).not_to eq(999)
        row = stored(id)
        expect([row[:name], row[:category], row[:owner_col], row[:secret_note], row[:rank]])
          .to eq(["echo", "z", "dan", nil, nil])

        # PUT: the same allow-list; the row is addressed by the URL id only.
        updated = client.put("/api/ident_allow_item/1", headers: auth, json: {
          "owner_col" => "eve", "secret_note" => "written", "id" => 998, "na me" => "x"
        })
        expect(updated.status).to eq(200), updated.body
        expect([stored(1)[:owner_col], stored(1)[:secret_note]]).to eq(%w[eve s1])
        expect(stored(998)).to be_nil

        by_attribute = client.put("/api/ident_allow_item/2", headers: auth, json: { "owner_name" => "fay" })
        expect(by_attribute.status).to eq(200), by_attribute.body
        expect(stored(2)[:owner_col]).to eq("fay")
      end
    end

    it "orm_save_writes_only_declared_fields" do
      # INSERT: an undeclared key passed to new() never reaches the column list.
      item = IdentifierAllowListItem.new(name: "golf", owner_name: "gus", secret_note: "written")
      expect(item.save).to be_truthy
      row = stored(item.id)
      expect([row[:name], row[:owner_col], row[:secret_note]]).to eq(["golf", "gus", nil])

      # UPDATE: a hydrated row carrying an undeclared column saves only declared ones.
      loaded = IdentifierAllowListItem.from_hash(
        { "id" => 1, "name" => "alpha", "owner_col" => "ann", "secret_note" => "overwritten" }
      )
      loaded.name = "alpha2"
      expect(loaded.save).to be_truthy
      expect([stored(1)[:name], stored(1)[:secret_note]]).to eq(%w[alpha2 s1])
    end
  end

  # ── Row addressing by id: AutoCrud id routes and generated GraphQL ───────
  describe "id addressing" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_ident_id") }
    let(:db)      { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "ids.db")) }
    let(:client)  { Tina4::TestClient.new }

    before(:each) do
      Tina4.bind_database(db)
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      db.execute("CREATE TABLE ident_allow_item (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, " \
                 "category TEXT, rank INTEGER, owner_col TEXT, secret_note TEXT)")
      db.execute("CREATE TABLE ident_code_item (code TEXT PRIMARY KEY, name TEXT)")
      db.execute("CREATE TABLE ident_gql_item (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      %w[alpha bravo charlie delta].each_with_index do |name, index|
        db.execute("INSERT INTO ident_allow_item (id, name) VALUES (?, ?)", [index + 1, name])
        db.execute("INSERT INTO ident_gql_item (id, name) VALUES (?, ?)", [index + 1, name])
      end
      [%w[alpha-code alpha], %w[bravo-code bravo], %w[0 zero]].each do |code, name|
        db.execute("INSERT INTO ident_code_item (code, name) VALUES (?, ?)", [code, name])
      end
    end

    after(:each) do
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    def rows(table, key = "id")
      db.fetch("SELECT * FROM #{table} ORDER BY #{key}").records.map { |row| [row[key.to_sym].to_s, row[:name]] }
    end

    def with_auth
      prior = { secret: ENV.delete("TINA4_SECRET"), api_key: ENV.delete("TINA4_API_KEY") }
      Tina4::Auth.instance_variable_set(:@private_key, nil)
      Tina4::Auth.instance_variable_set(:@public_key, nil)
      Tina4::Auth.instance_variable_set(:@keys_dir, nil)
      Tina4::Auth.setup(tmp_dir)
      yield({ "Authorization" => "Bearer #{Tina4::Auth.get_token({ 'sub' => 'id-tester' })}" })
    ensure
      ENV["TINA4_SECRET"] = prior[:secret] if prior[:secret]
      ENV["TINA4_API_KEY"] = prior[:api_key] if prior[:api_key]
    end

    it "autocrud_id_route_addresses_only_that_row" do
      Tina4::AutoCrud.register(IdentifierAllowListItem)
      Tina4::AutoCrud.register(IdentifierCodeItem)
      Tina4::AutoCrud.generate_routes
      with_auth do |auth|
        # A non-first id reads, updates and deletes that row and no other.
        expect(client.get("/api/ident_allow_item/3").json["data"]["name"]).to eq("charlie")
        expect(client.put("/api/ident_allow_item/3", headers: auth, json: { "name" => "charlie2" }).status).to eq(200)
        expect(client.delete("/api/ident_allow_item/2", headers: auth).status).to eq(200)
        expect(rows("ident_allow_item")).to eq([%w[1 alpha], %w[3 charlie2], %w[4 delta]])

        # A non-numeric id on an integer key is 404 and changes nothing.
        before = rows("ident_allow_item")
        %w[3x abc 4.0].each do |bad_id|
          expect(client.get("/api/ident_allow_item/#{bad_id}").status).to eq(404), "GET #{bad_id}"
          expect(client.put("/api/ident_allow_item/#{bad_id}", headers: auth, json: { "name" => "x" }).status)
            .to eq(404), "PUT #{bad_id}"
          expect(client.delete("/api/ident_allow_item/#{bad_id}", headers: auth).status).to eq(404), "DELETE #{bad_id}"
        end
        expect(rows("ident_allow_item")).to eq(before)

        # A string natural key is bound as-is, never coerced to an integer.
        expect(client.get("/api/ident_code_item/bravo-code").json["data"]["name"]).to eq("bravo")
        expect(client.put("/api/ident_code_item/bravo-code", headers: auth, json: { "name" => "bravo2" }).status).to eq(200)
        expect(client.delete("/api/ident_code_item/alpha-code", headers: auth).status).to eq(200)
        expect(client.get("/api/ident_code_item/missing").status).to eq(404)
        expect(rows("ident_code_item", "code")).to eq([%w[0 zero], %w[bravo-code bravo2]])
      end
    end

    it "graphql_id_argument_addresses_only_that_row" do
      schema = Tina4::GraphQLSchema.new
      schema.from_orm(IdentGqlItem)
      gql = Tina4::GraphQL.new(schema)

      single = gql.execute('{ ident_gql_item(id: "3") { id name } }')
      expect(single["errors"]).to be_nil
      expect(single["data"]["ident_gql_item"]["name"]).to eq("charlie")

      updated = gql.execute('mutation { updateIdentGqlItem(id: "3", input: { name: "charlie2" }) { id name } }')
      expect(updated["errors"]).to be_nil
      expect(updated["data"]["updateIdentGqlItem"]["name"]).to eq("charlie2")
      deleted = gql.execute('mutation { deleteIdentGqlItem(id: "2") }')
      expect(deleted["errors"]).to be_nil
      expect(deleted["data"]["deleteIdentGqlItem"]).to be(true)
      expect(rows("ident_gql_item")).to eq([%w[1 alpha], %w[3 charlie2], %w[4 delta]])

      # A non-matching id reads nothing and changes nothing.
      before = rows("ident_gql_item")
      %w[99 3x abc].each do |bad_id|
        missing = gql.execute("{ ident_gql_item(id: \"#{bad_id}\") { id name } }")
        expect(missing["errors"]).to be_nil, "query #{bad_id}: #{missing['errors']}"
        expect(missing["data"]["ident_gql_item"]).to be_nil
        update = gql.execute("mutation { updateIdentGqlItem(id: \"#{bad_id}\", input: { name: \"x\" }) { id } }")
        expect(update["errors"]).to be_nil, "update #{bad_id}: #{update['errors']}"
        expect(update["data"]["updateIdentGqlItem"]).to be_nil
        delete = gql.execute("mutation { deleteIdentGqlItem(id: \"#{bad_id}\") }")
        expect(delete["errors"]).to be_nil, "delete #{bad_id}: #{delete['errors']}"
        expect(delete["data"]["deleteIdentGqlItem"]).to be(false)
      end
      expect(rows("ident_gql_item")).to eq(before)
    end
  end

  # ── E. AutoCrud reads through the model's own connection ──────────────────
  describe "AutoCrud connection" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_ident_bound") }
    let(:client)  { Tina4::TestClient.new }

    after(:each) do
      IdentifierBoundConnectionItem.db = nil
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      FileUtils.rm_rf(tmp_dir)
    end

    it "autocrud_list_uses_the_registered_connection" do
      global_db = Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "global.db"))
      model_db = Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "model.db"))
      begin
        ddl = "CREATE TABLE ident_bound_item (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)"
        # The global database has the table but NONE of the rows.
        global_db.execute(ddl)
        model_db.execute(ddl)
        model_db.execute("INSERT INTO ident_bound_item (id, name) VALUES (?, ?)", [1, "bound-one"])
        model_db.execute("INSERT INTO ident_bound_item (id, name) VALUES (?, ?)", [2, "bound-two"])

        Tina4.bind_database(global_db)
        IdentifierBoundConnectionItem.db = model_db
        Tina4::Router.clear!
        Tina4::AutoCrud.clear!
        Tina4::AutoCrud.register(IdentifierBoundConnectionItem)
        Tina4::AutoCrud.generate_routes

        listed = client.get("/api/ident_bound_item?sort=-id")
        expect(listed.status).to eq(200), listed.body
        expect(listed.json["records"].map { |r| r["name"] }).to eq(%w[bound-two bound-one])
        expect(listed.json["total"]).to eq(2)

        filtered = client.get("/api/ident_bound_item?filter[name]=bound-one")
        expect(filtered.json["records"].map { |r| r["id"] }).to eq([1])
        expect(filtered.json["total"]).to eq(1)

        single = client.get("/api/ident_bound_item/2")
        expect(single.status).to eq(200), single.body
        expect(single.json["data"]["name"]).to eq("bound-two")

        # And the global database really was left alone.
        expect(global_db.fetch_one("SELECT COUNT(*) AS c FROM ident_bound_item")[:c]).to eq(0)
      ensure
        global_db.close
        model_db.close
      end
    end
  end

  # ── B. ORM find(hash) + G3. db write helpers, on every engine ─────────────
  describe "ORM find(hash) and db write helpers" do
    def reachable?(host, port)
      Socket.tcp(host, port, connect_timeout: 3) { true }
    rescue StandardError
      false
    end

    def engine_db(engine)
      case engine
      when "sqlite"
        Tina4::Database.new("sqlite:///" + File.join(SpecTmpdir.create, "ident_find.db"))
      when "postgres"
        h = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
        p = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
        skip("postgres unreachable at #{h}:#{p} (set TINA4_TEST_PG_*)") unless reachable?(h, p)
        Tina4::Database.new("postgres://#{h}:#{p}/#{ENV.fetch('TINA4_TEST_PG_DB', 'tina4_rb')}",
                            username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                            password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
      when "mysql"
        h = ENV.fetch("TINA4_TEST_MYSQL_HOST", "127.0.0.1")
        p = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
        skip("mysql unreachable at #{h}:#{p} (set TINA4_TEST_MYSQL_*)") unless reachable?(h, p)
        Tina4::Database.new("mysql://#{h}:#{p}/#{ENV.fetch('TINA4_TEST_MYSQL_DB', 'tina4_test')}",
                            username: ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4"),
                            password: ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4"))
      when "mssql"
        h = ENV.fetch("TINA4_TEST_MSSQL_HOST", "127.0.0.1")
        p = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
        skip("mssql unreachable at #{h}:#{p} (set TINA4_TEST_MSSQL_*)") unless reachable?(h, p)
        Tina4::Database.new("mssql://#{h}:#{p}/#{ENV.fetch('TINA4_TEST_MSSQL_DB', 'tina4_test')}",
                            username: ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa"),
                            password: ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure"))
      else
        url = ENV["TINA4_TEST_FIREBIRD_URL"]
        skip("[needs:firebird] TINA4_TEST_FIREBIRD_URL not set (needs a live Firebird)") if url.nil? || url.empty?
        Tina4::Database.new(url,
                            username: ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA"),
                            password: ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey"))
      end
    end

    def drop_table(db, engine, table = "ident_find_item")
      if engine == "firebird"
        db.execute("DROP TABLE #{table}") if db.table_exists?(table)
      elsif engine == "mssql"
        db.execute("IF OBJECT_ID('#{table}', 'U') IS NOT NULL DROP TABLE #{table}")
      else
        db.execute("DROP TABLE IF EXISTS #{table}")
      end
    rescue StandardError
      nil
    end

    %w[sqlite postgres mysql mssql firebird].each do |engine|
      context "on #{engine}" do
        it "orm_find_rejects_undeclared_filter_key" do
          db = engine_db(engine)
          begin
            Tina4.bind_database(db)
            drop_table(db, engine)
            db.execute("CREATE TABLE ident_find_item (id INTEGER NOT NULL PRIMARY KEY, name VARCHAR(50), " \
                       "owner_col VARCHAR(50), secret_note VARCHAR(50))")
            db.execute("INSERT INTO ident_find_item (id, name, owner_col, secret_note) VALUES (?, ?, ?, ?)",
                       [1, "alpha", "ann", "s1"])
            db.execute("INSERT INTO ident_find_item (id, name, owner_col, secret_note) VALUES (?, ?, ?, ?)",
                       [2, "bravo", "bob", "s2"])

            # Negative: an undeclared-but-real column, and non-identifier keys,
            # in every calling form - rejected with the contract message.
            [
              -> { IdentifierFindItem.find({ "secret_note" => "s1" }) },
              -> { IdentifierFindItem.find(secret_note: "s1") },
              -> { IdentifierFindItem.find(nil, { "secret_note" => "s1" }) }
            ].each do |call|
              expect(&call).to raise_error(
                ArgumentError, "Unknown filter field 'secret_note' for model IdentifierFindItem"
              )
            end
            ["na me", "name'", "name)"].each do |key|
              expect { IdentifierFindItem.find({ key => "alpha" }) }.to raise_error(
                ArgumentError, "Unknown filter field '#{key}' for model IdentifierFindItem"
              )
            end

            # Positive: a declared field, a mapped field by attribute AND by column.
            expect(IdentifierFindItem.find({ "name" => "alpha" }).map(&:id)).to eq([1])
            expect(IdentifierFindItem.find(name: "bravo").map(&:id)).to eq([2])
            expect(IdentifierFindItem.find({ "owner_name" => "ann" }).map(&:name)).to eq(["alpha"])
            expect(IdentifierFindItem.find({ "owner_col" => "bob" }).map(&:name)).to eq(["bravo"])
            expect(IdentifierFindItem.find({ "name" => "alpha", "owner_name" => "ann" }).map(&:id)).to eq([1])
            # The raw order_by argument stays a documented raw ORDER BY clause.
            expect(IdentifierFindItem.find({ "owner_col" => "ann" }, order_by: "id DESC").map(&:id)).to eq([1])
          ensure
            drop_table(db, engine)
            db.close
          end
        end

        it "db_write_helpers_reject_non_identifier_keys" do
          db = engine_db(engine)
          table = "ident_write_item"
          begin
            drop_table(db, engine, table)
            db.execute("CREATE TABLE #{table} (id INTEGER NOT NULL PRIMARY KEY, name VARCHAR(50), note VARCHAR(50))")
            db.insert(table, { "id" => 1, "name" => "alpha", "note" => "n1" })
            db.insert(table, { "id" => 2, "name" => "bravo", "note" => "n2" })
            snapshot = -> { db.fetch("SELECT id, name, note FROM #{table} ORDER BY id").records.map(&:values) }
            before = snapshot.call

            # Negative: a data or filter-map key that is not a plain identifier
            # is refused before any SQL, by every write helper and batch form.
            ["na me", "name'", "name]", "[name", "name)", "1name", "na-me", ""].each do |key|
              message = "Invalid column name '#{key}'"
              expect { db.insert(table, { "id" => 3, key => "x" }) }.to raise_error(ArgumentError, message)
              expect { db.insert(table, [{ "id" => 3, "name" => "c" }, { "id" => 4, key => "x" }]) }
                .to raise_error(ArgumentError, message)
              expect { db.insert(table, [{ "id" => 3, key => "x" }]) }.to raise_error(ArgumentError, message)
              expect { db.update(table, { key => "x" }, { "id" => 1 }) }.to raise_error(ArgumentError, message)
              expect { db.update(table, { "name" => "x" }, { key => 1 }) }.to raise_error(ArgumentError, message)
              expect { db.update(table, { "id" => 1, key => "x" }) }.to raise_error(ArgumentError, message)
              expect { db.delete(table, { key => 1 }) }.to raise_error(ArgumentError, message)
              expect { db.delete(table, [{ "id" => 2 }, { key => 1 }]) }.to raise_error(ArgumentError, message)
            end
            expect(snapshot.call).to eq(before), "a rejected write must not touch the table on #{engine}"

            # Positive: plain identifiers (String or Symbol keys, with _ and $)
            # still insert, update and delete through every form.
            db.insert(table, { id: 3, name: "charlie", note: "n3" })
            db.insert(table, [{ "id" => 4, "name" => "delta", "note" => "n4" }, { "id" => 5, "name" => "echo", "note" => "n5" }])
            db.update(table, { "note" => "changed" }, { "name" => "alpha" })
            db.update(table, { "id" => 2, "name" => "bravo2" })
            db.delete(table, { "id" => 4 })
            db.delete(table, [{ id: 5 }])
            rows = db.fetch("SELECT id, name, note FROM #{table} ORDER BY id").records
                     .map { |row| row.transform_keys { |k| k.to_s.downcase } }
            expect(rows.map { |row| [row["id"].to_i, row["name"], row["note"]] }).to eq(
              [[1, "alpha", "changed"], [2, "bravo2", "n2"], [3, "charlie", "n3"]]
            )
          ensure
            drop_table(db, engine, table)
            db.close
          end
        end
      end
    end
  end

  # ── C. DocStore field paths ───────────────────────────────────────────────
  describe "DocStore field paths" do
    def fallback_collection
      %w[TINA4_MONGO_URI TINA4_SESSION_MONGO_URI TINA4_SESSION_MONGO_URL].each { |k| ENV.delete(k) }
      ENV["TINA4_DOC_STORE_PATH"] = File.join(SpecTmpdir.create, "ident_ds.db")
      Tina4::DocStore.reset_default_store
      Tina4::DocStore.get_collection("ident_#{SecureRandom.hex(4)}")
    end

    def run_query(collection, filter, sort)
      cursor = collection.find(filter)
      cursor = cursor.sort(sort) if sort
      ids = cursor.to_a.map { |doc| doc["_id"].to_s }
      sort ? ids : ids.sort
    end

    after(:each) do
      %w[TINA4_MONGO_URI TINA4_MONGO_DB TINA4_DOC_STORE_PATH].each { |k| ENV.delete(k) }
      Tina4::DocStore.reset_default_store
    end

    it "docstore_rejects_unsafe_field_path" do
      collection = fallback_collection
      collection.insert_many(IDENT_ALLOW_SAFE_DOCS.map(&:dup))
      message = ->(key) { "DocStore: invalid field path '#{key}' - each dot-separated segment must match [A-Za-z0-9_-]+" }

      ["a b", "a'b", "a..b", ".a", "a.", "", "a[0]", "a\"b"].each do |key|
        # Top-level filter key.
        expect { collection.find({ key => 1 }) }.to raise_error(ArgumentError, message.call(key))
        # Nested inside $or / $and.
        expect { collection.find({ "$or" => [{ "a_b" => 1 }, { key => 1 }] }) }.to raise_error(ArgumentError, message.call(key))
        expect { collection.find({ "$and" => [{ key => { "$exists" => true } }] }) }.to raise_error(ArgumentError, message.call(key))
        # Operator field.
        expect { collection.find({ key => { "$gt" => 1 } }) }.to raise_error(ArgumentError, message.call(key))
        # Sort key - raised when the SQL would be built, before it runs.
        expect { collection.find({}).sort(key, 1).to_a }.to raise_error(ArgumentError, message.call(key))
        # Count / update / delete paths reject too, and nothing was touched.
        expect { collection.count_documents({ key => 1 }) }.to raise_error(ArgumentError, message.call(key))
        expect { collection.update_many({ key => 1 }, { "$set" => { "a_b" => 9 } }) }.to raise_error(ArgumentError, message.call(key))
        expect { collection.delete_many({ key => 1 }) }.to raise_error(ArgumentError, message.call(key))
      end
      expect(collection.count_documents({})).to eq(3)
      expect(collection.count_documents({ "a_b" => 9 })).to eq(0)
    end

    it "docstore_accepts_safe_field_paths" do
      collection = fallback_collection
      collection.insert_many(IDENT_ALLOW_SAFE_DOCS.map(&:dup))
      expected = {
        "a_b" => %w[doc1 doc3],
        "a-b" => %w[doc1 doc3],
        "A1" => %w[doc1 doc2],
        "nested.key" => %w[doc1 doc3],
        "_id" => %w[doc2],
        "$or" => %w[doc2 doc3],
        "sort a-b desc" => %w[doc1 doc3 doc2],
        "sort nested.key, A1" => %w[doc3 doc1 doc2],
        "sort _id" => %w[doc1 doc2 doc3]
      }
      IDENT_ALLOW_SAFE_QUERIES.each do |label, (filter, sort)|
        expect(run_query(collection, filter, sort)).to eq(expected.fetch(label)), "fallback query #{label}"
      end
    end

    it "docstore_safe_paths_match_on_real_mongo" do
      uri = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017")
      begin
        require "mongo"
        Mongo::Logger.logger.level = Logger::FATAL
        probe = Mongo::Client.new(uri, server_selection_timeout: 3)
        probe.database.command(ping: 1)
        probe.close
      rescue StandardError, LoadError => e
        skip("mongo not reachable at #{uri}: #{e.class}")
      end

      fallback = fallback_collection
      fallback.insert_many(IDENT_ALLOW_SAFE_DOCS.map(&:dup))

      db_name = "tina4_sqli_rb_#{Process.pid}_#{SecureRandom.hex(3)}"
      ENV["TINA4_MONGO_URI"] = uri
      ENV["TINA4_MONGO_DB"] = db_name
      begin
        mongo = Tina4::DocStore.get_collection("ident_parity")
        expect(mongo).not_to be_a(Tina4::DocStore::SqliteCollection)
        mongo.insert_many(IDENT_ALLOW_SAFE_DOCS.map { |doc| Marshal.load(Marshal.dump(doc)) })

        IDENT_ALLOW_SAFE_QUERIES.each do |label, (filter, sort)|
          expect(run_query(fallback, filter, sort)).to eq(run_query(mongo, filter, sort)), "fallback vs mongo for #{label}"
        end

        # A key the fallback rejects raises there, never silently returns nothing.
        expect { fallback.find({ "a b" => 1 }) }.to raise_error(ArgumentError)
      ensure
        Tina4::DocStore.mongo_client(uri, db_name).database.drop
        Tina4::DocStore.close_doc_store
      end
    end
  end

  # ── Tina4::Crud (Ruby-only HTML component + its SQL-mode write routes) ────
  describe "Tina4::Crud" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_ident_crud") }
    let(:db)      { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "crud.db")) }
    let(:client)  { Tina4::TestClient.new }

    before(:each) do
      Tina4.bind_database(db)
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      Tina4::Crud.instance_variable_set(:@registered_tables, {})
      # Row order differs by id, name, owner_col and secret_note, so the
      # rendered order shows which column the page was actually sorted by.
      db.execute("CREATE TABLE ident_crud_sort (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, " \
                 "owner_col TEXT, secret_note TEXT)")
      [[1, "alpha", "z", "b"], [2, "bravo", "x", "c"], [3, "charlie", "y", "a"]].each do |row|
        db.execute("INSERT INTO ident_crud_sort (id, name, owner_col, secret_note) VALUES (?, ?, ?, ?)", row)
      end
    end

    after(:each) do
      Tina4::Router.clear!
      Tina4::AutoCrud.clear!
      Tina4::Crud.instance_variable_set(:@registered_tables, {})
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    def crud_page(query, options)
      request = Tina4::Request.new(
        "REQUEST_METHOD" => "GET", "PATH_INFO" => "/admin/crud",
        "QUERY_STRING" => query, "CONTENT_TYPE" => "text/html"
      )
      Tina4::Crud.to_crud(request, options)
    end

    def row_order(html)
      %w[alpha bravo charlie].sort_by { |name| html.index(name) || raise("#{name} not rendered") }
    end

    it "crud_to_crud_sort_accepts_only_known_columns" do
      model = { model: IdentifierCrudSortItem }
      sql = { sql: "SELECT id, name, owner_col FROM ident_crud_sort", primary_key: "id" }
      by_pk = %w[alpha bravo charlie]

      # Negative: an undeclared-but-real column and non-identifier values fall
      # back to the primary-key order instead of reaching ORDER BY.
      ["secret_note", "na%20me", "name%27", "name%20DESC"].each do |sort|
        expect(row_order(crud_page("sort=#{sort}", model))).to eq(by_pk), "model mode sort=#{sort}"
        expect(row_order(crud_page("sort=#{sort}", sql))).to eq(by_pk), "sql mode sort=#{sort}"
        expect(row_order(crud_page("sort=#{sort}&search=a", sql))).to eq(by_pk), "sql mode + search sort=#{sort}"
      end

      # Positive: a declared field, a mapped field by attribute AND by column,
      # and a column of the SQL query's own result set; sort_dir stays asc/desc.
      expect(row_order(crud_page("sort=name&sort_dir=desc", model))).to eq(%w[charlie bravo alpha])
      expect(row_order(crud_page("sort=owner_name", model))).to eq(%w[bravo charlie alpha])
      expect(row_order(crud_page("sort=owner_col", model))).to eq(%w[bravo charlie alpha])
      expect(row_order(crud_page("sort=owner_col", sql))).to eq(%w[bravo charlie alpha])
      expect(row_order(crud_page("sort=name&sort_dir=desc&search=a", sql))).to eq(%w[charlie bravo alpha])
    end

    it "crud_sql_mode_writes_accept_only_table_columns" do
      db.execute("CREATE TABLE ident_crud_write (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, " \
                 "note TEXT, is_deleted INTEGER DEFAULT 0)")
      db.execute("INSERT INTO ident_crud_write (id, name, note) VALUES (?, ?, ?)", [1, "first", "n1"])
      prior_secret = ENV.delete("TINA4_SECRET")
      prior_api_key = ENV.delete("TINA4_API_KEY")
      Tina4::Auth.instance_variable_set(:@private_key, nil)
      Tina4::Auth.instance_variable_set(:@public_key, nil)
      Tina4::Auth.instance_variable_set(:@keys_dir, nil)
      Tina4::Auth.setup(tmp_dir)
      begin
        crud_page("", { sql: "SELECT id, name, note FROM ident_crud_write", primary_key: "id" })
        auth = { "Authorization" => "Bearer #{Tina4::Auth.get_token({ 'sub' => 'crud-writer' })}" }
        row = ->(id) { db.fetch_one("SELECT * FROM ident_crud_write WHERE id = ?", [id]) }

        # POST: unknown keys are dropped, is_deleted is never writable, a real
        # column matches case-insensitively and is written in its real spelling.
        created = client.post("/api/ident_crud_write", headers: auth, json: {
          "NAME" => "second", "note" => "n2", "is_deleted" => 1,
          "not_a_column" => "x", "na me" => "x", "note'" => "x"
        })
        expect(created.status).to eq(201), created.body
        expect(created.json["data"]).to eq("name" => "second", "note" => "n2")
        stored = db.fetch_one("SELECT * FROM ident_crud_write WHERE name = ?", ["second"])
        expect(stored[:note]).to eq("n2")
        expect(stored[:is_deleted].to_i).to eq(0)

        # PUT: the row is addressed by the URL id only (body pk stripped),
        # unknown keys dropped, is_deleted never writable.
        updated = client.put("/api/ident_crud_write/1", headers: auth, json: {
          "id" => 999, "name" => "renamed", "is_deleted" => 1, "not_a_column" => "x", "na me" => "x"
        })
        expect(updated.status).to eq(200), updated.body
        expect(updated.json["data"]).to eq("name" => "renamed")
        expect(row.call(1)[:name]).to eq("renamed")
        expect(row.call(1)[:is_deleted].to_i).to eq(0)
        expect(row.call(999)).to be_nil
      ensure
        ENV["TINA4_SECRET"] = prior_secret if prior_secret
        ENV["TINA4_API_KEY"] = prior_api_key if prior_api_key
      end
    end
  end
end
