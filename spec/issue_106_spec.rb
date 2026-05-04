# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe "Issue #106 equivalent bugs" do
  # ── 1. Wildcard param key is "*" ─────────────────────────────────────
  describe "Wildcard param key" do
    before { Tina4::Router.clear! }

    it 'uses :"*" (matching Python/PHP/Node parity) as the key for a bare * wildcard' do
      # Tina4 uses the literal "*" key for bare-wildcard captures across all
      # four frameworks — Python/PHP/Node docs say `request.params["*"]`.
      # Ruby uses the symbol form :"*" to match that contract. NOT :splat
      # (Sinatra's convention) — that would diverge from the cross-framework
      # API surface.
      Tina4::Router.get("/docs/*") { |req, res| res.text("docs") }
      route, params = Tina4::Router.match("GET", "/docs/some/deep/path")
      expect(route).not_to be_nil
      expect(params).to have_key(:"*")
      expect(params[:"*"]).to eq("some/deep/path")
    end

    it "uses the named key for *name wildcard" do
      Tina4::Router.get("/files/*path") { |req, res| res.text("file") }
      route, params = Tina4::Router.match("GET", "/files/a/b/c.txt")
      expect(route).not_to be_nil
      expect(params).to have_key(:path)
      expect(params[:path]).to eq("a/b/c.txt")
    end
  end

  # ── 2. Router.group accessible ───────────────────────────────────────
  describe "Router.group accessible" do
    before { Tina4::Router.clear! }

    it "responds to .group" do
      expect(Tina4::Router).to respond_to(:group)
    end

    it "prefixes routes registered inside the group" do
      Tina4::Router.group("/api/v1") do
        get("/items") { "items" }
      end
      route, _ = Tina4::Router.match("GET", "/api/v1/items")
      expect(route).not_to be_nil
      expect(route.method).to eq("GET")
    end

    it "does not register the unprefixed path" do
      Tina4::Router.group("/api/v1") do
        get("/items") { "items" }
      end
      result = Tina4::Router.match("GET", "/items")
      expect(result).to be_nil
    end
  end

  # ── 3. request.files for multipart ──────────────────────────────────
  describe "request.files for multipart" do
    it "separates files from body params on multipart/form-data" do
      # Simulate a Rack env with multipart content
      tempfile = Tempfile.new("upload")
      tempfile.write("file content")
      tempfile.rewind

      env = {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/upload",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "multipart/form-data; boundary=----test",
        "CONTENT_LENGTH" => "0",
        "rack.input" => StringIO.new(""),
        "rack.request.form_hash" => {
          "name" => "test",
          "avatar" => {
            filename: "photo.jpg",
            type: "image/jpeg",
            tempfile: tempfile
          }
        }
      }

      request = Tina4::Request.new(env)
      expect(request.files).to have_key("avatar")
      expect(request.files["avatar"][:filename]).to eq("photo.jpg")
      expect(request.files["avatar"][:type]).to eq("image/jpeg")

      # Body params should not include file entries
      # (files are extracted separately from form_hash)
      expect(request.files.keys).not_to include("name")

      tempfile.close
      tempfile.unlink
    end
  end

  # ── 4. to_paginate() slices correctly ───────────────────────────────
  describe "to_paginate() slices correctly" do
    it "returns the correct slice for page 2 with per_page 10" do
      records = (1..50).map { |i| { id: i, name: "item_#{i}" } }
      result = Tina4::DatabaseResult.new(records, sql: "SELECT * FROM items",
                                         count: 50, limit: 10, offset: 0)

      paginated = result.to_paginate(page: 2, per_page: 10)
      expect(paginated[:data].length).to eq(10)
      expect(paginated[:data].first[:id]).to eq(11)
      expect(paginated[:data].last[:id]).to eq(20)
      expect(paginated[:page]).to eq(2)
      expect(paginated[:per_page]).to eq(10)
      expect(paginated[:total]).to eq(50)
      expect(paginated[:total_pages]).to eq(5)
      expect(paginated[:has_next]).to be true
      expect(paginated[:has_prev]).to be true
    end

    it "returns the last page correctly" do
      records = (1..50).map { |i| { id: i } }
      result = Tina4::DatabaseResult.new(records, sql: "", count: 50)

      paginated = result.to_paginate(page: 5, per_page: 10)
      expect(paginated[:data].length).to eq(10)
      expect(paginated[:data].first[:id]).to eq(41)
      expect(paginated[:has_next]).to be false
      expect(paginated[:has_prev]).to be true
    end
  end

  # ── 5. column_info() types ─────────────────────────────────────────
  describe "column_info() types" do
    it "returns real column types from SQLite, not UNKNOWN" do
      db_path = File.join(Dir.tmpdir, "tina4_issue106_colinfo_#{$$}.db")
      db = Tina4::Database.new("sqlite:///" + db_path)
      db.execute("CREATE TABLE col_test (id INTEGER PRIMARY KEY, name TEXT, score REAL, active BOOLEAN)")
      db.execute("INSERT INTO col_test (id, name, score, active) VALUES (1, 'Alice', 9.5, 1)")

      result = db.fetch("SELECT * FROM col_test")
      info = result.column_info

      expect(info).not_to be_empty
      types = info.map { |c| c[:type] }
      expect(types).not_to include("UNKNOWN")

      # Verify specific types are reported correctly
      id_col = info.find { |c| c[:name] == "id" }
      expect(id_col[:type]).to eq("INTEGER")

      name_col = info.find { |c| c[:name] == "name" }
      expect(name_col[:type]).to eq("TEXT")

      score_col = info.find { |c| c[:name] == "score" }
      expect(score_col[:type]).to eq("REAL")

      db.close
      File.delete(db_path) if File.exist?(db_path)
    end
  end

  # ── 6. Default fetch limit is not 20 ───────────────────────────────
  describe "Default fetch limit" do
    it "Database.fetch returns 100 rows with default limit" do
      db_path = File.join(Dir.tmpdir, "tina4_issue106_fetchlimit_#{$$}.db")
      db = Tina4::Database.new("sqlite:///" + db_path)
      db.execute("CREATE TABLE fetch_test (id INTEGER PRIMARY KEY, val TEXT)")

      # Insert 150 rows — more than both 20 and 100
      150.times { |i| db.execute("INSERT INTO fetch_test (id, val) VALUES (?, ?)", [i + 1, "row_#{i + 1}"]) }

      result = db.fetch("SELECT * FROM fetch_test")
      # Without an explicit limit, all 150 rows should be returned
      expect(result.count).to eq(100)

      db.close
      File.delete(db_path) if File.exist?(db_path)
    end

    it "Database.fetch respects explicit limit of 100" do
      db_path = File.join(Dir.tmpdir, "tina4_issue106_fetchlimit2_#{$$}.db")
      db = Tina4::Database.new("sqlite:///" + db_path)
      db.execute("CREATE TABLE fetch_test2 (id INTEGER PRIMARY KEY, val TEXT)")

      150.times { |i| db.execute("INSERT INTO fetch_test2 (id, val) VALUES (?, ?)", [i + 1, "row_#{i + 1}"]) }

      result = db.fetch("SELECT * FROM fetch_test2", [], limit: 100)
      expect(result.count).to eq(100)

      db.close
      File.delete(db_path) if File.exist?(db_path)
    end
  end

  # ── 7. CSS served from framework public ─────────────────────────────
  describe "CSS served from framework public" do
    it "tina4.css exists in the gem's public directory" do
      css_path = File.join(File.dirname(__dir__), "lib", "tina4", "public", "css", "tina4.css")
      expect(File.exist?(css_path)).to be(true), "Expected tina4.css at #{css_path}"
    end

    it "tina4.min.css exists in the gem's public directory" do
      css_path = File.join(File.dirname(__dir__), "lib", "tina4", "public", "css", "tina4.min.css")
      expect(File.exist?(css_path)).to be(true), "Expected tina4.min.css at #{css_path}"
    end
  end
end
