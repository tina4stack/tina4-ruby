# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "socket"

# Feature 22 - Imperative ORM relationships: the shared conformance contract,
# parity with tina4-python/tests/test_imperative_relationships_contract.py.
#
# IMPREL-DEC-01 (OWNER-DECISIONS.md Batch 4): imperative relationships are a
# PER-LANGUAGE IDIOM. Ruby has NO separate instance-level builder -- its
# imperative form is the DECLARATIVE class method (has_one/has_many/belongs_to)
# invoked at RUNTIME. So this runner exercises exactly that: the class methods
# called at runtime, then read through the generated accessors. No new API is
# forced onto Ruby (the ledger's call).
#
# NO MOCKS: real SQLite AND real PostgreSQL (:55432, tina4/tina4). Positive AND
# negative throughout. Under TINA4_REQUIRE_SERVICES a postgres skip is a hard
# failure.

# Model classes are TOP LEVEL on purpose (a bare constant inside RSpec.describe
# lands on Object and clobbers another spec file). Parent BEFORE child so the FK
# auto-wire wires has_many :posts on the already-loaded parent.
class ImpRelAuthorRb < Tina4::ORM
  table_name "imp_rel_author"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

class ImpRelPostRb < Tina4::ORM
  table_name "imp_rel_post"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  # FK auto-wire: ImpRelPost.author (belongs_to) + ImpRelAuthor.posts (has_many)
  foreign_key_field :author_id, references: ImpRelAuthorRb, related_name: :posts
end

IMPREL_ENGINES = %w[sqlite postgres].freeze

RSpec.describe "Imperative ORM relationships (feature 22)" do
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
      Tina4::Database.new("sqlite:///#{Tempfile.new(["imprel", ".db"]).path}")
    end
  end

  def fresh(db)
    Tina4.bind_database(db)
    %w[imp_rel_post imp_rel_author].each do |t|
      begin
        db.execute("DROP TABLE IF EXISTS #{t}")
      rescue StandardError
        nil
      end
    end
    ImpRelAuthorRb.create_table
    ImpRelPostRb.create_table
  end

  IMPREL_ENGINES.each do |engine|
    context "on #{engine}" do
      # ── IMPREL-DEC-02: an imperatively-loaded relation SERIALIZES ──────────
      it "imperative_relation_serializes" do
        db = engine_db(engine)
        fresh(db)
        begin
          author = ImpRelAuthorRb.new(name: "a").save
          3.times { |i| ImpRelPostRb.new(title: "p#{i}", author_id: author.id).save }

          # Ruby imperative form: has_many invoked at RUNTIME, read via accessor.
          ImpRelAuthorRb.has_many(:ser_posts, class_name: "ImpRelPostRb", foreign_key: "author_id")
          fresh_author = ImpRelAuthorRb.find(author.id)
          expect(fresh_author.ser_posts.length).to eq(3)

          d = fresh_author.to_h(include: ["ser_posts"])
          expect(d[:ser_posts].length).to eq(3)
          expect(d[:ser_posts].map { |p| p[:title] }.sort).to eq(%w[p0 p1 p2])

          # Negative: WITHOUT include the relation is not serialized.
          expect(fresh_author.to_h).not_to have_key(:ser_posts)
        ensure
          db.close
        end
      end

      # ── IMPREL-DEC-01: the imperative surface behaves the same (per-language) ─
      it "imperative_surface_behaves_same_all_four" do
        db = engine_db(engine)
        fresh(db)
        begin
          author = ImpRelAuthorRb.new(name: "a").save
          ImpRelPostRb.new(title: "p0", author_id: author.id).save
          ImpRelPostRb.new(title: "p1", author_id: author.id).save

          # Ruby imperative form: has_one/has_many/belongs_to invoked at RUNTIME.
          ImpRelAuthorRb.has_one(:one_post, class_name: "ImpRelPostRb", foreign_key: "author_id")
          ImpRelAuthorRb.has_many(:many_posts, class_name: "ImpRelPostRb", foreign_key: "author_id")
          ImpRelPostRb.belongs_to(:owner, class_name: "ImpRelAuthorRb", foreign_key: "author_id")

          fresh_author = ImpRelAuthorRb.find(author.id)
          expect(fresh_author.one_post).not_to be_nil
          expect(%w[p0 p1]).to include(fresh_author.one_post.title)
          expect(fresh_author.many_posts.map(&:title).sort).to eq(%w[p0 p1])

          child = ImpRelPostRb.where("title = ?", ["p0"]).first
          expect(child.owner).not_to be_nil
          expect(child.owner.name).to eq("a")

          # Negative: belongs_to whose FK resolves to no parent returns nil
          # (read-side-only: no DB FK constraint, so a dangling FK inserts fine).
          orphan = ImpRelPostRb.new(title: "orphan", author_id: 999_999).save
          expect(orphan.owner).to be_nil
        ensure
          db.close
        end
      end
    end
  end

  # ── IMPREL-PY-CAP parity: the runtime-invoked class method returns the whole
  #    set, same count as the eager path -- > the old cap of 100. SQLite only. ──
  it "imperative_and_lazy_same_row_count" do
    db = engine_db("sqlite")
    fresh(db)
    begin
      author = ImpRelAuthorRb.new(name: "a").save
      rows = Array.new(150) { |i| { "title" => "p#{i}", "author_id" => author.id } }
      db.insert("imp_rel_post", rows)

      # Ruby imperative form: has_many invoked at RUNTIME.
      ImpRelAuthorRb.has_many(:runtime_posts, class_name: "ImpRelPostRb", foreign_key: "author_id")
      fresh_author = ImpRelAuthorRb.find(author.id)

      imperative = fresh_author.runtime_posts                         # runtime-invoked accessor
      eager = ImpRelAuthorRb.all(include: ["posts"]).first.posts      # eager path (FK auto-wired)

      expect(imperative.length).to eq(150)
      expect(eager.length).to eq(150)
      expect(imperative.length).to eq(eager.length)
    ensure
      db.close
    end
  end
end
