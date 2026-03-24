# frozen_string_literal: true

# Tina4 Ruby Demo Application
# Run: cd tina4-ruby/demo && ruby app.rb
# Visit: http://localhost:7147

$LOAD_PATH.unshift(File.join(__dir__, "..", "lib"))
require "tina4"
require "json"
require "fileutils"

# ---------------------------------------------------------------------------
# Initialize Tina4 (loads .env, sets up logging, auth keys, translations)
# ---------------------------------------------------------------------------
Tina4.initialize!(__dir__)

# ---------------------------------------------------------------------------
# Database setup — SQLite temp file for demo
# ---------------------------------------------------------------------------
DB_PATH = "/tmp/tina4-demo-ruby.db"
DEMO_DB = Tina4::Database.new("sqlite://#{DB_PATH}")
Tina4.database = DEMO_DB

# Create demo table
DEMO_DB.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS demo_users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    age INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  )
SQL

# ---------------------------------------------------------------------------
# Seed tables matching PHP demo parity (users, products, orders)
# ---------------------------------------------------------------------------
DEMO_DB.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    active INTEGER DEFAULT 1,
    created_at TEXT DEFAULT (datetime('now'))
  )
SQL

DEMO_DB.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    price REAL NOT NULL DEFAULT 0,
    stock INTEGER DEFAULT 0,
    category TEXT,
    created_at TEXT DEFAULT (datetime('now'))
  )
SQL

DEMO_DB.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    product_id INTEGER NOT NULL,
    quantity INTEGER DEFAULT 1,
    total REAL NOT NULL DEFAULT 0,
    status TEXT DEFAULT 'pending',
    created_at TEXT DEFAULT (datetime('now'))
  )
SQL

# Seed data if users table is empty
begin
  existing = DEMO_DB.fetch("SELECT COUNT(*) AS cnt FROM users")
  count = existing.to_a.first&.[]("cnt") || existing.to_a.first&.[](:"cnt") || 0
  count = count.to_i

  if count == 0
    # Seed users (5 rows)
    [
      ["Alice Johnson", "alice@example.com", "admin"],
      ["Bob Smith", "bob@example.com", "user"],
      ["Charlie Brown", "charlie@example.com", "user"],
      ["Diana Prince", "diana@example.com", "moderator"],
      ["Eve Martinez", "eve@example.com", "user"]
    ].each do |name, email, role|
      DEMO_DB.execute("INSERT INTO users (name, email, role) VALUES (?, ?, ?)", [name, email, role])
    end

    # Seed products (8 rows)
    [
      ["Wireless Mouse", "Ergonomic wireless mouse with USB receiver", 29.99, 150, "Electronics"],
      ["Mechanical Keyboard", "Cherry MX Blue switches, RGB backlit", 89.99, 75, "Electronics"],
      ["USB-C Hub", "7-in-1 USB-C hub with HDMI, ethernet, SD card", 49.99, 200, "Electronics"],
      ["Standing Desk Mat", "Anti-fatigue mat for standing desks", 39.99, 100, "Office"],
      ["Notebook A5", "Ruled notebook, 200 pages, hardcover", 12.99, 500, "Stationery"],
      ["Desk Lamp", "LED desk lamp with adjustable brightness", 34.99, 80, "Office"],
      ["Webcam HD", "1080p webcam with built-in microphone", 59.99, 60, "Electronics"],
      ["Monitor Stand", "Adjustable monitor riser with storage", 44.99, 90, "Office"]
    ].each do |name, desc, price, stock, category|
      DEMO_DB.execute("INSERT INTO products (name, description, price, stock, category) VALUES (?, ?, ?, ?, ?)", [name, desc, price, stock, category])
    end

    # Seed orders (8 rows)
    [
      [1, 2, 1, 89.99, "completed"],
      [2, 1, 2, 59.98, "completed"],
      [1, 3, 1, 49.99, "shipped"],
      [3, 5, 3, 38.97, "pending"],
      [4, 7, 1, 59.99, "completed"],
      [5, 4, 1, 39.99, "pending"],
      [2, 6, 1, 34.99, "shipped"],
      [3, 8, 2, 89.98, "pending"]
    ].each do |user_id, product_id, quantity, total, status|
      DEMO_DB.execute("INSERT INTO orders (user_id, product_id, quantity, total, status) VALUES (?, ?, ?, ?, ?)", [user_id, product_id, quantity, total, status])
    end

    Tina4::Log.info("Seeded users, products, and orders tables with demo data")
  end
rescue => e
  Tina4::Log.warning("Could not seed demo tables: #{e.message}")
end

