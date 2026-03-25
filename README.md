<p align="center">
  <img src="https://tina4.com/logo.svg" alt="Tina4" width="200">
</p>

<h1 align="center">Tina4 Ruby</h1>
<h3 align="center">This is not a framework</h3>

<p align="center">
  Laravel joy. Ruby speed. 10x less code. Zero third-party dependencies.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/tina4"><img src="https://img.shields.io/gem/v/tina4?color=7b1fa2&label=RubyGems" alt="Gem"></a>
  <img src="https://img.shields.io/badge/tests-1%2C578%20passing-brightgreen" alt="Tests">
  <img src="https://img.shields.io/badge/features-38-blue" alt="Features">
  <img src="https://img.shields.io/badge/dependencies-0-brightgreen" alt="Zero Deps">
  <a href="https://tina4.com"><img src="https://img.shields.io/badge/docs-tina4.com-7b1fa2" alt="Docs"></a>
</p>

<p align="center">
  <a href="https://tina4.com">Documentation</a> &bull;
  <a href="#getting-started">Getting Started</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#cli-reference">CLI Reference</a> &bull;
  <a href="https://tina4.com">tina4.com</a>
</p>

---

## Quick Start

```bash
# Install the Tina4 CLI
cargo install tina4  # or download binary from https://github.com/tina4stack/tina4/releases

# Create a project
tina4 init ruby ./my-app

# Run it
cd my-app && tina4 serve
```

Open http://localhost:7147 — your app is running.

<details>
<summary><strong>Without the Tina4 CLI</strong></summary>

```bash
# 1. Create project
mkdir my-app && cd my-app
echo 'source "https://rubygems.org"' > Gemfile
echo 'gem "tina4-ruby", "~> 3.0"' >> Gemfile
bundle install

# 2. Create entry point
cat > app.rb << 'EOF'
require "tina4"
Tina4.initialize!(__dir__)
app = Tina4::RackApp.new
Tina4::WebServer.new(app, host: "0.0.0.0", port: 7147).start
EOF

# 3. Create .env
echo 'TINA4_DEBUG=true' > .env
echo 'TINA4_LOG_LEVEL=ALL' >> .env

# 4. Create route directory
mkdir -p src/routes

# 5. Run
bundle exec ruby app.rb
```

Open http://localhost:7147

</details>

---

## What's Included

Every feature is built from scratch -- no gem install, no node_modules, no third-party runtime dependencies in core.

| Category | Features |
|----------|----------|
| **HTTP** | Rack 3 server, block routing, path params (`{id:int}`, `{p:path}`), middleware pipeline, CORS, rate limiting, graceful shutdown |
| **Templates** | Frond engine (Twig-compatible), inheritance, partials, 35+ filters, macros, fragment caching, sandboxing |
| **ORM** | Active Record, typed fields with validation, soft delete, relationships (`has_one`/`has_many`/`belongs_to`), scopes, result caching, multi-database |
| **Database** | SQLite, PostgreSQL, MySQL, MSSQL, Firebird -- unified adapter interface, query caching (TINA4_DB_CACHE=true for 4x speedup) |
| **Auth** | Zero-dep JWT (HS256/RS256), sessions (file/Redis/Valkey/MongoDB/database), password hashing, form tokens |
| **API** | Swagger/OpenAPI auto-generation, GraphQL with ORM auto-schema and GraphiQL IDE, WSDL/SOAP with auto WSDL |
| **Background** | Queue (SQLite/RabbitMQ/Kafka/MongoDB) with priority, delayed jobs, retry, batch processing |
| **Real-time** | Native WebSocket (RFC 6455), per-path routing, connection manager |
| **Frontend** | tina4-css (~24 KB), frond.js helper, SCSS compiler, live reload, CSS hot-reload |
| **DX** | Dev admin dashboard, error overlay, request inspector, AI tool integration, Carbonah green benchmarks |
| **Data** | Migrations with rollback, 50+ fake data generators, ORM and table seeders |
| **Other** | REST client, localization (6 languages), cache (memory/Redis/file), event system, inline testing, messenger (.env driven), configurable error pages |

**1,578 tests across 38 built-in features. Zero dependencies. All Carbonah benchmarks rated A+.**

