# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "socket"

# Feature 21 - Declarative ORM relationships: the shared conformance contract,
# parity with tina4-python/tests/test_relationships_contract.py.
#
# REL-DEC-01 (read-side-only cascade) + REL-DEC-02 (soft-delete filter on
# traversal, bounded eager IN + explicit lazy paging). NO MOCKS: real SQLite AND
# real PostgreSQL (:55432, tina4/tina4). Row presence/absence is asserted by
# querying the real table; "one query per relation" is proven with a REAL
# executed-statement counter that instruments the real db.fetch (observation,
# not a mock). Under TINA4_REQUIRE_SERVICES a postgres skip is a hard failure.

# Model classes are TOP LEVEL on purpose (a bare constant inside RSpec.describe
# lands on Object and clobbers another spec file). Parent BEFORE child so the
# FK auto-wire wires has_many on the already-loaded parent.
class RelAuthorRb < Tina4::ORM
  table_name "rel_author"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class RelPostRb < Tina4::ORM
  table_name "rel_post"
  self.soft_delete = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  integer_field :is_deleted, default: 0
  # Read-side-only FK auto-wire: RelPost.author (belongs_to) + RelAuthor.posts (has_many)
  foreign_key_field :author_id, references: RelAuthorRb, related_name: :posts
end

REL_ENGINES = %w[sqlite postgres].freeze

RSpec.describe "Declarative ORM relationships (feature 21)" do
  def reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 3) { true }
  rescue StandardError
    false
  end

  def engine_db(engine)
    if engine == "postgres"
      h = ENV.fetch("TINA4_TEST_PG_HOST", "127.0.0.1")
      p = ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
      skip "postgres unreachable at #{h}:#{p} (set TINA4_TEST_PG_*)" unless reachable?(h, p)
      db = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")
      Tina4::Database.new("postgres://#{h}:#{p}/#{db}",
                          username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                          password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
    else
      Tina4::Database.new("sqlite:///#{Tempfile.new(["rel", ".db"]).path}")
    end
  end

  def fresh(db)
    Tina4.bind_database(db)
    %w[rel_post rel_author].each do |t|
      begin
        db.execute("DROP TABLE IF EXISTS #{t}")
      rescue StandardError
        nil
      end
    end
    RelAuthorRb.create_table
    RelPostRb.create_table
  end

  def raw_count(db, table, where, params)
    row = db.fetch_one("SELECT COUNT(*) AS c FROM #{table} WHERE #{where}", params)
    (row["c"] || row["C"] || row[:c]).to_i
  end

  # Count fetches touching `table` while the block runs. Every counted call still
  # runs the REAL query via the captured original -- instrumentation, not a mock.
  def count_child_fetches(db, table)
    n = { c: 0 }
    orig = db.method(:fetch)
    db.define_singleton_method(:fetch) do |sql, params = [], **kw|
      n[:c] += 1 if sql.include?(table)
      orig.call(sql, params, **kw)
    end
    yield
    n[:c]
  ensure
    begin
      db.singleton_class.send(:remove_method, :fetch)
    rescue StandardError
      nil
    end
  end

  # ── REL-EAGER: exactly ONE query per relation (no N+1) ─────────────────────
  it "eager_include_runs_one_query_per_relation" do
    db = engine_db("sqlite")
    fresh(db)
    begin
      3.times do |a|
        author = RelAuthorRb.new(name: "a#{a}").save
        2.times { |p| RelPostRb.new(title: "a#{a}-p#{p}", author_id: author.id).save }
      end

      total = 0
      count = count_child_fetches(db, "rel_post") do
        authors = RelAuthorRb.all(include: ["posts"])
        total = authors.sum { |author| author.posts.length }
      end

      expect(total).to eq(6)
      # ONE query for the relation across all 3 authors -- not one per author.
      expect(count).to eq(1)
    ensure
      db.close
    end
  end

  REL_ENGINES.each do |engine|
    context "on #{engine}" do
      # ── REL-SOFTDELETE: a soft-deleted child is excluded from traversal ────
      it "soft_deleted_child_excluded_from_lazy_traversal" do
        db = engine_db(engine)
        fresh(db)
        begin
          author = RelAuthorRb.new(name: "a").save
          RelPostRb.new(title: "keep", author_id: author.id).save
          gone = RelPostRb.new(title: "gone", author_id: author.id).save
          gone.delete # soft delete -> is_deleted = 1

          expect(raw_count(db, "rel_post", "1=1", [])).to eq(2)
          fresh_author = RelAuthorRb.find(author.id)
          expect(fresh_author.posts.map(&:title)).to eq(["keep"])
        ensure
          db.close
        end
      end

      it "soft_deleted_child_excluded_from_eager_traversal" do
        db = engine_db(engine)
        fresh(db)
        begin
          author = RelAuthorRb.new(name: "a").save
          RelPostRb.new(title: "keep", author_id: author.id).save
          gone = RelPostRb.new(title: "gone", author_id: author.id).save
          gone.delete

          loaded = RelAuthorRb.all(include: ["posts"])
          expect(loaded.length).to eq(1)
          expect(loaded.first.posts.map(&:title)).to eq(["keep"])
        ensure
          db.close
        end
      end

      # ── REL-DEC-02: lazy attribute access returns the related rows ─────────
      it "lazy_attribute_access_returns_related_rows" do
        db = engine_db(engine)
        fresh(db)
        begin
          author = RelAuthorRb.new(name: "a").save
          RelPostRb.new(title: "p0", author_id: author.id).save
          RelPostRb.new(title: "p1", author_id: author.id).save

          fresh_author = RelAuthorRb.find(author.id)
          expect(fresh_author.posts.map(&:title).sort).to eq(%w[p0 p1])

          post = RelPostRb.where("title = ?", ["p0"]).first
          expect(post.author).not_to be_nil
          expect(post.author.name).to eq("a")
        ensure
          db.close
        end
      end

      # ── REL-DEC-01: read-side-only -- deleting a parent leaves children ────
      it "deleting_a_parent_leaves_children_in_the_db" do
        db = engine_db(engine)
        fresh(db)
        begin
          author = RelAuthorRb.new(name: "a").save
          RelPostRb.new(title: "p0", author_id: author.id).save
          RelPostRb.new(title: "p1", author_id: author.id).save

          author.force_delete # hard delete the parent

          # No DB-level ON DELETE cascade: the children rows survive.
          expect(raw_count(db, "rel_author", "id = ?", [author.id])).to eq(0)
          expect(raw_count(db, "rel_post", "author_id = ?", [author.id])).to eq(2)
        ensure
          db.close
        end
      end
    end
  end

  # ── REL-EAGER-UNBOUNDED: > one page of children is fully reachable ─────────
  it "large_child_set_is_fully_reachable_not_truncated" do
    # SQLite only: proves the PAGING loop returns the tail (was a silent 100-row
    # cap via the default fetch limit). The paging is engine-independent.
    db = engine_db("sqlite")
    fresh(db)
    begin
      author = RelAuthorRb.new(name: "a").save
      rows = Array.new(1001) { |i| { "title" => "p#{i}", "author_id" => author.id, "is_deleted" => 0 } }
      db.insert("rel_post", rows)

      fresh_author = RelAuthorRb.find(author.id)
      expect(fresh_author.posts.length).to eq(1001)
    ensure
      db.close
    end
  end
end
