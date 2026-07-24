# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Lock-in for the row-hydration contract of the SQLite read path (issue #355).
#
# execute_query hydrates every result row into a SYMBOL-keyed Hash. The mapping
# is now computed once per query rather than per cell, so these tests pin the
# OUTPUT SHAPE so that optimisation (or any future one, e.g. switching to
# array rows) cannot quietly change what callers receive. Real SQLite, no doubles.
RSpec.describe "SQLite read hydration contract" do
  around do |example|
    @dir = Dir.mktmpdir("tina4_hydration")
    @db = Tina4::Database.new("sqlite://#{@dir}/h.db")
    @db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
    @db.execute("INSERT INTO users VALUES (1, 'Alice', 'a@x')")
    @db.execute("INSERT INTO users VALUES (2, NULL, 'b@x')")
    @db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)")
    @db.execute("INSERT INTO posts VALUES (10, 1, 'Hi')")
    @db.commit
    example.run
  ensure
    @db&.close
    FileUtils.remove_entry(@dir, true) if @dir
  end

  it "returns rows as symbol-keyed Hashes (not string-keyed, not arrays)" do
    row = @db.fetch_one("SELECT * FROM users WHERE id = 1")
    expect(row).to eq({ id: 1, name: "Alice", email: "a@x" })
    expect(row.keys).to all(be_a(Symbol))
    # Guards against a future "read arrays for speed" change forgetting to
    # rebuild the hash: an Array or a string-keyed Hash must fail here.
    expect(row).to be_a(Hash)
    expect(row.key?("id")).to be(false)
  end

  it "drops any positional Integer keys the gem may emit" do
    row = @db.fetch_one("SELECT * FROM users WHERE id = 1")
    expect(row.keys.any? { |k| k.is_a?(Integer) }).to be(false)
  end

  it "preserves NULL as nil under a symbol key" do
    row = @db.fetch_one("SELECT * FROM users WHERE id = 2")
    expect(row).to eq({ id: 2, name: nil, email: "b@x" })
  end

  it "hydrates aliased JOIN columns by their alias, once per distinct column" do
    row = @db.fetch_one(
      "SELECT u.id AS uid, p.id AS pid, u.name, p.title " \
      "FROM users u JOIN posts p ON p.user_id = u.id"
    )
    expect(row).to eq({ uid: 1, pid: 10, name: "Alice", title: "Hi" })
  end

  it "hydrates every row of a multi-row set with identical symbol keys" do
    rows = @db.fetch("SELECT * FROM users ORDER BY id", [], limit: 1000).records
    expect(rows.length).to eq(2)
    expect(rows.map(&:keys)).to all(eq(%i[id name email]))
    expect(rows.first).to eq({ id: 1, name: "Alice", email: "a@x" })
  end

  it "returns an empty record set (not nil, not [nil]) for a no-match query" do
    result = @db.fetch("SELECT * FROM users WHERE id = 999", [], limit: 1000)
    expect(result.records).to eq([])
  end
end