For full documentation visit **[tina4.com](https://tina4.com)**.

---

## Install

```bash
gem install tina4ruby
```

### Optional database drivers

Install only what you need:

```bash
gem install pg                   # PostgreSQL
gem install mysql2               # MySQL / MariaDB (driver name: mysql)
gem install tiny_tds             # Microsoft SQL Server
gem install fb                   # Firebird
```

---

## Getting Started

### 1. Create a project

```bash
tina4ruby init my-app
cd my-app
```

This creates:

```
my-app/
├── app.rb              # Entry point
├── .env                # Configuration
├── Gemfile
├── src/
│   ├── routes/         # API + page routes (auto-discovered)
│   ├── orm/            # Database models
│   ├── app/            # Service classes and shared helpers
│   ├── templates/      # Frond/Twig templates
│   ├── seeds/          # Database seeders
│   ├── scss/           # SCSS (auto-compiled to public/css/)
│   └── public/         # Static assets served at /
├── migrations/         # SQL migration files
└── tests/              # RSpec tests
```

### 2. Create a route

Create `src/routes/hello.rb`:

```ruby
Tina4.get "/api/hello" do |request, response|
  response.json({ message: "Hello from Tina4!" })
end

Tina4.get "/api/hello/{name}" do |request, response|
  response.json({ message: "Hello, #{request.params["name"]}!" })
end
```

Visit `http://localhost:7147/api/hello` -- routes are auto-discovered, no requires needed.

### 3. Add a database

Edit `.env`:

```bash
DATABASE_URL=sqlite://data/app.db
DATABASE_USERNAME=
DATABASE_PASSWORD=
```

Create and run a migration:

```bash
tina4ruby migrate --create "create users table"
```

Edit the generated SQL:

```sql
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

```bash
tina4ruby migrate
```

### 4. Create an ORM model

Create `src/orm/user.rb`:

```ruby
class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name, nullable: false, length: 100
  string_field  :email, length: 255
  datetime_field :created_at
end
```

### 5. Build a REST API

Create `src/routes/users.rb`:

```ruby
Tina4.get "/api/users" do |request, response|
  response.json(User.all(limit: 100).map(&:to_hash))
end

Tina4.get "/api/users/{id}" do |request, response|
  user = User.find(request.params["id"])
  if user
    response.json(user.to_hash)
  else
    response.json({ error: "Not found" }, 404)
  end
end

Tina4.post "/api/users", auth: false do |request, response|
  user = User.create(request.json_body)
  response.json(user.to_hash, 201)
end
```

### 6. Add a template

Create `src/templates/base.twig`:

```twig
<!DOCTYPE html>
<html>
<head>
    <title>{% block title %}My App{% endblock %}</title>
    <link rel="stylesheet" href="/css/tina4.min.css">
    {% block stylesheets %}{% endblock %}
</head>
<body>
    {% block content %}{% endblock %}
    <script src="/js/frond.js"></script>
    {% block javascripts %}{% endblock %}
</body>
</html>
```

Create `src/templates/pages/home.twig`:

```twig
{% extends "base.twig" %}
{% block content %}
<div class="container mt-4">
    <h1>{{ title }}</h1>
    <ul>
    {% for user in users %}
        <li>{{ user.name }} -- {{ user.email }}</li>
    {% endfor %}
    </ul>
</div>
{% endblock %}
```

Render it from a route:

```ruby
Tina4.get "/" do |request, response|
  users = User.all(limit: 20).map(&:to_hash)
  response.render("pages/home.twig", { title: "Users", users: users })
end
```

### 7. Seed, test, deploy

```bash
tina4ruby seed                          # Run seeders from src/seeds/
tina4ruby test                          # Run test suite
tina4ruby build                         # Build distributable
```

For the complete step-by-step guide, visit **[tina4.com](https://tina4.com)**.

---

## Features

### Routing

```ruby
Tina4.get "/api/items" do |request, response|       # Public by default
  response.json({ items: [] })
end

Tina4.post "/api/webhook", auth: false do |request, response|  # Make a write route public
  response.json({ ok: true })
end

Tina4.secure_get "/api/admin/stats" do |request, response|     # Protect a GET route
  response.json({ secret: true })
end
```

Path parameter types: `{id}` (string), `{id:int}`, `{price:float}`, `{path:path}` (greedy).

### ORM

Active Record with typed fields, validation, soft delete, relationships, scopes, and multi-database support.

```ruby
class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name, nullable: false, length: 100
  string_field  :email, length: 255
  string_field  :role, default: "user"
  integer_field :age, default: 0
end

# CRUD
user = User.new(name: "Alice", email: "alice@example.com")
user.save
user = User.find(1)
user.delete

# Relationships
orders = user.has_many("Order", "user_id")
profile = user.has_one("Profile", "user_id")

# Soft delete, scopes, caching
user.soft_delete
active_admins = User.scope("active").scope("admin").select
users = User.cached("SELECT * FROM users", ttl: 300)

# Multi-database
Tina4.database = Tina4::Database.new("sqlite://app.db")           # Default
Tina4.database("audit", Tina4::Database.new("sqlite://audit.db")) # Named

class AuditLog < Tina4::ORM
  self.db_name = "audit"          # Uses named connection
end
```

### Database

Unified interface across 5 engines:

```ruby
db = Tina4::Database.new("sqlite://data/app.db")
db = Tina4::Database.new("postgres://localhost:5432/mydb", username: "user", password: "pass")
db = Tina4::Database.new("mysql://localhost:3306/mydb", username: "user", password: "pass")
db = Tina4::Database.new("mssql://localhost:1433/mydb", username: "sa", password: "pass")
db = Tina4::Database.new("firebird://localhost:3050/path/to/db", username: "SYSDBA", password: "masterkey")

result = db.fetch("SELECT * FROM users WHERE age > ?", [18], limit: 20, offset: 0)
row = db.fetch_one("SELECT * FROM users WHERE id = ?", [1])
db.insert("users", { name: "Alice", email: "alice@test.com" })
db.commit
```

### Middleware

```ruby
Tina4.before("/protected") do |request, response|
  unless request.headers["authorization"]
    return request, response.json({ error: "Unauthorized" }, 401)
  end
end

Tina4.get "/protected" do |request, response|
  response.json({ secret: true })
end
```

### JWT Authentication

```ruby
token = Tina4::Auth.get_token({ user_id: 42 })
result = Tina4::Auth.valid_token(token)
payload = Tina4::Auth.get_payload(token)
```

POST/PUT/PATCH/DELETE routes require `Authorization: Bearer <token>` by default. Use `auth: false` to make public, `secure_get` to protect GET routes.

### Sessions

```ruby
request.session["user_id"] = 42
user_id = request.session["user_id"]
```

Backends: file (default), Redis, MongoDB. Set via `TINA4_SESSION_HANDLER` in `.env`.

### Queues

```ruby
queue = Tina4::Queue.new(topic: "emails")
queue.produce("emails", { to: "alice@example.com" })

queue.consume("emails") { |msg| send_email(msg.payload) }
```

### GraphQL

```ruby
gql = Tina4::GraphQL.new
gql.schema.from_orm(User)
gql.register_route("/graphql")   # GET = GraphiQL IDE, POST = queries
```

### WebSocket

```ruby
ws = Tina4::WebSocketManager.new

ws.route "/ws/chat" do |connection, message|
  ws.broadcast("/ws/chat", "User said: #{message}")
end
```

### Swagger / OpenAPI

Auto-generated at `/swagger`:

```ruby
Tina4.get "/api/users", swagger_meta: {
  summary: "Get all users",
  tags: ["users"]
} do |request, response|
  response.json(User.all.map(&:to_hash))
end
```

### Event System

```ruby
Tina4.on("user.created", priority: 10) do |user|
  send_notification("New user: #{user[:name]}")
end

Tina4.emit("user.created", { name: "Alice" })
```

### Template Engine (Frond)

Twig-compatible, 35+ filters, macros, inheritance, fragment caching, sandboxing:

```twig
{% extends "base.twig" %}
{% block content %}
<h1>{{ title | upper }}</h1>
{% for item in items %}
    <p>{{ item.name }} -- {{ item.price | number_format(2) }}</p>
{% endfor %}

{% cache "sidebar" 300 %}
    {% include "partials/sidebar.twig" %}
{% endcache %}
{% endblock %}
```

### CRUD Scaffolding

```ruby
Tina4.get "/admin/users" do |request, response|
  response.json(Tina4::CRUD.to_crud(request, {
    sql: "SELECT id, name, email FROM users",
    title: "User Management",
    primary_key: "id"
  }))
end
```

### REST Client

```ruby
api = Tina4::API.new("https://api.example.com", headers: {
  "Authorization" => "Bearer xyz"
})
result = api.get("/users/42")
```

### Data Seeder

```ruby
fake = Tina4::FakeData.new
fake.name      # "Alice Johnson"
fake.email     # "alice.johnson@example.com"

Tina4.seed_orm(User, count: 50)
```

### Email / Messenger

```ruby
mail = Tina4::Messenger.new
mail.send(to: "user@test.com", subject: "Welcome", body: "<h1>Hi!</h1>", html: true)
```

### In-Memory Cache

```ruby
cache = Tina4::Cache.new
cache.set("key", "value", ttl: 300)
cache.tag("users").flush
```

### SCSS, Localization, Inline Testing

- **SCSS**: Drop `.scss` in `src/scss/` -- auto-compiled to CSS. Variables, nesting, mixins, `@import`, `@extend`.
- **i18n**: JSON translation files, 6 languages (en, fr, af, zh, ja, es), placeholder interpolation.
- **Inline tests**: `test_method :add, assert_equal: [[5, 3], 8]` on any method.

---

## Dev Mode

Set `TINA4_DEBUG=true` in `.env` to enable:

- **Live reload** -- browser auto-refreshes on code changes
- **CSS hot-reload** -- SCSS changes apply without page refresh
- **Error overlay** -- rich error display in the browser
- **Dev admin** at `/__dev/` with tabs: Routes, Queue, Mailbox, Messages, Database, Requests, Errors, WebSocket, System, Tools, Tina4

---

## CLI Reference

```bash
tina4ruby init [dir]             # Scaffold a new project
tina4ruby serve [port]           # Start dev server (default: 7147)
tina4ruby serve --production     # Auto-install and use Puma production server
tina4ruby migrate                # Run pending migrations
tina4ruby migrate --create <desc># Create a migration file
tina4ruby migrate --rollback     # Rollback last batch
tina4ruby generate model <name>  # Generate ORM model scaffold
tina4ruby generate route <name>  # Generate route scaffold
tina4ruby generate migration <d> # Generate migration file
tina4ruby generate middleware <n># Generate middleware scaffold
tina4ruby seed                   # Run seeders from src/seeds/
tina4ruby routes                 # List all registered routes
tina4ruby test                   # Run test suite
tina4ruby build                  # Build distributable gem
tina4ruby ai [--all]             # Detect AI tools and install context
```

### Production Server Auto-Detection

`tina4 serve` automatically detects and uses the best available production server:

- **Ruby**: Puma (if installed), otherwise WEBrick -- Puma gives 2.8x improvement
- Use `tina4ruby serve --production` to auto-install Puma

### Scaffolding with `tina4 generate`

Quickly scaffold new components:

```bash
tina4ruby generate model User          # Creates src/orm/user.rb with field stubs
tina4ruby generate route users         # Creates src/routes/users.rb with CRUD stubs
tina4ruby generate migration "add age" # Creates migration SQL file
tina4ruby generate middleware AuthLog   # Creates middleware class
```

### ORM Relationships & Eager Loading

```ruby
# Relationships
orders = user.has_many("Order", "user_id")
profile = user.has_one("Profile", "user_id")
customer = order.belongs_to("Customer", "customer_id")

# Eager loading with include:
users = User.all(include: ["orders", "profile"])
```

### DB Query Caching

Enable query caching for up to 4x speedup on read-heavy workloads:

```bash
# .env
TINA4_DB_CACHE=true
```

### Frond Pre-Compilation

Templates are pre-compiled for 2.8x faster rendering.

### Gallery

7 interactive examples with **Try It** deploy.

## Environment

```bash
SECRET=your-jwt-secret
DATABASE_URL=sqlite://data/app.db
DATABASE_USERNAME=
DATABASE_PASSWORD=
TINA4_DEBUG=true                     # Enable dev toolbar, error overlay
TINA4_LOG_LEVEL=ALL                  # ALL, DEBUG, INFO, WARNING, ERROR
TINA4_LOCALE=en                    # en, fr, af, zh, ja, es
TINA4_SESSION_HANDLER=SessionFileHandler
SWAGGER_TITLE=My API
```

## Carbonah Green Benchmarks

All 9 benchmarks rated **A+** (South Africa grid, 1000 iterations each):

| Benchmark | SCI (gCO2eq) | Grade |
|-----------|-------------|-------|
| JSON Hello World | 0.000897 | A+ |
| Single DB Query | 0.000561 | A+ |
| Multiple DB Queries | 0.001402 | A+ |
| Template Rendering | 0.003351 | A+ |
| Large JSON Payload | 0.001019 | A+ |
| Plaintext Response | 0.000391 | A+ |
| CRUD Cycle | 0.000473 | A+ |
| Paginated Query | 0.001027 | A+ |
| Framework Startup | 0.00267 | A+ |

Startup: 37ms | Memory: 34.9MB | SCI: 0.00267

Run locally: `ruby benchmarks/run_carbonah.rb`

---

## Documentation

Full guides, API reference, and examples at **[tina4.com](https://tina4.com)**.

## License

MIT (c) 2007-2026 Tina4 Stack
https://opensource.org/licenses/MIT

---

<p align="center"><b>Tina4</b> -- The framework that keeps out of the way of your coding.</p>

---

## Our Sponsors

**Sponsored with 🩵 by Code Infinity**

[<img src="https://codeinfinity.co.za/wp-content/uploads/2025/09/c8e-logo-github.png" alt="Code Infinity" width="100">](https://codeinfinity.co.za/about-open-source-policy?utm_source=github&utm_medium=website&utm_campaign=opensource_campaign&utm_id=opensource)

*Supporting open source communities <span style="color: #1DC7DE;">•</span> Innovate <span style="color: #1DC7DE;">•</span> Code <span style="color: #1DC7DE;">•</span> Empower*
