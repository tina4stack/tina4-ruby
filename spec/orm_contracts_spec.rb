# frozen_string_literal: true
#
# Lock-in regression tests for the v3.13.39 ORM "fail loud, never silent" pass.
#
# These contracts guard against silent-drift in the ORM/QueryBuilder failure
# paths. The principle (the same db.execute already follows by raising): a
# failure must never vanish silently — it returns the documented self/false or
# raises loudly AND the real cause stays recoverable. If any of these behaviours
# regresses to the old silent form, one of these named tests goes red.
#
# Mirrors tests/test_orm_contracts.py from the Python master, PLUS a test per
# Ruby-specific outlier bug fixed in the same pass (A–E). Engine-agnostic
# (sqlite is fine). Log output is verified by spying on Tina4::Log.error
# (level-independent — spec_helper silences the console log) rather than reading
# stdout, which is the Ruby-idiomatic equivalent of Python's capsys assertion.

require "spec_helper"

# ── Test Models ─────────────────────────────────────────────────

class CUser < Tina4::ORM
  table_name "cusers"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false # NOT NULL at the DB and required in the model
  string_field :email
end

class CWidget < Tina4::ORM
  table_name "cwidgets"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
end

class CGhost < Tina4::ORM
  # Points at a table that is never created — every save hits a driver error
  # ("no such table"), exercising create's failure propagation through the
  # DB-error path (construction + validation both succeed).
  table_name "cghost_missing"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :label
end

class CCoin < Tina4::ORM
  # Natural (non-auto-increment) string primary key — exercises the
  # INSERT-vs-UPDATE-by-existence decision (bug B).
  table_name "ccoins"
  string_field :code, primary_key: true
  string_field :label
end