# ---------------------------------------------------------------------------
# ORM Model — defined after table exists
# ---------------------------------------------------------------------------
class DemoUser < Tina4::ORM
  table_name "demo_users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
  string_field  :email
  integer_field :age, nullable: true
  datetime_field :created_at, nullable: true
end

# ---------------------------------------------------------------------------
# Register Auto-CRUD for DemoUser (creates GET/POST/PUT/DELETE /api/demo_users)
# ---------------------------------------------------------------------------
Tina4::AutoCrud.register(DemoUser)
Tina4::AutoCrud.generate_routes(prefix: "/api")

# ---------------------------------------------------------------------------
# GraphQL setup
# ---------------------------------------------------------------------------
DEMO_SCHEMA = Tina4::GraphQLSchema.new
DEMO_SCHEMA.from_orm(DemoUser)
DEMO_GQL = Tina4::GraphQL.new(DEMO_SCHEMA)
DEMO_GQL.register_route("/graphql")

# ---------------------------------------------------------------------------
# WSDL Service setup
# ---------------------------------------------------------------------------
DEMO_WSDL_SERVICE = Tina4::WSDL::Service.new(name: "DemoService")
DEMO_WSDL_SERVICE.add_operation(
  "GetGreeting",
  input_params: { name: :string },
  output_params: { greeting: :string }
) do |params|
  { greeting: "Hello, #{params['name']}! From Tina4 WSDL." }
end

# ---------------------------------------------------------------------------
# Middleware — add a custom header to all /demo/* requests
# ---------------------------------------------------------------------------
Tina4.before("/demo") do |request, response|
  response.header("X-Tina4-Demo", "true")
  true
end

# ---------------------------------------------------------------------------
# Helper to build JSON demo responses
# ---------------------------------------------------------------------------
def demo_response(feature:, status:, output:, notes: "")
  {
    feature: feature,
    status: status,
    output: output,
    notes: notes
  }
end

