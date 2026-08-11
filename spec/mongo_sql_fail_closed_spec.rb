# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# MongoDB SQL provider - fail-closed WHERE + mass-delete data-loss guard (feature 14).
#
# Shared contract: plan/v3/fixtures/mongosql_contract.json (MONGO-DEC-01). This is
# the Ruby half; Python/PHP/Node carry the same case names against the same real
# MongoDB.
#
# WHY THIS FILE EXISTS
#   The MongoDB SQL provider translates a SQL WHERE into a Mongo filter with a
#   hand-rolled regex parser. Before MONGO-DEC-01 an UNPARSEABLE / UNSUPPORTED
#   WHERE silently degraded to an EMPTY filter, so a DELETE/UPDATE then reached
#   delete_many({}) / update_many({}) and matched EVERY document - a silent mass
#   wipe - and NO functional test in any framework exercised the parse/CRUD path.
#
#   The guard is fail-closed: an unparseable WHERE RAISES (never match-all), and a
#   DELETE/UPDATE with NO WHERE clause is REFUSED (truncate() is the explicit
#   whole-collection spelling). This proves it against a REAL MongoDB.
#
# NO MOCKS. A real MongoDB over a real socket. The framework performs the writes
# (the code under test); an independent raw Mongo::Client witnesses the resulting
# document state. After the guard fires, the collection count is UNCHANGED.
# Mutation-proved: disable the guard and the unparseable delete wipes the
# collection, turning "count unchanged" red.
RSpec.describe "MongoDB SQL fail-closed guard" do
  MONGOSQL_URI = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017")
  MONGOSQL_DB = "tina4_mongosql_rb"

  def self.mongo_reachable?
    return @mongo_reachable unless @mongo_reachable.nil?

    @mongo_reachable = begin
      require "mongo"
      Mongo::Logger.logger.level = Logger::FATAL
      client = Mongo::Client.new(MONGOSQL_URI, server_selection_timeout: 3)
      client.database.command(ping: 1)
      client.close
      true
    rescue StandardError, LoadError
      false
    end
  end

  def uri_with_db
    scheme, rest = MONGOSQL_URI.split("://", 2)
    query = rest.include?("?") ? "?#{rest.split('?', 2)[1]}" : ""
    host = rest.split("?", 2)[0].split("/", 2)[0]
    "#{scheme}://#{host}/#{MONGOSQL_DB}#{query}"
  end

  before do
    skip "no reachable MongoDB at #{MONGOSQL_URI} (set TINA4_TEST_MONGO_URI)" unless self.class.mongo_reachable?

    @db = Tina4::Database.new(uri_with_db)
    @collection = "widgets_#{SecureRandom.hex(6)}"
    # Independent witness: a raw driver client, not the code under test.
    @witness = Mongo::Client.new(MONGOSQL_URI, server_selection_timeout: 3).use(MONGOSQL_DB)
  end

  after do
    if @db
      begin
        @db.execute("DROP TABLE #{@collection}")
      rescue StandardError
        # best effort
      end
      @db.close
    end
    @witness&.close
  end

  def seed(rows)
    rows.each do |row|
      @db.execute(
        "INSERT INTO #{@collection} (id, status) VALUES (?, ?)",
        [row[:id], row[:status]]
      )
    end
  end

  def count
    @witness[@collection].count_documents({})
  end

  def statuses
    @witness[@collection].find.map { |doc| doc["status"] }.sort
  end

  # -- Guard 1: an unparseable / unsupported WHERE fails closed --------------

  it "an unparseable where delete raises and deletes nothing" do
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "keep" },
           { id: 3, status: "gone" }
         ])
    expect(count).to eq(3)

    # UPPER(status) is a function on the column - unsupported by the regex
    # parser. Before the fix it degraded to {} and delete_many({}) wiped all 3.
    expect do
      @db.execute("DELETE FROM #{@collection} WHERE UPPER(status) = 'GONE'")
    end.to raise_error(StandardError)

    # The witness: nothing was deleted.
    expect(count).to eq(3)
  end

  it "a partially unparseable where delete raises and deletes nothing" do
    # A COMPOUND WHERE where one AND-part is valid and one is unsupported. If the
    # parser silently DROPPED the unsupported part it would leave { id: 1 } - a
    # NON-empty but WRONG filter that the empty-filter guard waves through - and
    # delete id=1 regardless of its status. Only the fail-closed parse catches
    # this: the whole statement must raise, deleting nothing.
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "gone" }
         ])

    expect do
      @db.execute("DELETE FROM #{@collection} WHERE id = 1 AND UPPER(status) = 'GONE'")
    end.to raise_error(StandardError)

    # Neither document was touched.
    expect(count).to eq(2)
    expect(statuses).to eq(%w[gone keep])
  end

  it "an unparseable where update raises and changes nothing" do
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "keep" }
         ])

    expect do
      @db.execute("UPDATE #{@collection} SET status = 'wiped' WHERE UPPER(status) = 'KEEP'")
    end.to raise_error(StandardError)

    expect(statuses).to eq(%w[keep keep])
  end

  # -- Guard 2: a DELETE/UPDATE with NO WHERE is refused ---------------------

  it "a no where delete is rejected and deletes nothing" do
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "keep" },
           { id: 3, status: "keep" }
         ])
    expect(count).to eq(3)

    expect do
      @db.execute("DELETE FROM #{@collection}")
    end.to raise_error(StandardError)

    # A filterless delete must never empty the collection.
    expect(count).to eq(3)
  end

  it "a no where update is rejected and changes nothing" do
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "keep" }
         ])

    expect do
      @db.execute("UPDATE #{@collection} SET status = 'wiped'")
    end.to raise_error(StandardError)

    expect(statuses).to eq(%w[keep keep])
  end

  # -- Positive: a real WHERE scopes the write to only matching docs ---------

  it "a valid where delete removes only matching docs" do
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "gone" },
           { id: 3, status: "keep" },
           { id: 4, status: "gone" }
         ])
    expect(count).to eq(4)

    @db.execute("DELETE FROM #{@collection} WHERE status = ?", ["gone"])

    # Exactly the two matches are gone; the two "keep" rows remain.
    expect(count).to eq(2)
    expect(statuses).to eq(%w[keep keep])
  end

  it "a valid where update changes only matching docs" do
    seed([
           { id: 1, status: "keep" },
           { id: 2, status: "keep" },
           { id: 3, status: "keep" }
         ])

    @db.execute("UPDATE #{@collection} SET status = ? WHERE id = ?", ["changed", 2])

    # Only id=2 changed.
    expect(statuses).to eq(%w[changed keep keep])
  end
end
