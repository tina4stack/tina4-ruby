# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "base64"

# Comprehensive smoke test for Tina4 Ruby framework.
# Validates all key features work end-to-end using in-memory/temp resources.

RSpec.describe "Tina4 Smoke Test" do
  # ────────────────────────────────────────────────────────────────────────
  # 1. Router
  # ────────────────────────────────────────────────────────────────────────
  describe "Router" do
    before { Tina4::Router.clear! }

    it "registers and matches a GET route" do
      Tina4::Router.get("/smoke/hello") { |_req, _res| "hello" }
      route, params = Tina4::Router.find_route("/smoke/hello", "GET")
      expect(route).not_to be_nil
      expect(route.method).to eq("GET")
      expect(params).to eq({})
    end

    it "registers and matches a POST route" do
      Tina4::Router.post("/smoke/data") { |_req, _res| "posted" }
      route, _params = Tina4::Router.find_route("/smoke/data", "POST")
      expect(route).not_to be_nil
      expect(route.method).to eq("POST")
    end

    it "extracts brace-style params {id}" do
      Tina4::Router.get("/smoke/users/{id}") { |_req, _res| "user" }
      route, params = Tina4::Router.find_route("/smoke/users/42", "GET")
      expect(route).not_to be_nil
      expect(params[:id]).to eq("42")
    end

    it "extracts typed params {id:int}" do
      Tina4::Router.add_route("GET", "/smoke/items/{id:int}", proc { "item" })
      route, params = Tina4::Router.find_route("/smoke/items/7", "GET")
      expect(route).not_to be_nil
      expect(params[:id]).to eq(7)
    end

    it "extracts multiple params" do
      Tina4::Router.get("/smoke/{a}/and/{b}") { "pair" }
      route, params = Tina4::Router.find_route("/smoke/foo/and/bar", "GET")
      expect(route).not_to be_nil
      expect(params[:a]).to eq("foo")
      expect(params[:b]).to eq("bar")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 2. ORM
  # ────────────────────────────────────────────────────────────────────────
  describe "ORM" do
    let(:db) do
      Tina4::Database.new(":memory:", driver_name: "sqlite")
    end

    before do
      db.execute("CREATE TABLE IF NOT EXISTS smoke_widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, weight REAL)")
      # Define a fresh model class each time to avoid cross-test pollution
      stub_const("SmokeWidget", Class.new(Tina4::ORM) {
        table_name "smoke_widgets"
        integer_field :id, primary_key: true, auto_increment: true
        string_field :name
        float_field :weight
      })
      SmokeWidget.db = db
    end

    after { db.close }

    it "saves, loads, and converts to hash" do
      w = SmokeWidget.new(name: "Bolt", weight: 1.5)
      expect(w.save).to be true
      expect(w.id).not_to be_nil

      loaded = SmokeWidget.new(id: w.id)
      expect(loaded.load).to be true
      expect(loaded.name).to eq("Bolt")

      h = loaded.to_h
      expect(h[:name]).to eq("Bolt")
      expect(h[:weight]).to eq(1.5)
    end

    it "deletes a record" do
      w = SmokeWidget.create(name: "Temp", weight: 0.1)
      expect(w.persisted?).to be true
      expect(w.delete).to be true
      expect(SmokeWidget.find(w.id)).to be_nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 3. Database (SQLite in-memory CRUD)
  # ────────────────────────────────────────────────────────────────────────
  describe "Database" do
    let(:db) { Tina4::Database.new(":memory:", driver_name: "sqlite") }
    after { db.close }

    it "creates tables, inserts, selects, updates, deletes" do
      db.execute("CREATE TABLE smoke_items (id INTEGER PRIMARY KEY, val TEXT)")

      # Insert
      db.insert(:smoke_items, { id: 1, val: "alpha" })
      db.insert(:smoke_items, { id: 2, val: "beta" })

      # Select
      rows = db.fetch("SELECT * FROM smoke_items ORDER BY id")
      expect(rows.count).to eq(2)
      expect(rows.first[:val]).to eq("alpha")

      # Update
      db.update(:smoke_items, { val: "ALPHA" }, { id: 1 })
      row = db.fetch_one("SELECT val FROM smoke_items WHERE id = ?", [1])
      expect(row[:val]).to eq("ALPHA")

      # Delete
      db.delete(:smoke_items, { id: 2 })
      expect(db.fetch("SELECT * FROM smoke_items").count).to eq(1)

      # table_exists?
      expect(db.table_exists?("smoke_items")).to be true
      expect(db.table_exists?("no_such_table")).to be false
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 4. Frond templates
  # ────────────────────────────────────────────────────────────────────────
  describe "Frond templates" do
    let(:tmpdir) { Dir.mktmpdir("tina4_frond") }
    let(:engine) { Tina4::Frond.new(template_dir: tmpdir) }
    after { FileUtils.rm_rf(tmpdir) }

    it "renders variables" do
      result = engine.render_string("Hello {{ name }}!", { name: "Tina4" })
      expect(result).to eq("Hello Tina4!")
    end

    it "applies filters" do
      result = engine.render_string("{{ word | upper }}", { word: "hello" })
      expect(result).to eq("HELLO")
    end

    it "supports template inheritance" do
      File.write(File.join(tmpdir, "base.html"), "START{% block body %}default{% endblock %}END")
      File.write(File.join(tmpdir, "child.html"), "{% extends 'base.html' %}{% block body %}custom{% endblock %}")

      result = engine.render("child.html")
      expect(result).to include("START")
      expect(result).to include("custom")
      expect(result).to include("END")
      expect(result).not_to include("default")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 5. Error templates
  # ────────────────────────────────────────────────────────────────────────
  describe "Error templates" do
    it "renders a 404 error page" do
      html = Tina4::Template.render_error(404)
      expect(html).to include("404")
    end

    it "renders a 500 error page" do
      html = Tina4::Template.render_error(500)
      expect(html).to include("500")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 6. Sessions (file handler)
  # ────────────────────────────────────────────────────────────────────────
  describe "Sessions" do
    let(:tmpdir) { Dir.mktmpdir("tina4_sessions") }
    after { FileUtils.rm_rf(tmpdir) }

    it "creates, reads, and destroys a session" do
      env = { "HTTP_COOKIE" => "" }
      session = Tina4::Session.new(env, handler: :file, handler_options: { dir: tmpdir })

      session["user"] = "alice"
      session.save

      # Re-read with same ID
      env2 = { "HTTP_COOKIE" => "tina4_session=#{session.id}" }
      session2 = Tina4::Session.new(env2, handler: :file, handler_options: { dir: tmpdir })
      expect(session2["user"]).to eq("alice")

      # Destroy
      session2.destroy
      env3 = { "HTTP_COOKIE" => "tina4_session=#{session.id}" }
      session3 = Tina4::Session.new(env3, handler: :file, handler_options: { dir: tmpdir })
      expect(session3["user"]).to be_nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 7. Auth / JWT
  # ────────────────────────────────────────────────────────────────────────
  describe "Auth/JWT" do
    let(:tmpdir) { Dir.mktmpdir("tina4_auth") }
    before { Tina4::Auth.setup(tmpdir) }
    after { FileUtils.rm_rf(tmpdir) }

    it "creates and validates a token" do
      token = Tina4::Auth.create_token({ "sub" => "user1" })
      expect(token).to be_a(String)

      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be true
      expect(result[:payload]["sub"]).to eq("user1")
    end

    it "rejects an expired token" do
      token = Tina4::Auth.create_token({ "sub" => "expired" }, expires_in: -1)
      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be false
      expect(result[:error]).to include("expired").or include("Expired").or include("Signature")
    end

    it "hashes and checks a password" do
      hash = Tina4::Auth.hash_password("s3cret!")
      # BCrypt hash starts with $2a$ or $2b$
      expect(hash.to_s).to start_with("$2")
      expect(Tina4::Auth.check_password("s3cret!", hash.to_s)).to be true
      expect(Tina4::Auth.check_password("wrong", hash.to_s)).to be false
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 8. Middleware
  # ────────────────────────────────────────────────────────────────────────
  describe "Middleware" do
    before { Tina4::Middleware.clear! }

    it "runs before and after hooks" do
      log = []
      Tina4::Middleware.before { |_req, _res| log << :before; true }
      Tina4::Middleware.after  { |_req, _res| log << :after }

      req = double("request", path: "/test")
      res = double("response")

      result = Tina4::Middleware.run_before(req, res)
      expect(result).to be true

      Tina4::Middleware.run_after(req, res)
      expect(log).to eq([:before, :after])
    end

    it "halts on before returning false" do
      Tina4::Middleware.before { |_req, _res| false }
      req = double("request", path: "/blocked")
      res = double("response")
      expect(Tina4::Middleware.run_before(req, res)).to be false
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 9. Queue
  # ────────────────────────────────────────────────────────────────────────
  describe "Queue" do
    let(:tmpdir) { Dir.mktmpdir("tina4_queue") }
    after { FileUtils.rm_rf(tmpdir) }

    it "pushes and pops a job with correct payload" do
      backend = Tina4::QueueBackends::LiteBackend.new(dir: tmpdir)
      queue = Tina4::Queue.new(topic: "smoke.jobs", backend: backend)

      msg = queue.produce("smoke.jobs", { action: "test", value: 42 })
      expect(msg).to be_a(Tina4::QueueMessage)
      expect(msg.payload[:action]).to eq("test")

      received = nil
      queue.consume("smoke.jobs") { |job| received = job; job.complete }

      expect(received).not_to be_nil
      expect(received.payload["action"]).to eq("test")
      expect(received.payload["value"]).to eq(42)
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 10. GraphQL
  # ────────────────────────────────────────────────────────────────────────
  describe "GraphQL" do
    it "adds types, queries, mutations and executes" do
      schema = Tina4::GraphQLSchema.new

      user_type = Tina4::GraphQLType.new("User", :object, fields: {
        "id" => { type: "ID" },
        "name" => { type: "String" }
      })
      schema.add_type(user_type)

      schema.add_query("user", type: "User", args: { "id" => { type: "ID!" } }) do |_root, args, _ctx|
        { "id" => args["id"], "name" => "Alice" }
      end

      schema.add_mutation("createUser", type: "User", args: { "name" => { type: "String!" } }) do |_root, args, _ctx|
        { "id" => "99", "name" => args["name"] }
      end

      gql = Tina4::GraphQL.new(schema)

      # Execute query
      result = gql.execute('{ user(id: "1") { id name } }')
      expect(result["data"]["user"]["name"]).to eq("Alice")

      # Execute mutation
      result = gql.execute('mutation { createUser(name: "Bob") { id name } }')
      expect(result["data"]["createUser"]["name"]).to eq("Bob")
    end

    it "auto-generates from ORM class" do
      db = Tina4::Database.new(":memory:", driver_name: "sqlite")
      db.execute("CREATE TABLE smoke_gql_items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)")

      stub_const("SmokeGqlItem", Class.new(Tina4::ORM) {
        table_name "smoke_gql_items"
        integer_field :id, primary_key: true, auto_increment: true
        string_field :title
      })
      SmokeGqlItem.db = db

      schema = Tina4::GraphQLSchema.new
      schema.from_orm(SmokeGqlItem)

      expect(schema.types["SmokeGqlItem"]).not_to be_nil
      expect(schema.queries).to have_key("smoke_gql_item")
      expect(schema.mutations).to have_key("createSmokeGqlItem")
      db.close
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 11. Swagger
  # ────────────────────────────────────────────────────────────────────────
  describe "Swagger" do
    before { Tina4::Router.clear! }

    it "generates an OpenAPI spec" do
      Tina4::Router.get("/api/smoke/items") { "items" }
      Tina4::Router.post("/api/smoke/items") { "create" }

      spec = Tina4::Swagger.generate
      expect(spec["openapi"]).to eq("3.0.3")
      expect(spec["paths"]).to have_key("/api/smoke/items")
      expect(spec["paths"]["/api/smoke/items"]).to have_key("get")
      expect(spec["paths"]["/api/smoke/items"]).to have_key("post")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 12. i18n / Localization
  # ────────────────────────────────────────────────────────────────────────
  describe "i18n" do
    before do
      Tina4::Localization.instance_variable_set(:@translations, {})
      Tina4::Localization.instance_variable_set(:@current_locale, "en")
    end

    it "translates a key and switches locale" do
      Tina4::Localization.add("en", "greeting", "Hello")
      Tina4::Localization.add("fr", "greeting", "Bonjour")

      expect(Tina4::Localization.t("greeting")).to eq("Hello")

      Tina4::Localization.current_locale = "fr"
      expect(Tina4::Localization.t("greeting")).to eq("Bonjour")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 13. FakeData
  # ────────────────────────────────────────────────────────────────────────
  describe "FakeData" do
    it "produces deterministic data with the same seed" do
      fake1 = Tina4::FakeData.new(seed: 123)
      fake2 = Tina4::FakeData.new(seed: 123)

      expect(fake1.name).to eq(fake2.name)
      expect(fake1.email).to eq(fake2.email)
      expect(fake1.integer(min: 0, max: 10_000)).to eq(fake2.integer(min: 0, max: 10_000))
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 14. Migrations
  # ────────────────────────────────────────────────────────────────────────
  describe "Migrations" do
    let(:tmpdir) { Dir.mktmpdir("tina4_migrations") }
    let(:db) { Tina4::Database.new(":memory:", driver_name: "sqlite") }
    after do
      db.close
      FileUtils.rm_rf(tmpdir)
    end

    it "runs a SQL migration and verifies the table" do
      migration = Tina4::Migration.new(db, migrations_dir: tmpdir)

      # Create a SQL migration file
      File.write(File.join(tmpdir, "001_create_smoke_logs.sql"),
        "CREATE TABLE smoke_logs (id INTEGER PRIMARY KEY, message TEXT);")

      results = migration.run
      expect(results).not_to be_empty
      expect(results.first[:status]).to eq("success")
      expect(db.table_exists?("smoke_logs")).to be true
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 15. AutoCRUD
  # ────────────────────────────────────────────────────────────────────────
  describe "AutoCRUD" do
    before do
      Tina4::Router.clear!
      Tina4::AutoCrud.instance_variable_set(:@models, [])
    end

    it "registers a model and creates REST routes" do
      db = Tina4::Database.new(":memory:", driver_name: "sqlite")
      db.execute("CREATE TABLE smoke_products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")

      stub_const("SmokeProduct", Class.new(Tina4::ORM) {
        table_name "smoke_products"
        integer_field :id, primary_key: true, auto_increment: true
        string_field :name
      })
      SmokeProduct.db = db

      Tina4::AutoCrud.register(SmokeProduct)
      Tina4::AutoCrud.generate_routes

      # Verify routes exist
      route_get, _ = Tina4::Router.find_route("/api/smoke_products", "GET")
      route_post, _ = Tina4::Router.find_route("/api/smoke_products", "POST")
      route_single, _ = Tina4::Router.find_route("/api/smoke_products/1", "GET")
      route_put, _ = Tina4::Router.find_route("/api/smoke_products/1", "PUT")
      route_del, _ = Tina4::Router.find_route("/api/smoke_products/1", "DELETE")

      expect(route_get).not_to be_nil
      expect(route_post).not_to be_nil
      expect(route_single).not_to be_nil
      expect(route_put).not_to be_nil
      expect(route_del).not_to be_nil

      db.close
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 16. Response Cache
  # ────────────────────────────────────────────────────────────────────────
  describe "ResponseCache" do
    it "caches a response and returns it on hit" do
      cache = Tina4::ResponseCache.new(ttl: 60)
      expect(cache.enabled?).to be true

      cache.cache_response("GET", "/cached", 200, "application/json", '{"ok":true}')

      hit = cache.get("GET", "/cached")
      expect(hit).not_to be_nil
      expect(hit.body).to eq('{"ok":true}')
      expect(hit.status_code).to eq(200)
    end

    it "returns nil for non-GET" do
      cache = Tina4::ResponseCache.new(ttl: 60)
      cache.cache_response("POST", "/cached", 200, "text/plain", "body")
      expect(cache.get("POST", "/cached")).to be_nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 17. SQL Translation
  # ────────────────────────────────────────────────────────────────────────
  describe "SQLTranslator" do
    it "converts LIMIT/OFFSET to ROWS (Firebird)" do
      result = Tina4::SQLTranslator.limit_to_rows("SELECT * FROM t LIMIT 10 OFFSET 5")
      expect(result).to eq("SELECT * FROM t ROWS 6 TO 15")
    end

    it "converts LIMIT to TOP (MSSQL)" do
      result = Tina4::SQLTranslator.limit_to_top("SELECT * FROM t LIMIT 10")
      expect(result).to eq("SELECT TOP 10 * FROM t")
    end

    it "converts TRUE/FALSE to 1/0" do
      result = Tina4::SQLTranslator.boolean_to_int("SELECT * FROM t WHERE active = TRUE")
      expect(result).to eq("SELECT * FROM t WHERE active = 1")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 18. AI Detection
  # ────────────────────────────────────────────────────────────────────────
  describe "AI Detection" do
    it "returns results for an empty directory" do
      tmpdir = Dir.mktmpdir("tina4_ai")
      results = Tina4::AI.detect_ai(tmpdir)
      expect(results).to be_an(Array)
      # No AI tools should be detected in an empty dir
      detected = results.select { |r| r[:status] == "detected" }
      expect(detected).to be_empty
      FileUtils.rm_rf(tmpdir)
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 19. DevMailbox
  # ────────────────────────────────────────────────────────────────────────
  describe "DevMailbox" do
    let(:tmpdir) { Dir.mktmpdir("tina4_mailbox") }
    after { FileUtils.rm_rf(tmpdir) }

    it "captures an email and reads it back" do
      mailbox = Tina4::DevMailbox.new(mailbox_dir: tmpdir)
      result = mailbox.capture(
        to: "test@localhost",
        subject: "Smoke test email",
        body: "This is a test."
      )
      expect(result[:success]).to be true
      expect(result[:id]).not_to be_nil

      msg = mailbox.read(result[:id])
      expect(msg[:subject]).to eq("Smoke test email")
      expect(msg[:to]).to include("test@localhost")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 20. Static files (MIME detection)
  # ────────────────────────────────────────────────────────────────────────
  describe "Static files / MIME" do
    it "detects common MIME types" do
      expect(Tina4::Response::MIME_TYPES[".html"]).to eq("text/html")
      expect(Tina4::Response::MIME_TYPES[".css"]).to eq("text/css")
      expect(Tina4::Response::MIME_TYPES[".js"]).to eq("application/javascript")
      expect(Tina4::Response::MIME_TYPES[".png"]).to eq("image/png")
      expect(Tina4::Response::MIME_TYPES[".json"]).to eq("application/json")
      expect(Tina4::Response::MIME_TYPES[".pdf"]).to eq("application/pdf")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 21. DotEnv
  # ────────────────────────────────────────────────────────────────────────
  describe "DotEnv" do
    let(:tmpdir) { Dir.mktmpdir("tina4_env") }
    after do
      ENV.delete("SMOKE_TEST_VAR")
      FileUtils.rm_rf(tmpdir)
    end

    it "loads env vars from a .env file" do
      File.write(File.join(tmpdir, ".env"), "SMOKE_TEST_VAR=\"smoke_value\"\n")
      ENV.delete("SMOKE_TEST_VAR")
      Tina4::Env.load_env(tmpdir)
      expect(ENV["SMOKE_TEST_VAR"]).to eq("smoke_value")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 22. WSDL
  # ────────────────────────────────────────────────────────────────────────
  describe "WSDL" do
    it "creates a service definition with operations" do
      svc = Tina4::WSDL::Service.new(name: "SmokeService")
      svc.add_operation("GetItem",
        input_params: { id: :integer },
        output_params: { name: :string, price: :float }
      ) { |params| { name: "Widget", price: 9.99 } }

      wsdl = svc.generate_wsdl("http://localhost/soap")
      expect(wsdl).to include("SmokeService")
      expect(wsdl).to include("GetItem")
      expect(wsdl).to include("definitions")
      expect(wsdl).to include("http://localhost/soap")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 23. WebSocket
  # ────────────────────────────────────────────────────────────────────────
  describe "WebSocket" do
    it "computes a valid accept key from client key + GUID" do
      client_key = "dGhlIHNhbXBsZSBub25jZQ=="
      accept = Base64.strict_encode64(
        Digest::SHA1.digest("#{client_key}#{Tina4::WebSocket::GUID}")
      )
      # The accept key should be a non-empty Base64 string
      expect(accept).to be_a(String)
      expect(accept).not_to be_empty
      # Verify the GUID constant is the RFC 6455 value
      expect(Tina4::WebSocket::GUID).to eq("258EAFA5-E914-47DA-95CA-5AB5DC11AD37")
    end

    it "builds a valid WebSocket frame" do
      conn = Tina4::WebSocketConnection.new("test-id", StringIO.new)
      # Use send to access private build_frame
      frame = conn.__send__(:build_frame, 0x1, "hi")
      expect(frame.bytesize).to be >= 4
      # First byte: FIN + opcode 1 (text)
      expect(frame.bytes[0]).to eq(0x81)
      # Second byte: length 2 (no mask)
      expect(frame.bytes[1]).to eq(2)
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 24. Events
  # ────────────────────────────────────────────────────────────────────────
  describe "Events" do
    after { Tina4::Events.clear }

    it "supports on and emit" do
      received = nil
      Tina4::Events.on("smoke.test") { |data| received = data }
      Tina4::Events.emit("smoke.test", "payload")
      expect(received).to eq("payload")
    end

    it "supports once (fires only once)" do
      count = 0
      Tina4::Events.once("smoke.once") { count += 1 }
      Tina4::Events.emit("smoke.once")
      Tina4::Events.emit("smoke.once")
      expect(count).to eq(1)
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 25. Service Runner (cron matching)
  # ────────────────────────────────────────────────────────────────────────
  describe "ServiceRunner" do
    it "matches a cron pattern" do
      # "* * * * *" matches everything
      expect(Tina4::ServiceRunner.match_cron?("* * * * *")).to be true

      # Exact minute match
      now = Time.now
      pattern = "#{now.min} #{now.hour} * * *"
      expect(Tina4::ServiceRunner.match_cron?(pattern, now)).to be true

      # Non-matching minute
      bad_min = (now.min + 1) % 60
      bad_pattern = "#{bad_min} #{now.hour} * * *"
      expect(Tina4::ServiceRunner.match_cron?(bad_pattern, now)).to be false
    end

    it "matches step patterns like */5" do
      t = Time.new(2026, 1, 1, 12, 0, 0) # minute = 0
      expect(Tina4::ServiceRunner.match_cron?("*/5 * * * *", t)).to be true

      t2 = Time.new(2026, 1, 1, 12, 3, 0) # minute = 3
      expect(Tina4::ServiceRunner.match_cron?("*/5 * * * *", t2)).to be false
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 26. Container (DI)
  # ────────────────────────────────────────────────────────────────────────
  describe "Container" do
    before { Tina4::Container.clear! }

    it "registers and resolves an instance" do
      Tina4::Container.register(:smoke_svc, "hello_service")
      expect(Tina4::Container.resolve(:smoke_svc)).to eq("hello_service")
    end

    it "registers and resolves a lazy factory" do
      call_count = 0
      Tina4::Container.register(:smoke_lazy) { call_count += 1; "lazy_value" }
      expect(Tina4::Container.resolve(:smoke_lazy)).to eq("lazy_value")
      # Second resolve should return memoized instance
      Tina4::Container.resolve(:smoke_lazy)
      expect(call_count).to eq(1)
    end

    it "raises on unknown service" do
      expect { Tina4::Container.resolve(:nonexistent) }.to raise_error(KeyError)
    end
  end
end