RSpec.describe "ORM fail-loud contracts (v3.13.39)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_orm_contracts") }
  let(:db_path) { File.join(tmp_dir, "orm_contracts.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE cusers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT)")
    db.execute("CREATE TABLE cwidgets (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)")
    db.execute("CREATE TABLE ccoins (code TEXT PRIMARY KEY, label TEXT)")
    db.commit
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  # ── 1. save on a DB constraint violation: false + retrievable cause + logged ──

  describe "save loud on DB error" do
    it "success returns self (fluent) and clears any previous error" do
      u = CUser.new(name: "Alice")
      expect(u.save).to be(u)        # fluent self on success (Ruby was the outlier returning true — bug A)
      expect(u.get_error).to be_nil   # cleared on success
      expect(u.last_error).to be_nil
    end

    it "a DB error is loud (false) and the real cause is recoverable + logged + rolled back" do
      # CGhost points at a non-existent table, so the INSERT raises inside the
      # transaction. Construction and validation both pass, so this isolates the
      # DB-error path from the validation path.
      ghost = CGhost.new(label: "x")

      expect(Tina4::Log).to receive(:error)
        .with(/CGhost\.save failed for table 'cghost_missing'/)
        .and_call_original

      result = ghost.save

      expect(result).to be false                 # loud: documented false (not a raise, not self)
      expect(ghost.get_error).to be_truthy        # cause recoverable
      expect(ghost.last_error).to be_truthy        # same cause on the attribute
      expect(ghost.get_error).to eq(ghost.last_error)
      expect(ghost.errors).not_to be_empty         # also on the legacy errors array
    end
  end

  # ── 2. save with validation errors: false, no row written, validate ran ──

  describe "save enforces validation" do
    it "a validation failure returns false, logs, records the cause, and writes nothing" do
      before = CUser.count
      invalid = CUser.new(name: "temp")
      invalid.name = nil # now violates nullable: false

      # Sanity: validate itself reports the error.
      expect(invalid.validate).not_to be_empty

      expect(Tina4::Log).to receive(:error)
        .with(/CUser\.save refused: validation failed/)
        .and_call_original

      result = invalid.save

      expect(result).to be false
      expect(invalid.get_error).to be_truthy       # cause recoverable
      expect(invalid.get_error.downcase).to include("null")
      expect(CUser.count).to eq(before)            # the write never happened
    end
  end

  # ── 3. create returns false when the underlying save fails ──

  describe "create propagates save failure" do
    it "returns false when the underlying save fails (driver error)" do
      # CGhost's save always hits a driver error and returns false.
      allow(Tina4::Log).to receive(:error)
      expect(CGhost.create(label: "x")).to be false
    end

    it "returns false when the underlying save fails (validation error)" do
      allow(Tina4::Log).to receive(:error)
      expect(CUser.create(email: "no-name@example.com")).to be false # name is required
    end

    it "returns the saved instance on success (happy path unchanged)" do
      user = CUser.create(name: "Valid")
      expect(user).to be_a(CUser)
      expect(user.id).not_to be_nil
      expect(CUser.count).to eq(1)
    end
  end

  # ── 4. QueryBuilder.get with no .limit() returns ALL rows (>100) ──

  describe "QueryBuilder#get has no silent default LIMIT" do
    it "returns all rows when there is no .limit() (insert 150, get all 150)" do
      150.times { |i| db.insert("cwidgets", { label: "w#{i}" }) }
      db.commit

      result = Tina4::QueryBuilder.from_table("cwidgets", db: db).get
      expect(result.records.length).to eq(150) # not a silently-truncated 100
    end

    it "still honours an explicit .limit(n)" do
      150.times { |i| db.insert("cwidgets", { label: "w#{i}" }) }
      db.commit

      result = Tina4::QueryBuilder.from_table("cwidgets", db: db).limit(10).get
      expect(result.records.length).to eq(10)
    end

    it "to_sql never injects a default LIMIT" do
      sql = Tina4::QueryBuilder.from_table("cwidgets", db: db).to_sql.upcase
      expect(sql).not_to include("LIMIT")
    end
  end

  # ── 5. to_mongo raises (no silent $where) on an unparseable WHERE ──

  describe "QueryBuilder#to_mongo has no silent $where fallback" do
    it "raises on an unparseable WHERE clause, naming the clause" do
      qb = Tina4::QueryBuilder.from_table("cwidgets", db: db)
             .where("label = label OR 1=1")
      # The raise itself proves no silent { "$where" => <raw JS> } hash was
      # returned — to_mongo never gets the chance to emit one.
      expect { qb.to_mongo }.to raise_error(ArgumentError, /label = label OR 1=1/)
    end

    it "still translates supported forms" do
      mongo = Tina4::QueryBuilder.from_table("cwidgets", db: db)
                .where("label = ?", ["x"])
                .to_mongo
      expect(mongo[:filter]).to eq({ "label" => "x" })
    end
  end

  # ── Ruby-specific outlier bugs (A–E) ─────────────────────────────

  describe "outlier bug A: save returns self/false (not a bare boolean)" do
    it "returns the instance itself on success, false on failure" do
      ok = CUser.new(name: "Bob")
      expect(ok.save).to be_a(CUser)
      expect(ok.save).to be(ok)

      allow(Tina4::Log).to receive(:error)
      bad = CUser.new(email: "x@y.z") # no name → validation fails
      expect(bad.save).to be false
    end
  end

  describe "outlier bug B: natural-key save decides INSERT vs UPDATE by row existence" do
    it "re-saving a fresh instance with an existing PK UPDATEs (never double-inserts)" do
      first = CCoin.new(code: "GC-1", label: "one")
      expect(first.save).to be(first)
      expect(CCoin.count).to eq(1)

      # A BRAND-NEW instance (so @persisted is false) carrying the same PK must
      # still UPDATE — pre-fix this double-inserted (or no-op'd) because the
      # decision was @persisted-only.
      again = CCoin.new(code: "GC-1", label: "one-updated")
      expect(again.instance_variable_get(:@persisted)).to be(false)
      expect(again.save).to be(again)

      expect(CCoin.count).to eq(1)                       # no duplicate row
      expect(CCoin.find_by_id("GC-1").label).to eq("one-updated")
    end

    it "first save of an unseen natural key INSERTs" do
      coin = CCoin.new(code: "GC-2", label: "two")
      expect(coin.save).to be(coin)
      expect(CCoin.find_by_id("GC-2").label).to eq("two")
    end
  end

  describe "outlier bug C: Model.exists(pk) finder" do
    it "is a class method that reports row existence" do
      expect(CUser).to respond_to(:exists)
      expect(CUser.exists(999)).to be false
      u = CUser.create(name: "Present")
      expect(CUser.exists(u.id)).to be true
    end
  end

  describe "outlier bug D: delete raises on a missing PK (matches force_delete)" do
    it "raises when the primary key value is nil, just like force_delete" do
      no_pk = CUser.new(name: "ephemeral") # never saved → id is nil
      expect { no_pk.delete }.to raise_error(/no primary key value/)
      expect { no_pk.force_delete }.to raise_error(/no primary key value/)
    end

    it "returns true and removes the row when the PK is set" do
      u = CUser.create(name: "Doomed")
      expect(u.delete).to be true
      expect(CUser.find_by_id(u.id)).to be_nil
    end
  end

  describe "outlier bug E: FK / has_many name derivation (declaring class lowercased + s)" do
    it "auto-wires the has_many accessor as <declaringClass.downcase> + 's'" do
      author_cls = Class.new(Tina4::ORM) do
        def self.name = "EAuthor"
        table_name "eauthors"
        integer_field :id, primary_key: true, auto_increment: true
        string_field :name
      end
      Object.const_set(:EAuthor, author_cls) unless Object.const_defined?(:EAuthor)

      post_cls = Class.new(Tina4::ORM) do
        def self.name = "EPost"
        table_name "eposts"
        integer_field :id, primary_key: true, auto_increment: true
        string_field :title
        foreign_key_field :eauthor_id, references: EAuthor
      end
      Object.const_set(:EPost, post_cls) unless Object.const_defined?(:EPost)

      # has_many name on the referenced model = declaring class lowercased + "s"
      expect(EAuthor.relationship_definitions).to have_key(:eposts)
      expect(EAuthor.relationship_definitions[:eposts][:class_name]).to eq("EPost")
      # belongs_to name on the declaring model = column minus _id
      expect(EPost.relationship_definitions).to have_key(:eauthor)
    ensure
      Object.send(:remove_const, :EPost) if Object.const_defined?(:EPost)
      Object.send(:remove_const, :EAuthor) if Object.const_defined?(:EAuthor)
    end

    it "singularizes a hand-written has_many class name (no naive sub(/s$/))" do
      # 'categories' must derive 'Category', not the naive 'Categorie'.
      cat_cls = Class.new(Tina4::ORM) do
        def self.name = "ECategory"
        has_many :categories
        has_many :products
      end
      expect(cat_cls.relationship_definitions[:categories][:class_name]).to eq("Category")
      expect(cat_cls.relationship_definitions[:products][:class_name]).to eq("Product")
    end
  end
end
