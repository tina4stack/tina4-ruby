# frozen_string_literal: true

require "tmpdir"
require "tina4"

# The ORM layer must honour a COMPOSITE primary key (feature 4, open item).
#
# Feature 4 fixed the raw write path: update/delete put EVERY primary-key column
# in the WHERE, because keying on one column of a composite key matches every
# row sharing that value. The ORM layer ABOVE it was never fixed, so the
# data-loss shape lived one level up. Three defects, all from the resolver
# returning a single column:
#
#   1. SAVING A NEW ROW OVERWROTE AN EXISTING ONE. The INSERT-vs-UPDATE decision
#      asked exists(pk_value) with only ONE key column, which is true for ANY
#      row sharing it, so a genuinely new row was decided to be an UPDATE.
#      Saving (acme, a2) rewrote (acme, a1). The worst of the three: it destroys
#      data on an ordinary insert, with no error.
#   2. UPDATE and DELETE keyed on one column, hitting every row sharing it.
#   3. create_table emitted an inline PRIMARY KEY on EACH key column, which is
#      invalid DDL - SQLite, PostgreSQL and MySQL all reject two of them.
#
# Real SQLite, no mocks: the DDL defect only shows against an engine that
# actually parses the statement.
RSpec.describe "ORM composite primary key" do
  # Locals, not constants: a constant here leaks into every other spec file.
  let(:dir) { Dir.mktmpdir("tina4-ck") }
  let(:db) { Tina4::Database.new("sqlite://#{File.join(dir, 'composite.db')}") }

  before do
    Tina4.bind_database(db)

    stub_membership = Class.new(Tina4::ORM) do
      table_name "membership"
      string_field :tenant, primary_key: true
      string_field :code, primary_key: true
      string_field :label
      integer_field :seats
    end
    Object.const_set(:CkMembership, stub_membership) unless Object.const_defined?(:CkMembership)

    stub_widget = Class.new(Tina4::ORM) do
      table_name "widget"
      integer_field :id, primary_key: true, auto_increment: true
      string_field :name
    end
    Object.const_set(:CkWidget, stub_widget) unless Object.const_defined?(:CkWidget)
  end

  after do
    begin
      db.close
    rescue StandardError
      nil
    end
    FileUtils.remove_entry(dir) if File.directory?(dir)
  end

  it "reports every primary-key column" do
    expect(CkMembership.primary_key_fields).to eq(%i[tenant code])
  end

  it "emits ONE table-level primary-key clause" do
    # Two inline PRIMARY KEY clauses is invalid DDL on every engine.
    CkMembership.create_table
    ddl = db.fetch_one(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='membership'"
    )[:sql].upcase
    expect(ddl.scan("PRIMARY KEY").length).to eq(1), ddl
    clause = ddl.split("PRIMARY KEY", 2)[1]
    expect(clause).to include("TENANT")
    expect(clause).to include("CODE")
  end

  it "INSERTS a second row that shares its first key column" do
    # The worst defect: this used to be decided as an UPDATE and overwrite a1.
    CkMembership.create_table
    CkMembership.new(tenant: "acme", code: "a1", label: "first", seats: 1).save
    CkMembership.new(tenant: "acme", code: "a2", label: "second", seats: 2).save

    rows = db.fetch("SELECT * FROM membership ORDER BY code", [], limit: 100).records
    expect(rows.length).to eq(2), "a new row overwrote an existing one"
  end

  it "updates only the row matching the WHOLE key" do
    CkMembership.create_table
    CkMembership.new(tenant: "acme", code: "a1", label: "first", seats: 1).save
    CkMembership.new(tenant: "acme", code: "a2", label: "second", seats: 2).save

    CkMembership.new(tenant: "acme", code: "a1", label: "CHANGED", seats: 99).save

    rows = db.fetch("SELECT * FROM membership ORDER BY code", [], limit: 100).records
    by_code = rows.each_with_object({}) { |r, acc| acc[r["code"] || r[:code]] = r }
    expect(by_code["a1"]["label"] || by_code["a1"][:label]).to eq("CHANGED")
    expect(by_code["a2"]["label"] || by_code["a2"][:label]).to eq("second"),
                                                             "saving a1 rewrote a2 - the key is truncated"
  end

  it "negative: deletes only the row matching the WHOLE key" do
    CkMembership.create_table
    CkMembership.new(tenant: "acme", code: "a1", label: "first", seats: 1).save
    CkMembership.new(tenant: "acme", code: "a2", label: "second", seats: 2).save

    CkMembership.new(tenant: "acme", code: "a1").delete

    rows = db.fetch("SELECT code FROM membership", [], limit: 100).records
    codes = rows.map { |r| r["code"] || r[:code] }
    expect(codes).to eq(%w[a2]), "delete removed more than the addressed row"
  end

  it "negative: a single-key model is unaffected" do
    expect(CkWidget.primary_key_fields).to eq([:id])
    CkWidget.create_table
    ddl = db.fetch_one(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='widget'"
    )[:sql].upcase
    expect(ddl.scan("PRIMARY KEY").length).to eq(1)
    # A single-key model keeps the INLINE form, not a table-level clause.
    expect(ddl).not_to include("PRIMARY KEY (")

    w = CkWidget.new(name: "one")
    expect(w.save).to be_truthy
    expect(CkWidget.find(w.id)).not_to be_nil
  end

  it "negative: a model with no declared key falls back to id" do
    loose = Class.new(Tina4::ORM) do
      table_name "loose"
      string_field :name
    end
    expect(loose.primary_key_fields).to eq([:id])
  end
end
