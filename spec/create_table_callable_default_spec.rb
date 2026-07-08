# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# Regression for issue #61: create_table must OMIT callable field defaults from the DDL.
#
# A callable default (e.g. datetime_field :created_at, default: -> { Time.now }) was
# rendered into the CREATE TABLE DDL as `DEFAULT #<Proc:...>` via default_literal's
# to_s branch -- invalid SQL that silently failed table creation, so a later save/all
# hit "no such table". Callable defaults are resolved per-row at instance creation
# (parity with the Python master); they must not reach the DDL.
#
# NOT a mock: real SQLite Database, real create_table DDL, real save/all round-trip.
class NoteCd61 < Tina4::ORM
  table_name "note_cd61"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title, default: "untitled"              # static -> stays in DDL
  datetime_field :created_at, default: -> { Time.now }  # callable -> omitted
end

RSpec.describe "create_table callable default (#61)" do
  before(:each) do
    @tmp = Tempfile.new(["tina4_cd61", ".db"])
    Tina4.bind_database(Tina4::Database.new("sqlite://#{@tmp.path}"))
  end

  after(:each) do
    @tmp.close!
  end

  it "creates the table (callable default omitted) and round-trips a row" do
    # Before #61 this raised/returned false: DDL had `DEFAULT #<Proc:...>`.
    expect(NoteCd61.create_table).to be true

    note = NoteCd61.new(title: "hello")
    expect(note.save).not_to be false

    rows = NoteCd61.all
    expect(rows.length).to eq(1)
    expect(rows.first.title).to eq("hello")
    expect(rows.first.created_at).not_to be_nil # callable resolved at insert
  end
end
