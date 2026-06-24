# frozen_string_literal: true

require "spec_helper"

# Regression: the sqlite3 gem RAISES ("can't prepare TrueClass") on a raw Ruby
# boolean parameter. The SQLite driver now coerces true/false to 1/0 (and
# Time/DateTime to ISO-8601) at the bind boundary, so a boolean field round-trips
# against a REAL SQLite database. No mocks — a live in-memory SQLite connection.
# Parity with the Python/PHP/Node adapters, which coerce at the same boundary.
RSpec.describe "SQLite boolean coercion (real DB)" do
  let(:db) { Tina4::Database.new("sqlite://:memory:") }

  after(:each) { db.close rescue nil }

  it "binds a raw boolean as 0/1 instead of raising" do
    db.execute("CREATE TABLE flags (id INTEGER PRIMARY KEY, flag INTEGER, name TEXT)")
    expect { db.execute("INSERT INTO flags (flag, name) VALUES (?, ?)", [true, "on"]) }.not_to raise_error
    expect { db.execute("INSERT INTO flags (flag, name) VALUES (?, ?)", [false, "off"]) }.not_to raise_error
    rows = db.fetch("SELECT flag FROM flags ORDER BY id").records
    expect(rows.map { |r| r[:flag] }).to eq([1, 0])
  end

  it "seeds a boolean column into a real SQLite DB (coerced to 0/1)" do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, active INTEGER)")
    # seed_table feeds the generated values straight through the driver's bind
    # boundary; a boolean value would raise without the coercion.
    summary = Tina4.seed_table("widgets", {
      "name" => -> { "w" },
      "active" => -> { [true, false].sample },
    }, count: 4)
    expect(summary.to_i).to eq(4)
    stored = db.fetch("SELECT active FROM widgets").records
    expect(stored.map { |r| r[:active] }).to all(satisfy { |v| v == 0 || v == 1 })
  end
end
