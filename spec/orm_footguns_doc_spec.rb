# frozen_string_literal: true
#
# Doc-lock boot-gate for the footguns documented in
#   .claude/skills/tina4-developer-ruby/references/data-and-orm.md   (ORM Lifecycle & Footguns)
#   .claude/skills/tina4-developer-ruby/references/auth-and-services.md (Auth footguns)
#
# Each example pins a behaviour the skill now promises, with POSITIVE and
# NEGATIVE cases. If a documented footgun regresses (or the framework drifts
# from the doc), the matching example goes red. Real SQLite files, the real
# router, the real Frond engine — NO mocks, NO stubs (parity with the Python
# master's tests/test_orm_footguns_doc.py).

require "spec_helper"
require_relative "support/real_log_capture"

# ── Models (unique table names so nothing collides with sibling specs) ──

class FDocUser < Tina4::ORM
  table_name "fdoc_users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name, nullable: false   # required
  string_field  :email
end

class FDocGhost < Tina4::ORM
  # table intentionally never created → save hits "no such table"
  table_name "fdoc_ghost_missing"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :label
end

class FDocSoft < Tina4::ORM
  self.soft_delete = true
  table_name "fdoc_soft"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title
  integer_field :is_deleted, default: 0
end

class FDocNomad < Tina4::ORM
  # points at a NAMED connection that is never registered
  self.db = :fdoc_never_registered
  table_name "fdoc_nomad"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
end

RSpec.describe "ORM & auth footguns (doc lock-in)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_footguns_doc") }
  let(:db_path) { File.join(tmp_dir, "footguns.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE fdoc_users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT)")
    db.commit
  end

  # Keep the console quiet WITHOUT a double. The previous
  # `allow(Tina4::Log).to receive(:error).and_call_original` installed a mock
  # proxy on the real logger for EVERY example in this file. This instead points
  # the REAL logger at a real temp file for the example's duration: the real
  # formatter, level filter and file sink all still run, and nothing is
  # substituted.
  around(:each) do |example|
    with_real_log_dir { example.run }
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  # ── save fails SOFT (false), never raises ──────────────────────────────

  describe "save fails soft" do
    it "returns self on success and clears the error" do
      user = FDocUser.new(name: "Alice", email: "a@x.com")
      expect(user.save).to be(user)
      expect(user.get_error).to be_nil
    end

    it "returns false (never raises) on a validation failure, with a recoverable cause" do
      bad = FDocUser.new(email: "no-name@x.com")   # name is required
      expect { @result = bad.save }.not_to raise_error
      expect(@result).to be false
      expect(bad.get_error.to_s.downcase).to include("required")
    end
  end

  # ── No auto table-create: save into a missing table → false + actionable hint ──

  describe "no auto table-create (missing-table save hint)" do
    it "returns false and the cause names create_table / a migration" do
      ghost = FDocGhost.new(label: "x")
      expect(ghost.save).to be false
      expect(ghost.get_error).to match(/does not exist; call FDocGhost\.create_table or run a migration/)
    end

    it "succeeds once the table is created (create_table then save)" do
      expect(FDocGhost.create_table).to be true
      created = FDocGhost.new(label: "x")
      expect(created.save).to be(created)
    end
  end

  # ── soft_delete requires a declared is_deleted column → save hint ──

  describe "soft_delete missing-is_deleted save hint" do
    it "returns false and names the missing is_deleted column when the table lacks it" do
      db.execute("CREATE TABLE fdoc_soft (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)")  # NO is_deleted
      db.commit
      row = FDocSoft.new(title: "hi")
      expect(row.save).to be false
      expect(row.get_error).to match(/soft_delete is on but the 'is_deleted' column is missing/)
    end

    it "succeeds when is_deleted exists (create_table declares it)" do
      expect(FDocSoft.create_table).to be true
      row = FDocSoft.new(title: "hi")
      expect(row.save).to be(row)
    end
  end

  # ── Ruby's constructor does NOT validate (DIFFERS from Python) ──

  describe "constructor does not validate (Ruby-specific)" do
    it "does not raise on a missing/bad field value — failure surfaces at save" do
      expect { FDocUser.new(name: nil) }.not_to raise_error
      expect { FDocUser.new("email" => "only@x.com") }.not_to raise_error   # String-keyed Hash from a body
    end

    it "raises ArgumentError on an Array positional arg (a model is one record)" do
      expect { FDocUser.new([{ "name" => "x" }]) }.to raise_error(ArgumentError)
    end

    it "raises on a non-JSON String positional arg" do
      expect { FDocUser.new("not-json") }.to raise_error(JSON::ParserError)
    end
  end

  # ── delete / restore fail LOUD (raise) — the asymmetry ──

  describe "delete / restore raise (loud)" do
    it "delete raises on a nil primary key (unsaved instance)" do
      expect { FDocUser.new(name: "ephemeral").delete }.to raise_error(/no primary key value/)
    end

    it "restore raises on a model without soft_delete" do
      expect { FDocUser.new(name: "x").restore }.to raise_error(/does not support soft delete/)
    end

    it "delete returns true and removes the row when the PK is set" do
      u = FDocUser.new(name: "Doomed"); u.save
      expect(u.delete).to be true
      expect(FDocUser.find_by_id(u.id)).to be_nil
    end
  end

  # ── db.execute raises (does NOT return false) ──

  describe "db.execute raises on error, returns true on a successful write" do
    it "raises on a driver error" do
      expect { db.execute("INSERT INTO nope_table (x) VALUES (1)") }.to raise_error(StandardError)
    end

    it "returns true on a successful non-SELECT write" do
      expect(db.execute("INSERT INTO fdoc_users (name) VALUES (?)", ["Zed"])).to be true
    end
  end

  # ── DB-bound precondition: an unregistered named connection raises clearly ──

  describe "database-bound precondition" do
    it "a model on an unregistered named connection raises a clear 'not registered' error" do
      expect { FDocNomad.all }.to raise_error(/not registered/i)
    end
  end

  # ── Route param types: a fixed set; an unknown/typo type raises at registration ──

  describe "route param types" do
    it "raises ArgumentError on an unknown param type (typo)" do
      expect { Tina4::Router.get("/fdoc/{id:inetger}") { |_req, res| res } }
        .to raise_error(ArgumentError, /Unknown param type/)
    end

    it "accepts a known param type" do
      expect { Tina4::Router.get("/fdoc/{id:int}") { |_req, res| res } }.not_to raise_error
    end
  end

  # ── Frond: ~ concatenates; + is arithmetic (coerces to numbers); live validates ──

  describe "Frond template gotchas" do
    let(:engine) { Tina4::Frond.new }

    it "~ concatenates strings" do
      expect(engine.render_string('{{ "hi " ~ name }}', { "name" => "Bob" })).to include("hi Bob")
    end

    it "+ is arithmetic — it coerces strings to numbers, it does NOT concatenate" do
      out = engine.render_string('{{ "hi " + name }}', { "name" => "Bob" })
      expect(out).not_to include("hi Bob")
      expect(out.strip).to eq("0")
    end

    it "a live block with a missing poll interval raises" do
      expect { engine.render_string('{% live "x" poll %}y{% endlive %}', {}) }.to raise_error(RuntimeError)
    end
  end
end