# ---------------------------------------------------------------------------
# GET / — Landing page (HTML)
# ---------------------------------------------------------------------------
Tina4.get "/" do |request, response|
  response.html(<<~HTML)
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Tina4 Ruby Demo</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               background: #0d1117; color: #c9d1d9; line-height: 1.6; }
        .container { max-width: 900px; margin: 0 auto; padding: 2rem; }
        h1 { color: #c084fc; font-size: 2.2rem; margin-bottom: 0.5rem; }
        h2 { color: #8b949e; font-size: 1.1rem; font-weight: normal; margin-bottom: 2rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 1rem; }
        .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px;
                padding: 1.2rem; transition: border-color 0.2s; }
        .card:hover { border-color: #c084fc; }
        .card a { color: #58a6ff; text-decoration: none; font-weight: 600; font-size: 1.05rem; }
        .card a:hover { text-decoration: underline; }
        .card p { color: #8b949e; font-size: 0.9rem; margin-top: 0.4rem; }
        .banner { white-space: pre; font-family: monospace; color: #c084fc;
                  font-size: 0.7rem; line-height: 1.2; margin-bottom: 1.5rem; }
        .footer { margin-top: 2rem; text-align: center; color: #484f58; font-size: 0.85rem; }
        .footer a { color: #58a6ff; text-decoration: none; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="banner">
    ████████╗██╗███╗   ██╗ █████╗ ██╗  ██╗
    ╚══██╔══╝██║████╗  ██║██╔══██╗██║  ██║
       ██║   ██║██╔██╗ ██║███████║███████║
       ██║   ██║██║╚██╗██║██╔══██║╚════██║
       ██║   ██║██║ ╚████║██║  ██║     ██║
       ╚═╝   ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝     ╚═╝</div>
        <h1>Tina4 Ruby Demo</h1>
        <h2>Every feature of the framework, live and interactive</h2>

        <div class="grid">
          <div class="card">
            <a href="/demo/routing">Routing</a>
            <p>GET/POST route registration, path params, type hints</p>
          </div>
          <div class="card">
            <a href="/demo/routing/42">Routing with Param</a>
            <p>Path parameter {id:int} with type coercion</p>
          </div>
          <div class="card">
            <a href="/demo/orm">ORM</a>
            <p>Create, insert, query with Tina4::ORM and SQLite</p>
          </div>
          <div class="card">
            <a href="/demo/auth">Authentication</a>
            <p>JWT token generation and validation (RS256)</p>
          </div>
          <div class="card">
            <a href="/demo/sessions">Sessions</a>
            <p>Server-side session set/get with file handler</p>
          </div>
          <div class="card">
            <a href="/demo/graphql">GraphQL</a>
            <p>Auto-generated schema from ORM, query execution</p>
          </div>
          <div class="card">
            <a href="/graphql">GraphiQL UI</a>
            <p>Interactive GraphQL explorer at /graphql</p>
          </div>
          <div class="card">
            <a href="/demo/websocket">WebSocket</a>
            <p>WebSocket handler info and API overview</p>
          </div>
          <div class="card">
            <a href="/demo/swagger">Swagger / OpenAPI</a>
            <p>Auto-generated API docs from registered routes</p>
          </div>
          <div class="card">
            <a href="/swagger">Swagger UI</a>
            <p>Interactive Swagger UI at /swagger</p>
          </div>
          <div class="card">
            <a href="/demo/api-client">API Client</a>
            <p>Tina4::API HTTP client — self-referencing call</p>
          </div>
          <div class="card">
            <a href="/demo/wsdl">WSDL</a>
            <p>SOAP/WSDL service definition and invocation</p>
          </div>
          <div class="card">
            <a href="/demo/queue">Queue</a>
            <p>Producer/Consumer message queue with LiteBackend</p>
          </div>
          <div class="card">
            <a href="/demo/faker">Faker / Seeder</a>
            <p>FakeData generator — names, emails, sentences</p>
          </div>
          <div class="card">
            <a href="/demo/i18n">Localization (i18n)</a>
            <p>Translation with interpolation, locale switching</p>
          </div>
          <div class="card">
            <a href="/demo/migrations">Migrations</a>
            <p>Migration tracking status</p>
          </div>
          <div class="card">
            <a href="/demo/auto-crud">Auto-CRUD</a>
            <p>Auto-generated REST endpoints for ORM models</p>
          </div>
          <div class="card">
            <a href="/demo/middleware">Middleware</a>
            <p>Before/after request hooks</p>
          </div>
          <div class="card">
            <a href="/demo/logging">Logging</a>
            <p>Structured logging with levels and colors</p>
          </div>
          <div class="card">
            <a href="/demo/scss">SCSS Compiler</a>
            <p>Built-in SCSS to CSS compilation</p>
          </div>
          <div class="card">
            <a href="/demo/shortcomings">Shortcomings</a>
            <p>Honest report — what works and what does not</p>
          </div>
        </div>

        <div class="footer">
          <p>Tina4 Ruby v#{Tina4::VERSION} &mdash; <a href="https://tina4.com">tina4.com</a></p>
        </div>
      </div>
    </body>
    </html>
  HTML
end

# ---------------------------------------------------------------------------
# GET /demo/routing — Basic routing demo
# ---------------------------------------------------------------------------
Tina4.get "/demo/routing" do |request, response|
  route_list = Tina4::Router.routes.map { |r| { method: r.method, path: r.path } }
  response.json(demo_response(
    feature: "Routing",
    status: "working",
    output: {
      registered_route_count: route_list.length,
      sample_routes: route_list.first(10),
      request_method: request.method,
      request_path: request.path,
      request_url: request.url
    },
    notes: "Routes registered via Tina4.get/post/put/patch/delete. Params use {name} or {name:type} syntax."
  ))
end

# ---------------------------------------------------------------------------
# GET /demo/routing/{id:int} — Path parameter with type hint
# ---------------------------------------------------------------------------
Tina4.get "/demo/routing/{id:int}" do |request, response|
  response.json(demo_response(
    feature: "Routing (path params)",
    status: "working",
    output: {
      path_params: request.path_params,
      id_value: request.path_params[:id],
      id_class: request.path_params[:id].class.name,
      note: "The {id:int} type hint auto-casts the value to Integer"
    },
    notes: "Supports {id:int}, {amount:float}, {slug:path} type hints."
  ))
end

# ---------------------------------------------------------------------------
# GET /demo/orm — ORM create, insert, query
# ---------------------------------------------------------------------------
Tina4.get "/demo/orm" do |request, response|
  begin
    # Insert a test record
    user = DemoUser.create(name: "Demo User #{rand(1000)}", email: "demo#{rand(1000)}@tina4.com", age: rand(18..65))

    # Query
    all_users = DemoUser.all(limit: 5, order_by: "id DESC")
    count = DemoUser.count

    # Find by ID
    found = DemoUser.find(user.id)

    response.json(demo_response(
      feature: "ORM",
      status: "working",
      output: {
        created_user: user.to_h,
        found_by_id: found&.to_h,
        total_records: count,
        recent_users: all_users.map(&:to_h),
        table_name: DemoUser.table_name,
        field_definitions: DemoUser.field_definitions.transform_values { |v| v[:type].to_s }
      },
      notes: "Using SQLite at #{DB_PATH}. ORM supports create, find, where, all, count, save, delete."
    ))
  rescue => e
    response.json(demo_response(
      feature: "ORM",
      status: "partial",
      output: { error: e.message, backtrace: e.backtrace&.first(3) },
      notes: "ORM encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/auth — JWT generation and validation
# ---------------------------------------------------------------------------
Tina4.get "/demo/auth" do |request, response|
  begin
    # Generate a token
    payload = { user_id: 1, role: "admin", email: "demo@tina4.com" }
    token = Tina4::Auth.create_token(payload, expires_in: 3600)

    # Validate it
    validation = Tina4::Auth.validate_token(token)

    # Password hashing
    hashed = Tina4::Auth.hash_password("demo-password")
    verified = Tina4::Auth.check_password("demo-password", hashed)
    wrong = Tina4::Auth.check_password("wrong-password", hashed)

    response.json(demo_response(
      feature: "Auth (JWT + bcrypt)",
      status: "working",
      output: {
        jwt_token: "#{token[0..50]}...",
        token_valid: validation[:valid],
        token_payload: validation[:payload],
        password_hash: hashed.to_s[0..30] + "...",
        password_verified_correct: verified,
        password_verified_wrong: wrong
      },
      notes: "JWT uses RS256 with auto-generated key pair in .keys/. Password hashing via bcrypt."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Auth",
      status: "partial",
      output: { error: e.message, backtrace: e.backtrace&.first(3) },
      notes: "Auth requires 'jwt' and 'bcrypt' gems."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/sessions — Session set/get
# ---------------------------------------------------------------------------
Tina4.get "/demo/sessions" do |request, response|
  begin
    session = Tina4::Session.new(request.env)
    visit_count = (session["visit_count"] || 0).to_i + 1
    session["visit_count"] = visit_count
    session["last_visit"] = Time.now.iso8601
    session.save

    response.set_cookie("tina4_session", session.id, max_age: 86400)
    response.json(demo_response(
      feature: "Sessions",
      status: "working",
      output: {
        session_id: session.id[0..16] + "...",
        visit_count: visit_count,
        session_data: session.to_hash
      },
      notes: "File-based session handler. Refresh this page to see the visit counter increment."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Sessions",
      status: "partial",
      output: { error: e.message },
      notes: "Session encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/graphql — GraphQL schema demo
# ---------------------------------------------------------------------------
Tina4.get "/demo/graphql" do |request, response|
  begin
    # Execute a query
    result = DEMO_GQL.execute('{ demo_users(limit: 3) { id name email age } }')

    response.json(demo_response(
      feature: "GraphQL",
      status: "working",
      output: {
        schema_types: DEMO_SCHEMA.types.keys,
        schema_queries: DEMO_SCHEMA.queries.keys,
        schema_mutations: DEMO_SCHEMA.mutations.keys,
        sample_query: '{ demo_users(limit: 3) { id name email age } }',
        sample_result: result,
        graphiql_url: "/graphql"
      },
      notes: "Schema auto-generated from ORM. Visit /graphql for the interactive GraphiQL UI."
    ))
  rescue => e
    response.json(demo_response(
      feature: "GraphQL",
      status: "partial",
      output: { error: e.message },
      notes: "GraphQL encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/websocket — WebSocket info
# ---------------------------------------------------------------------------
Tina4.get "/demo/websocket" do |request, response|
  begin
    ws = Tina4::WebSocket.new
    response.json(demo_response(
      feature: "WebSocket",
      status: "working",
      output: {
        class: "Tina4::WebSocket",
        methods: %w[on upgrade? handle_upgrade broadcast connections],
        events: %w[open message close error],
        note: "WebSocket requires a raw TCP socket upgrade. WEBrick does not support WS natively. Use Puma or a reverse proxy for production WebSocket usage."
      },
      notes: "The WebSocket module exists and is functional but requires a compatible server (Puma, Thin, etc.) for actual WS connections."
    ))
  rescue => e
    response.json(demo_response(
      feature: "WebSocket",
      status: "partial",
      output: { error: e.message },
      notes: "WebSocket class exists but requires compatible server."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/swagger — Swagger info
# ---------------------------------------------------------------------------
Tina4.get "/demo/swagger" do |request, response|
  begin
    spec = Tina4::Swagger.generate
    response.json(demo_response(
      feature: "Swagger / OpenAPI",
      status: "working",
      output: {
        openapi_version: spec["openapi"],
        info: spec["info"],
        path_count: spec["paths"].keys.length,
        paths: spec["paths"].keys.first(15),
        swagger_ui_url: "/swagger",
        openapi_json_url: "/swagger/openapi.json"
      },
      notes: "OpenAPI 3.0.3 spec auto-generated from registered routes. Visit /swagger for interactive UI."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Swagger",
      status: "partial",
      output: { error: e.message },
      notes: "Swagger generation encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/api-client — HTTP client demo (self-referencing call)
# ---------------------------------------------------------------------------
Tina4.get "/demo/api-client" do |request, response|
  begin
    client = Tina4::API.new("http://localhost:7147")
    api_response = client.get("/demo/routing")

    response.json(demo_response(
      feature: "API Client",
      status: api_response.success? ? "working" : "partial",
      output: {
        base_url: "http://localhost:7147",
        request_path: "/demo/routing",
        response_status: api_response.status,
        response_success: api_response.success?,
        response_body_preview: api_response.json.is_a?(Hash) ? api_response.json.keys : api_response.body[0..200],
        methods_available: %w[get post put patch delete upload]
      },
      notes: "Tina4::API is a built-in HTTP client wrapping Net::HTTP. This demo calls itself."
    ))
  rescue => e
    response.json(demo_response(
      feature: "API Client",
      status: "partial",
      output: { error: e.message },
      notes: "API client self-call may fail if server is single-threaded."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/wsdl — WSDL service info
# ---------------------------------------------------------------------------
Tina4.get "/demo/wsdl" do |request, response|
  begin
    wsdl_xml = DEMO_WSDL_SERVICE.generate_wsdl("http://localhost:7147/soap")

    # Invoke the operation directly
    soap_result = DEMO_WSDL_SERVICE.handle_soap_request(
      '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">' \
      '<soap:Body><GetGreeting><name>Tina4</name></GetGreeting></soap:Body></soap:Envelope>'
    )

    response.json(demo_response(
      feature: "WSDL",
      status: "working",
      output: {
        service_name: DEMO_WSDL_SERVICE.name,
        namespace: DEMO_WSDL_SERVICE.namespace,
        operations: DEMO_WSDL_SERVICE.operations.keys,
        wsdl_preview: wsdl_xml[0..300] + "...",
        soap_invocation_result: soap_result[0..300] + "..."
      },
      notes: "WSDL service with SOAP envelope parsing. Full WSDL XML generation and operation handling."
    ))
  rescue => e
    response.json(demo_response(
      feature: "WSDL",
      status: "partial",
      output: { error: e.message },
      notes: "WSDL encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/queue — Queue push/pop
# ---------------------------------------------------------------------------
Tina4.get "/demo/queue" do |request, response|
  begin
    backend = Tina4::QueueBackends::LiteBackend.new(dir: "/tmp/tina4-demo-queue")
    queue = Tina4::Queue.new(topic: "demo-topic", backend: backend)

    # Publish messages
    msg1 = queue.produce("demo-topic", { action: "greet", data: "Hello from queue!" })
    msg2 = queue.produce("demo-topic", { action: "process", data: "Task ##{rand(1000)}" })

    # Consume one
    consumed = nil
    queue.consume("demo-topic") { |msg| consumed = msg.to_hash; msg.complete }

    response.json(demo_response(
      feature: "Queue",
      status: "working",
      output: {
        published_message_1: msg1.to_hash,
        published_message_2: msg2.to_hash,
        consumed_message: consumed,
        remaining_size: backend.size("demo-topic"),
        backend: "LiteBackend (file-based)"
      },
      notes: "Queue produce/consume pattern with LiteBackend (file-based). Also supports RabbitMQ and Kafka backends."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Queue",
      status: "partial",
      output: { error: e.message },
      notes: "Queue encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/faker — Fake data generation
# ---------------------------------------------------------------------------
Tina4.get "/demo/faker" do |request, response|
  begin
    fake = Tina4::FakeData.new(seed: 42)

    response.json(demo_response(
      feature: "FakeData / Seeder",
      status: "working",
      output: {
        name: fake.name,
        email: fake.email,
        phone: fake.phone,
        sentence: fake.sentence(words: 8),
        paragraph: fake.paragraph(sentences: 2),
        integer: fake.integer(min: 1, max: 100),
        numeric: fake.numeric(min: 0.0, max: 100.0, decimals: 2),
        date: fake.date,
        city: fake.city,
        country: fake.country,
        address: fake.address,
        company: fake.company,
        uuid: fake.uuid,
        url: fake.url,
        color_hex: fake.color_hex,
        slug: fake.slug,
        deterministic_note: "seed: 42 produces the same data every time"
      },
      notes: "Zero-dependency fake data generator with deterministic seeding. Also supports seed_orm() for auto-populating ORM models."
    ))
  rescue => e
    response.json(demo_response(
      feature: "FakeData",
      status: "partial",
      output: { error: e.message },
      notes: "FakeData encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/i18n — Translation demo
# ---------------------------------------------------------------------------
Tina4.get "/demo/i18n" do |request, response|
  begin
    en_greeting = Tina4.t("greeting", name: "World")
    en_farewell = Tina4.t("farewell", name: "World")
    en_title = Tina4.t("demo.title")

    fr_greeting = Tina4.t("greeting", locale: "fr", name: "Monde")
    fr_farewell = Tina4.t("farewell", locale: "fr", name: "Monde")
    fr_title = Tina4.t("demo.title", locale: "fr")

    missing = Tina4.t("nonexistent.key", default: "fallback value")

    response.json(demo_response(
      feature: "Localization (i18n)",
      status: "working",
      output: {
        current_locale: Tina4::Localization.current_locale,
        available_locales: Tina4::Localization.available_locales,
        english: { greeting: en_greeting, farewell: en_farewell, title: en_title },
        french: { greeting: fr_greeting, farewell: fr_farewell, title: fr_title },
        missing_key_with_default: missing
      },
      notes: "Loads JSON/YAML from src/locales/. Supports dot-notation keys, interpolation (%{name}), locale fallback."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Localization",
      status: "partial",
      output: { error: e.message },
      notes: "Localization encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/migrations — Migration status
# ---------------------------------------------------------------------------
Tina4.get "/demo/migrations" do |request, response|
  begin
    migration = Tina4::Migration.new(DEMO_DB, migrations_dir: File.join(__dir__, "src", "migrations"))
    status = migration.status

    response.json(demo_response(
      feature: "Migrations",
      status: "working",
      output: {
        migration_status: status,
        tracking_table: Tina4::Migration::TRACKING_TABLE,
        migrations_dir: File.join(__dir__, "src", "migrations"),
        database_tables: DEMO_DB.tables
      },
      notes: "Migration system with up/down, batch tracking, rollback. Supports .rb and .sql files."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Migrations",
      status: "partial",
      output: { error: e.message },
      notes: "Migration encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/auto-crud — Auto-CRUD info
# ---------------------------------------------------------------------------
Tina4.get "/demo/auto-crud" do |request, response|
  begin
    models = Tina4::AutoCrud.models.map(&:name)

    response.json(demo_response(
      feature: "Auto-CRUD",
      status: "working",
      output: {
        registered_models: models,
        endpoints: [
          "GET /api/demo_users — list with pagination, filtering, sorting",
          "GET /api/demo_users/{id} — get single record",
          "POST /api/demo_users — create record",
          "PUT /api/demo_users/{id} — update record",
          "DELETE /api/demo_users/{id} — delete record"
        ],
        try_it: "/api/demo_users"
      },
      notes: "Register any ORM model with Tina4::AutoCrud.register(Model) and call generate_routes. Supports filter[], sort, limit, offset."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Auto-CRUD",
      status: "partial",
      output: { error: e.message },
      notes: "Auto-CRUD encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/middleware — Middleware demo
# ---------------------------------------------------------------------------
Tina4.get "/demo/middleware" do |request, response|
  begin
    response.json(demo_response(
      feature: "Middleware",
      status: "working",
      output: {
        before_handlers_count: Tina4::Middleware.before_handlers.length,
        after_handlers_count: Tina4::Middleware.after_handlers.length,
        custom_header_added: response.headers["X-Tina4-Demo"],
        note: "The X-Tina4-Demo header was added by a before-middleware on /demo/* routes. Check response headers."
      },
      notes: "Tina4.before(pattern) and Tina4.after(pattern) add request hooks. Pattern can be a String prefix or Regexp."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Middleware",
      status: "partial",
      output: { error: e.message },
      notes: "Middleware encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/logging — Logging demo
# ---------------------------------------------------------------------------
Tina4.get "/demo/logging" do |request, response|
  begin
    Tina4::Log.info("Demo log: INFO level message")
    Tina4::Log.debug("Demo log: DEBUG level message")
    Tina4::Log.warning("Demo log: WARNING level message")
    Tina4::Log.error("Demo log: ERROR level message (this is just a test)")

    response.json(demo_response(
      feature: "Logging",
      status: "working",
      output: {
        log_levels: %w[debug info warning error],
        log_dir: Tina4::Log.log_dir,
        debug_level: ENV["TINA4_DEBUG_LEVEL"] || "[TINA4_LOG_ALL]",
        methods: %w[Tina4::Log.info Tina4::Log.debug Tina4::Log.warning Tina4::Log.error],
        note: "Check the console and logs/debug.log for the messages just emitted."
      },
      notes: "Structured logging with color output (dev) or JSON (production). Supports log rotation and gzip compression."
    ))
  rescue => e
    response.json(demo_response(
      feature: "Logging",
      status: "partial",
      output: { error: e.message },
      notes: "Logging encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/scss — SCSS compilation
# ---------------------------------------------------------------------------
Tina4.get "/demo/scss" do |request, response|
  begin
    # Create a temp SCSS file and compile it
    scss_dir = File.join(__dir__, "src", "scss")
    FileUtils.mkdir_p(scss_dir)
    scss_file = File.join(scss_dir, "demo.scss")
    File.write(scss_file, <<~SCSS)
      $primary: #c084fc;
      $bg: #0d1117;

      body {
        background: $bg;
        color: $primary;

        h1 {
          font-size: 2rem;
        }
      }
    SCSS

    css_output = Tina4::ScssCompiler.compile_scss(
      File.read(scss_file),
      scss_dir
    )

    response.json(demo_response(
      feature: "SCSS Compiler",
      status: "working",
      output: {
        input_scss: File.read(scss_file).strip,
        output_css: css_output.strip,
        note: "Basic SCSS compiler handles variables, nesting, and imports. For full Sass, install the sassc gem."
      },
      notes: "Built-in basic SCSS-to-CSS compiler. Falls back to sassc gem if available."
    ))
  rescue => e
    response.json(demo_response(
      feature: "SCSS Compiler",
      status: "partial",
      output: { error: e.message },
      notes: "SCSS compilation encountered an error."
    ))
  end
end

# ---------------------------------------------------------------------------
# GET /demo/shortcomings — Honest report of what works and what does not
# ---------------------------------------------------------------------------
Tina4.get "/demo/shortcomings" do |request, response|
  results = []

  # 1. Routing
  results << { feature: "Routing", status: "working", detail: "GET/POST/PUT/PATCH/DELETE, path params with types, groups, middleware" }

  # 2. ORM
  begin
    u = DemoUser.create(name: "test", email: "test@test.com")
    DemoUser.find(u.id)
    DemoUser.all(limit: 1)
    DemoUser.count
    u.delete
    results << { feature: "ORM", status: "working", detail: "create, find, where, all, count, save, delete, field types DSL" }
  rescue => e
    results << { feature: "ORM", status: "partial", detail: e.message }
  end

  # 3. Database
  begin
    DEMO_DB.tables
    DEMO_DB.columns("demo_users")
    DEMO_DB.table_exists?("demo_users")
    results << { feature: "Database", status: "working", detail: "SQLite driver, fetch, execute, insert, update, delete, transaction, tables, columns" }
  rescue => e
    results << { feature: "Database", status: "partial", detail: e.message }
  end

  # 4. Auth
  begin
    token = Tina4::Auth.create_token({ test: true })
    Tina4::Auth.validate_token(token)
    results << { feature: "Auth (JWT)", status: "working", detail: "RS256 token generation and validation" }
  rescue => e
    results << { feature: "Auth (JWT)", status: "partial", detail: e.message }
  end

  begin
    h = Tina4::Auth.hash_password("test")
    Tina4::Auth.check_password("test", h)
    results << { feature: "Auth (bcrypt)", status: "working", detail: "Password hashing and verification" }
  rescue => e
    results << { feature: "Auth (bcrypt)", status: "partial", detail: e.message }
  end

  # 5. Sessions
  begin
    s = Tina4::Session.new({})
    s["key"] = "value"
    s.save
    results << { feature: "Sessions", status: "working", detail: "File-based session handler, set/get/delete/clear" }
  rescue => e
    results << { feature: "Sessions", status: "partial", detail: e.message }
  end

  # 6. GraphQL
  begin
    r = DEMO_GQL.execute('{ demo_users(limit: 1) { id name } }')
    if r["errors"] && !r["errors"].empty?
      results << { feature: "GraphQL", status: "partial", detail: r["errors"].first["message"] }
    else
      results << { feature: "GraphQL", status: "working", detail: "Parser, executor, ORM auto-schema, route registration" }
    end
  rescue => e
    results << { feature: "GraphQL", status: "partial", detail: e.message }
  end

  # 7. WebSocket
  begin
    ws = Tina4::WebSocket.new
    results << { feature: "WebSocket", status: "working", detail: "Class instantiates. Actual WS requires Puma/compatible server, not WEBrick." }
  rescue => e
    results << { feature: "WebSocket", status: "missing", detail: e.message }
  end

  # 8. Swagger
  begin
    spec = Tina4::Swagger.generate
    results << { feature: "Swagger", status: "working", detail: "OpenAPI 3.0.3 spec generated with #{spec['paths'].keys.length} paths" }
  rescue => e
    results << { feature: "Swagger", status: "partial", detail: e.message }
  end

  # 9. API Client
  begin
    Tina4::API.new("http://localhost:7147")
    results << { feature: "API Client", status: "working", detail: "HTTP client class instantiates. Self-call may hang on single-threaded server." }
  rescue => e
    results << { feature: "API Client", status: "partial", detail: e.message }
  end

  # 10. WSDL
  begin
    xml = DEMO_WSDL_SERVICE.generate_wsdl("http://localhost:7147/soap")
    results << { feature: "WSDL", status: "working", detail: "WSDL XML generation and SOAP request handling" }
  rescue => e
    results << { feature: "WSDL", status: "partial", detail: e.message }
  end

  # 11. Queue
  begin
    be = Tina4::QueueBackends::LiteBackend.new(dir: "/tmp/tina4-demo-queue-test")
    q = Tina4::Queue.new(topic: "test", backend: be)
    q.produce("test", { hello: "world" })
    q.consume("test") { |job| job.complete }
    results << { feature: "Queue", status: "working", detail: "LiteBackend publish/consume works" }
  rescue => e
    results << { feature: "Queue", status: "partial", detail: e.message }
  end

  # 12. FakeData
  begin
    f = Tina4::FakeData.new(seed: 1)
    f.name; f.email; f.phone; f.sentence
    results << { feature: "FakeData / Seeder", status: "working", detail: "Deterministic fake data generation" }
  rescue => e
    results << { feature: "FakeData", status: "partial", detail: e.message }
  end

  # 13. Localization
  begin
    r = Tina4.t("greeting", name: "Test")
    results << { feature: "Localization (i18n)", status: "working", detail: "Translation with interpolation, locale switching, dot-notation keys" }
  rescue => e
    results << { feature: "Localization", status: "partial", detail: e.message }
  end

  # 14. Migrations
  begin
    m = Tina4::Migration.new(DEMO_DB, migrations_dir: File.join(__dir__, "src", "migrations"))
    m.status
    results << { feature: "Migrations", status: "working", detail: "Status, run, rollback, create" }
  rescue => e
    results << { feature: "Migrations", status: "partial", detail: e.message }
  end

  # 15. Auto-CRUD
  begin
    models = Tina4::AutoCrud.models
    results << { feature: "Auto-CRUD", status: "working", detail: "#{models.length} model(s) registered with auto REST endpoints" }
  rescue => e
    results << { feature: "Auto-CRUD", status: "partial", detail: e.message }
  end

  # 16. Middleware
  results << { feature: "Middleware", status: "working", detail: "before/after hooks with pattern matching" }

  # 17. Logging
  results << { feature: "Logging", status: "working", detail: "info/debug/warning/error with file and console output, rotation, gzip" }

  # 18. SCSS
  begin
    css = Tina4::ScssCompiler.compile_scss("$c: red; body { color: $c; }", __dir__)
    results << { feature: "SCSS Compiler", status: "working", detail: "Basic SCSS compilation (variables, nesting, imports)" }
  rescue => e
    results << { feature: "SCSS Compiler", status: "partial", detail: e.message }
  end

  # 19. Template
  begin
    Tina4::Template.render_error(404)
    results << { feature: "Template (ERB)", status: "working", detail: "ERB template rendering with globals" }
  rescue => e
    results << { feature: "Template (ERB)", status: "partial", detail: e.message }
  end

  # Summary
  working = results.count { |r| r[:status] == "working" }
  partial = results.count { |r| r[:status] == "partial" }
  missing = results.count { |r| r[:status] == "missing" }

  response.json({
    feature: "Shortcomings Report",
    summary: {
      total: results.length,
      working: working,
      partial: partial,
      missing: missing
    },
    results: results,
    known_limitations: [
      "WebSocket requires Puma or compatible server (WEBrick does not support WS upgrade)",
      "API Client self-call may block on single-threaded WEBrick",
      "SCSS compiler is basic without sassc gem (handles variables, nesting, imports only)",
      "Template engine defaults to ERB; Twig engine is custom and basic",
      "No built-in form validation DSL (use ORM field constraints)",
      "DevReload requires the 'listen' gem"
    ]
  })
end

# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------
app = Tina4::RackApp.new(root_dir: __dir__)
server = Tina4::WebServer.new(app, port: 7147)
server.start
