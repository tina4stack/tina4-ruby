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

    it "registers a working prefixed route via the .group block" do
      # Behavioural proof that .group actually evaluates its block and
      # registers a real, dispatchable route (not just that the method
      # exists). The block runs in the GroupContext, so the bare get(...)
      # call prefixes the path and stores a live handler we can invoke.
      Tina4::Router.group("/x") do
        get("/y") { "y-handler-ran" }
      end

      route, params = Tina4::Router.match("GET", "/x/y")
      expect(route).not_to be_nil
      expect(route.path).to eq("/x/y")
      expect(params).to eq({})
      # The registered block is the real handler — invoking it returns the
      # value defined inside the group, proving the block was wired through.
      expect(route.handler.call).to eq("y-handler-ran")
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

  # ── 4. to_paginate() describes the fetched page (ADR-0043) ──────────
  # GitHub #106 asked for in-memory slicing (to_paginate(page:, per_page:)).
  # ADR-0043 supersedes that: to_paginate takes NO arguments and describes the
  # page the query returned - to read page N you FETCH page N. Passing an
  # argument is a hard error, because a DatabaseResult holds no connection and
  # an argument could only re-slice rows already in memory and lie about
  # total_pages. Real SQLite, no mocks.
  describe "to_paginate() describes the fetched page" do
    def paging_db
      db_path = File.join(Dir.tmpdir, "tina4_issue106_paging_#{$$}.db")
      File.delete(db_path) if File.exist?(db_path)
      db = Tina4::Database.new("sqlite:///" + db_path)
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      (1..50).each { |i| db.execute("INSERT INTO items (id, name) VALUES (?, ?)", [i, "item_#{i}"]) }
      [db, db_path]
    end

    it "reads page 2 (per_page 10) by fetching it, then to_paginate with no arguments" do
      db, db_path = paging_db
      paginated = db.fetch("SELECT * FROM items ORDER BY id", [], limit: 10, offset: 10).to_paginate
      expect(paginated[:records].length).to eq(10)
      expect(paginated[:records].first[:id]).to eq(11)
      expect(paginated[:records].last[:id]).to eq(20)
      expect(paginated[:page]).to eq(2)          # floor(10 / 10) + 1
      expect(paginated[:per_page]).to eq(10)
      expect(paginated[:total]).to eq(50)        # true total, from the COUNT probe
      expect(paginated[:total_pages]).to eq(5)
      db.close
      File.delete(db_path) if File.exist?(db_path)
    end

    it "reads the last page by fetching it" do
      db, db_path = paging_db
      paginated = db.fetch("SELECT * FROM items ORDER BY id", [], limit: 10, offset: 40).to_paginate
      expect(paginated[:records].length).to eq(10)
      expect(paginated[:records].first[:id]).to eq(41)
      expect(paginated[:page]).to eq(5)
      expect(paginated[:total_pages]).to eq(5)
      db.close
      File.delete(db_path) if File.exist?(db_path)
    end

    it "rejects the removed in-memory slicing arguments (ADR-0043)" do
      db, db_path = paging_db
      full = db.fetch("SELECT * FROM items ORDER BY id", [], limit: 0)
      expect { full.to_paginate(page: 2, per_page: 10) }.to raise_error(ArgumentError)
      db.close
      File.delete(db_path) if File.exist?(db_path)
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
      # The default cap returns 100 ROWS, and `count` is the TRUE TOTAL for the
      # filter (150) - not the rows returned. Both halves matter: the cap is what
      # protects you from reading a whole table, and the true total is what lets
      # a paginated response say how many pages really exist. This used to assert
      # count == 100, which pinned the old rows-returned meaning and made a
      # truncation indistinguishable from a complete answer.
      expect(result.records.size).to eq(100)
      expect(result.count).to eq(150)

      db.close
      File.delete(db_path) if File.exist?(db_path)
    end

    it "Database.fetch respects explicit limit of 100" do
      db_path = File.join(Dir.tmpdir, "tina4_issue106_fetchlimit2_#{$$}.db")
      db = Tina4::Database.new("sqlite:///" + db_path)
      db.execute("CREATE TABLE fetch_test2 (id INTEGER PRIMARY KEY, val TEXT)")

      150.times { |i| db.execute("INSERT INTO fetch_test2 (id, val) VALUES (?, ?)", [i + 1, "row_#{i + 1}"]) }

      result = db.fetch("SELECT * FROM fetch_test2", [], limit: 100)
      expect(result.records.size).to eq(100)
      expect(result.count).to eq(150)

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
