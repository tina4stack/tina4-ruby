# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "tempfile"
require "socket"

# ORM field column read-back: an attribute whose DB column has another name
# round-trips on every read path.
#
# Parity with tina4-python tests/test_orm_field_column_readback.py. Python's bug
# was a `Field(column=)` that was written to its column but hydrated onto a
# stray attribute. Ruby has no per-field column option: `field_mapping`
# ({ "attribute" => "column" }) is the one resolver, read through
# get_db_column and reversed in from_hash. These cases pin that it round-trips
# on find(pk), all, where, find(filter), ORDER BY, count, load, update, delete,
# to_h, a mapped primary key, and a relationship foreign key.
#
# Real databases, no mocks: SQLite, PostgreSQL, MySQL, MSSQL and Firebird
# (Firebird folds unquoted identifiers to upper case).

# Model classes are TOP LEVEL on purpose (a bare constant inside RSpec.describe
# lands on Object and clobbers another spec file).
class ColRbPerson < Tina4::ORM
  table_name "colrr_person"
  self.field_mapping = { "name" => "full_name" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class ColRbMixed < Tina4::ORM
  table_name "colrr_mixed"
  self.field_mapping = { "name" => "full_name", "email" => "email_address" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :email
end

class ColRbPlain < Tina4::ORM
  table_name "colrr_plain"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class ColRbKeyed < Tina4::ORM
  table_name "colrr_keyed"
  self.field_mapping = { "id" => "person_id", "name" => "full_name" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class ColRbNamedKey < Tina4::ORM
  table_name "colrr_named_key"
  integer_field :person_id, primary_key: true, auto_increment: true
  string_field :name
end

class ColRbOwner < Tina4::ORM
  table_name "colrr_owner"
  self.field_mapping = { "name" => "owner_name" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  has_many :pets, class_name: "ColRbPet", foreign_key: "owner_id"
  has_one :pet, class_name: "ColRbPet", foreign_key: "owner_id"
end

class ColRbPet < Tina4::ORM
  table_name "colrr_pet"
  self.field_mapping = { "id" => "pet_id", "name" => "pet_name", "owner_id" => "owner_ref" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  integer_field :owner_id
  belongs_to :owner, class_name: "ColRbOwner", foreign_key: "owner_id"
end

class ColRbKeyedChild < Tina4::ORM
  table_name "colrr_keyed_child"
  integer_field :id, primary_key: true, auto_increment: true
  foreign_key_field :keyed_id, references: ColRbKeyed, related_name: :children
  string_field :label
end

# belongs_to with the foreign key spelled as the COLUMN.
class ColRbPetByColumn < Tina4::ORM
  table_name "colrr_pet"
  self.field_mapping = { "id" => "pet_id", "name" => "pet_name", "owner_id" => "owner_ref" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  integer_field :owner_id
  belongs_to :owner, class_name: "ColRbOwner", foreign_key: "owner_ref"
end

# The same relationship with the foreign key spelled as the COLUMN.
class ColRbOwnerByColumn < Tina4::ORM
  table_name "colrr_owner"
  self.field_mapping = { "name" => "owner_name" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  has_many :pets, class_name: "ColRbPet", foreign_key: "owner_ref"
end

COLRB_TABLES = {
  "colrr_person" => ["id", "full_name VARCHAR(100)"],
  "colrr_mixed" => ["id", "full_name VARCHAR(100), email_address VARCHAR(100)"],
  "colrr_plain" => ["id", "name VARCHAR(100)"],
  "colrr_keyed" => ["person_id", "full_name VARCHAR(100)"],
  "colrr_named_key" => ["person_id", "name VARCHAR(100)"],
  "colrr_owner" => ["id", "owner_name VARCHAR(100)"],
  "colrr_pet" => ["pet_id", "pet_name VARCHAR(100), owner_ref INTEGER"],
  "colrr_keyed_child" => ["id", "keyed_id INTEGER, label VARCHAR(255)"]
}.freeze

COLRB_ENGINES = %w[sqlite postgres mysql mssql firebird].freeze

RSpec.describe "ORM field column read-back" do
  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 3) { true }
  rescue StandardError
    false
  end

  def open_engine(engine)
    case engine
    when "sqlite"
      Tina4::Database.new("sqlite:///#{Tempfile.new(['colrb', '.db']).path}")
    when "firebird"
      url = ENV["TINA4_TEST_FIREBIRD_URL"]
      skip "[needs:firebird] firebird not set: TINA4_TEST_FIREBIRD_URL (needs a live Firebird)" if url.nil? || url.empty?
      Tina4::Database.new(url, username: "SYSDBA", password: "masterkey")
    else
      prefix, port, database, user, password = {
        "postgres" => ["PG", "55432", "tina4_rb", "tina4", "tina4"],
        "mysql" => ["MYSQL", "3306", "tina4_test", "tina4", "tina4"],
        "mssql" => ["MSSQL", "1433", "tina4_test", "sa", "TinaSQL123!Secure"]
      }.fetch(engine)
      host = ENV.fetch("TINA4_TEST_#{prefix}_HOST", "127.0.0.1")
      port = ENV.fetch("TINA4_TEST_#{prefix}_PORT", port).to_i
      skip "[needs:#{engine}] #{engine} unreachable at #{host}:#{port} (set TINA4_TEST_#{prefix}_*)" unless reachable?(host, port)
      Tina4::Database.new("#{engine}://#{host}:#{port}/#{ENV.fetch("TINA4_TEST_#{prefix}_DB", database)}",
                          username: ENV.fetch("TINA4_TEST_#{prefix}_USERNAME", user),
                          password: ENV.fetch("TINA4_TEST_#{prefix}_PASSWORD", password))
    end
  end

  def key_column(engine, key)
    {
      "sqlite" => "#{key} INTEGER PRIMARY KEY AUTOINCREMENT",
      "postgres" => "#{key} SERIAL PRIMARY KEY",
      "mysql" => "#{key} INT AUTO_INCREMENT PRIMARY KEY",
      "mssql" => "#{key} INT IDENTITY(1,1) PRIMARY KEY",
      "firebird" => "#{key} INTEGER NOT NULL PRIMARY KEY"
    }.fetch(engine)
  end

  def drop_tables(db, engine)
    COLRB_TABLES.each_key do |table|
      statements = ["DROP TABLE #{table}"]
      statements = ["DROP TRIGGER #{table}_bi", *statements, "DROP GENERATOR gen_#{table}_id"] if engine == "firebird"
      statements.each do |statement|
        db.execute(statement)
      rescue StandardError
        nil
      end
    end
  end

  def use_engine(engine, *tables)
    @engine = engine
    @db = open_engine(engine)
    Tina4.bind_database(@db)
    [ColRbPerson, ColRbMixed, ColRbPlain, ColRbKeyed, ColRbNamedKey, ColRbOwner, ColRbPet,
     ColRbOwnerByColumn, ColRbKeyedChild, ColRbPetByColumn].each { |model| model.db = @db }
    drop_tables(@db, engine)
    tables.each do |table|
      key, columns = COLRB_TABLES.fetch(table)
      @db.execute("CREATE TABLE #{table} (#{key_column(engine, key)}, #{columns})")
      next unless engine == "firebird"

      # Firebird's auto-key idiom: a GEN_<TABLE>_ID generator fed by a BEFORE
      # INSERT trigger -- the generator the driver reads the new key back from.
      @db.execute("CREATE GENERATOR gen_#{table}_id")
      @db.execute("CREATE TRIGGER #{table}_bi FOR #{table} ACTIVE BEFORE INSERT POSITION 0 " \
                  "AS BEGIN IF (NEW.#{key} IS NULL) THEN NEW.#{key} = GEN_ID(gen_#{table}_id, 1); END")
    end
  end

  after do
    if @db
      drop_tables(@db, @engine)
      begin
        @db.close
      rescue StandardError
        nil
      end
      @db = nil
    end
  end

  # Raw row with lower-cased string keys: asserts WHERE a value landed, not the
  # driver's key casing.
  def raw_row(sql, params = [])
    row = @db.fetch_one(sql, params)
    expect(row).not_to be_nil, "no row for: #{sql}"
    row.to_h.transform_keys { |key| key.to_s.downcase }
  end

  def expect_no_stray_column_attribute(model, column)
    expect(model.to_h.keys.map(&:to_s)).not_to include(column),
      "hydration left a stray '#{column}' key: the DB column must map back onto its attribute"
    expect(model.respond_to?(column)).to be(false)
  end

  COLRB_ENGINES.each do |engine|
    context "on #{engine}" do
      it "field column write lands in the declared column" do
        use_engine(engine, "colrr_person")
        expect(ColRbPerson.create(name: "Ada")).to be_truthy
        expect(raw_row("SELECT full_name FROM colrr_person")["full_name"]).to eq("Ada")
      end

      it "field column reads back through find by primary key" do
        use_engine(engine, "colrr_person")
        saved = ColRbPerson.create(name: "Ada")
        found = ColRbPerson.find(saved.id)
        expect(found).not_to be_nil
        expect(found.name).to eq("Ada")
        expect_no_stray_column_attribute(found, "full_name")
      end

      it "field column reads back through all" do
        use_engine(engine, "colrr_person")
        ColRbPerson.create(name: "Ada")
        ColRbPerson.create(name: "Grace")
        people = ColRbPerson.all
        expect(people.map(&:name).sort).to eq(%w[Ada Grace])
        people.each { |person| expect_no_stray_column_attribute(person, "full_name") }
      end

      it "field column reads back through where" do
        use_engine(engine, "colrr_person")
        ColRbPerson.create(name: "Ada")
        ColRbPerson.create(name: "Grace")
        rows = ColRbPerson.where("full_name = ?", ["Grace"])
        expect(rows.map(&:name)).to eq(["Grace"])
        expect_no_stray_column_attribute(rows.first, "full_name")
      end

      it "field column filters through find by attribute name" do
        use_engine(engine, "colrr_person")
        ColRbPerson.create(name: "Ada")
        ColRbPerson.create(name: "Grace")
        expect(ColRbPerson.find(name: "Ada").map(&:name)).to eq(["Ada"])
        expect(ColRbPerson.find({ "name" => "Grace" }).map(&:name)).to eq(["Grace"])
      end

      it "field column sorts and reads back in order" do
        use_engine(engine, "colrr_person")
        %w[Grace Ada Linus].each { |name| ColRbPerson.create(name: name) }
        # order_by is SQL (SQL-first ORM), so it names the column; every row it
        # returns must still hydrate onto the attribute, in the database's order.
        expect(ColRbPerson.all(order_by: "full_name DESC").map(&:name)).to eq(%w[Linus Grace Ada])
        expect(ColRbPerson.where("1=1", [], order_by: "full_name ASC").map(&:name)).to eq(%w[Ada Grace Linus])
      end

      it "field column counts and loads" do
        use_engine(engine, "colrr_person")
        saved = ColRbPerson.create(name: "Ada")
        expect(ColRbPerson.count("full_name = ?", ["Ada"])).to eq(1)
        fresh = ColRbPerson.new
        fresh.id = saved.id
        expect(fresh.load).to be true
        expect(fresh.name).to eq("Ada")
      end

      it "field column updates the declared column" do
        use_engine(engine, "colrr_person")
        person = ColRbPerson.create(name: "Ada")
        person.name = "Ada Lovelace"
        expect(person.save).to be_truthy
        expect(raw_row("SELECT full_name FROM colrr_person")["full_name"]).to eq("Ada Lovelace")
        expect(ColRbPerson.find(person.id).name).to eq("Ada Lovelace")
      end

      it "field column to_h uses the attribute name" do
        use_engine(engine, "colrr_person")
        saved = ColRbPerson.create(name: "Ada")
        expect(ColRbPerson.find(saved.id).to_h).to eq({ id: saved.id, name: "Ada" })
      end

      it "get_db_column resolves field column" do
        expect(ColRbPerson.get_db_column(:name)).to eq(:full_name)
        expect(ColRbMixed.get_db_column(:email)).to eq(:email_address)
        expect(ColRbPlain.get_db_column(:name)).to eq(:name)
      end

      it "field mapping and field column round trip together" do
        use_engine(engine, "colrr_mixed")
        saved = ColRbMixed.create(name: "Ada", email: "ada@example.com")
        expect(raw_row("SELECT full_name, email_address FROM colrr_mixed"))
          .to eq({ "full_name" => "Ada", "email_address" => "ada@example.com" })
        found = ColRbMixed.find(saved.id)
        expect([found.name, found.email]).to eq(["Ada", "ada@example.com"])
        expect_no_stray_column_attribute(found, "full_name")
        expect_no_stray_column_attribute(found, "email_address")
        expect(ColRbMixed.find(name: "Ada").map(&:id)).to eq([saved.id])
        expect(ColRbMixed.find(email: "ada@example.com").map(&:id)).to eq([saved.id])
        expect(ColRbMixed.all.map(&:name)).to eq(["Ada"])
      end

      it "plain field round trips unchanged" do
        use_engine(engine, "colrr_plain")
        saved = ColRbPlain.create(name: "Ada")
        expect(raw_row("SELECT name FROM colrr_plain")["name"]).to eq("Ada")
        expect(ColRbPlain.find(saved.id).name).to eq("Ada")
        expect(ColRbPlain.find(name: "Ada").map(&:name)).to eq(["Ada"])
        expect(ColRbPlain.all.map(&:name)).to eq(["Ada"])
      end

      it "undeclared select column is ignored by hydration, declared ones still map" do
        use_engine(engine, "colrr_person")
        ColRbPerson.create(name: "Ada")
        person = ColRbPerson.select("SELECT id, full_name, 7 AS extra_value FROM colrr_person").first
        expect(person.name).to eq("Ada")
        expect(person.respond_to?(:extra_value)).to be(false)
      end

      it "foreign key field column loads lazy and eager" do
        use_engine(engine, "colrr_owner", "colrr_pet")
        owner = ColRbOwner.create(name: "Ada")
        ColRbPet.create(name: "Rex", owner_id: owner.id)
        ColRbPet.create(name: "Tom", owner_id: owner.id)
        expect(raw_row("SELECT owner_ref FROM colrr_pet WHERE pet_name = ?", ["Rex"])["owner_ref"]).to eq(owner.id)

        expect(ColRbOwner.find(owner.id).pets.map(&:name).sort).to eq(%w[Rex Tom])
        expect(%w[Rex Tom]).to include(ColRbOwner.find(owner.id).pet.name)
        expect(ColRbOwner.all(include: ["pets"]).first.pets.map(&:name).sort).to eq(%w[Rex Tom])
        # foreign_key may also be spelled as the COLUMN; it resolves to the same attribute.
        expect(ColRbOwnerByColumn.find(owner.id).pets.map(&:name).sort).to eq(%w[Rex Tom])
        expect(ColRbOwnerByColumn.all(include: ["pets"]).first.pets.map(&:name).sort).to eq(%w[Rex Tom])

        pet = ColRbPet.find(name: "Rex").first
        expect(pet.owner_id).to eq(owner.id)
        expect(pet.owner.name).to eq("Ada")
        expect(ColRbPet.all(include: ["owner"]).first.owner.name).to eq("Ada")
        expect(ColRbPetByColumn.find(name: "Rex").first.owner.name).to eq("Ada")
        eager_pet = ColRbPetByColumn.all(include: ["owner"]).first
        # include: must fill the cache itself (not fall back to a lazy query).
        expect(eager_pet.instance_variable_get(:@relationship_cache)).to have_key(:owner)
        expect(eager_pet.owner.name).to eq("Ada")
      end

      it "primary key field column round trips" do
        use_engine(engine, "colrr_keyed")
        first = ColRbKeyed.create(name: "Ada")
        second = ColRbKeyed.create(name: "Grace")
        expect(first.id).not_to be_nil
        expect(second.id).not_to be_nil
        expect(first.id).not_to eq(second.id)
        expect(raw_row("SELECT person_id, full_name FROM colrr_keyed WHERE person_id = ?", [first.id]))
          .to eq({ "person_id" => first.id, "full_name" => "Ada" })
        found = ColRbKeyed.find(first.id)
        expect([found.id, found.name]).to eq([first.id, "Ada"])
        expect_no_stray_column_attribute(found, "person_id")

        found.name = "Ada Lovelace"
        expect(found.save).to be_truthy
        expect(ColRbKeyed.find(first.id).name).to eq("Ada Lovelace")
        expect(ColRbKeyed.find(second.id).name).to eq("Grace"), "an update must address only its own row"

        expect(ColRbKeyed.find(second.id).delete).to be true
        expect(ColRbKeyed.find(second.id)).to be_nil
        expect(ColRbKeyed.all.map(&:name)).to eq(["Ada Lovelace"])
      end

      it "seeder draws foreign keys from a mapped parent key" do
        use_engine(engine, "colrr_keyed", "colrr_keyed_child")
        parent_ids = [ColRbKeyed.create(name: "Ada").id, ColRbKeyed.create(name: "Grace").id]
        summary = Tina4.seed_orm(ColRbKeyedChild, count: 6, seed: 7, strict: true)
        expect(summary.to_i).to eq(6)
        children = ColRbKeyedChild.all
        expect(children.length).to eq(6)
        expect(children.map(&:keyed_id).uniq - parent_ids).to be_empty,
          "the seeder must draw foreign keys from the parent's real key column"
        # belongs_to a parent whose key column is mapped: lazy and eager.
        expect(%w[Ada Grace]).to include(children.first.keyed.name)
        expect(ColRbKeyedChild.all(include: ["keyed"]).map { |child| child.keyed.name }.uniq - %w[Ada Grace]).to be_empty
      end

      it "non id auto increment key is set after save" do
        use_engine(engine, "colrr_named_key")
        first = ColRbNamedKey.create(name: "Ada")
        second = ColRbNamedKey.create(name: "Grace")
        expect(first.person_id).not_to be_nil
        expect(second.person_id).not_to be_nil
        expect(first.person_id).not_to eq(second.person_id)
        expect(ColRbNamedKey.find(second.person_id).name).to eq("Grace")
      end
    end
  end
end

RSpec.describe "PostgreSQL last_id for a key not named id" do
  it "never reports a stale sequence value" do
    host = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
    port = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
    reachable = begin
      Socket.tcp(host, port, connect_timeout: 3) { true }
    rescue StandardError
      false
    end
    skip "[needs:postgres] postgres unreachable at #{host}:#{port} (set TINA4_TEST_PG_*)" unless reachable
    db = Tina4::Database.new("postgres://#{host}:#{port}/#{ENV.fetch('TINA4_TEST_PG_DB', 'tina4_rb')}",
                             username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                             password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
    tables = %w[colrr_named_key colrr_natural]
    tables.each { |table| db.execute("DROP TABLE IF EXISTS #{table}") }
    db.execute("CREATE TABLE colrr_named_key (person_id SERIAL PRIMARY KEY, name VARCHAR(100))")
    db.execute("CREATE TABLE colrr_natural (code VARCHAR(10) PRIMARY KEY, name VARCHAR(100))")
    expect(db.insert("colrr_named_key", { name: "Ada" }).last_id).to eq(1)
    natural = db.insert("colrr_natural", { code: "A1", name: "Grace" })
    expect(natural.last_id).to be_nil, "stale sequence value leaked: #{natural.last_id.inspect}"
  ensure
    tables&.each do |table|
      db&.execute("DROP TABLE IF EXISTS #{table}")
    rescue StandardError
      nil
    end
    db&.close
  end
end
