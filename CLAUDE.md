# Tina4 Ruby

Lightweight Ruby web framework. See https://tina4.com for full documentation.

## Build & Test

- Ruby: >=3.1.0 (homebrew: `/opt/homebrew/opt/ruby/bin/ruby`)
- Install: `bundle install`
- Run all tests: `bundle exec rspec`
- Run single test: `bundle exec rspec spec/file_spec.rb:LINE`
- Start server: `ruby app.rb` or `tina4ruby` CLI (default host: 0.0.0.0, default port: 7147)
- CLI: `tina4ruby` (Thor-based, exe in `exe/tina4ruby`)

## Code Principles

- **DRY** — Never duplicate logic. Centralise shared code in helper modules, template partials, or base classes. If a pattern exists anywhere, use it everywhere
- **Separation of Concerns** — One route resource per file in `routes/`, one ORM model per file in `orm/`, shared helpers in `app/`
- **No inline styles** on any element — use tina4-css classes (e.g. `.form-input`, `.form-control`) or SCSS in `scss/`
- **No hardcoded hex colors** — always use CSS variables (`var(--text)`, `var(--border)`, `var(--primary)`, etc.) or SCSS variables
- **Shared CSS only** — Never define UI patterns in local `<style>` blocks. All shared styles go in a project SCSS file
- **Use built-in features** — Never reinvent what the framework provides (Queue, Api, Auth, ORM, etc.)
- **Template inheritance** — Every page extends a base template, reusable UI in partials
- **Migrations for all schema changes** — Never execute DDL outside migration files
- **Constants** — No magic strings or numbers in routes. Put constants in a dedicated constants module
- **Service layer pattern** — For complex business logic, create service classes in `app/`. Routes should be thin wrappers
- **Error handling in routes** — Wrap route logic in `begin/rescue`, log with `Tina4::Log.error()`, return response with appropriate status
- **All links and references** should point to https://tina4.com
- **Push to staging only** — Never push to production without explicit approval
- Linting: `rubocop`

## Development Mode (DevReload)

Start with `--dev` flag to enable development features:

```bash
tina4ruby serve --dev
```

Or set `TINA4_DEBUG=true` in `.env`:

- **Auto-reload** — File watcher detects changes to `.rb`, `.twig`, `.html`, `.erb` files and reloads
- **SCSS auto-compile** — `.scss` changes compiled automatically
- **Verbose logging** — Full debug output to console and `logs/debug.log`

DevReload watches routes, templates, and scss directories via the `listen` gem.

## Project Structure

```
lib/
  tina4.rb             # Main require file
  tina4/               # Core framework modules
    router.rb, orm.rb, database.rb, seeder.rb,
    migration.rb, template.rb, swagger.rb, webserver.rb,
    queue.rb, session.rb, graphql.rb, wsdl.rb, crud.rb,
    websocket.rb, localization.rb, middleware.rb, cli.rb,
    auth.rb, field_types.rb, rack_app.rb, scss_compiler.rb,
    dev_reload.rb, log.rb, debug.rb (compat alias), env.rb,
    api.rb, version.rb,
    events.rb,          # Observer pattern event system
    ai.rb,              # AI coding-tool detection & context scaffolding
    response_cache.rb,  # In-memory GET response cache with TTL
    container.rb,       # Lightweight DI container
    constants.rb,       # HTTP status codes & content types
    cors.rb,            # CORS middleware
    dev_admin.rb,       # Dev toolbar dashboard (debug mode)
    dev_mailbox.rb,     # Dev mailbox for email capture
    error_overlay.rb,   # Rich HTML error overlay (dev mode)
    frond.rb,           # Frontend asset helper
    health.rb,          # Health check endpoint
    html_element.rb,    # Programmatic HTML builder & helpers
    messenger.rb,       # Messaging abstraction
    rate_limiter.rb,    # Rate limiting middleware
    request.rb,         # Request wrapper
    response.rb,        # Response wrapper
    service_runner.rb,  # Background service runner
    shutdown.rb,        # Graceful shutdown handler
    testing.rb,         # Inline test framework (describe/it)
    sql_translation.rb  # Cross-engine SQL translator & query cache
    drivers/            # Database drivers (sqlite, postgres, mysql, mssql, firebird)
    queue_backends/     # Queue backends (lite, rabbitmq, kafka)
    session_handlers/   # Session storage (file, redis, mongo)
    templates/          # Built-in framework templates
    public/             # Built-in static assets
    scss/               # Built-in SCSS
exe/
  tina4ruby            # CLI executable
spec/                  # RSpec test files
```

## Key Method Stubs

### Router — Route registration

```ruby
# Convenience methods (delegated to Tina4::Router)
Tina4.get(path, swagger_meta: {}, &handler)
Tina4.post(path, swagger_meta: {}, &handler)
Tina4.put(path, swagger_meta: {}, &handler)
Tina4.patch(path, swagger_meta: {}, &handler)
Tina4.delete(path, swagger_meta: {}, &handler)
Tina4.any(path, swagger_meta: {}, &handler)
Tina4.secure_get(path, &handler)
Tina4.secure_post(path, &handler)
Tina4.group(prefix, auth_handler: nil, &block)

# Direct Router class methods (preferred in v3)
Tina4::Router.get(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.post(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.put(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.patch(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.delete(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.any(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.add_route(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [], template: nil)
Tina4::Router.find_route(path, method)
Tina4::Router.group(prefix, auth_handler: nil, middleware: [], &block)
Tina4::Router.clear!
Tina4::Router.routes

# Route params use {id} syntax (NOT :id). Matches Python exactly.
# Type hints: {id:int}, {amount:float}, {slug:path}
# Catch-all splat: *path
# Handler receives |request, response| block params
# template: keyword renders a Twig template with the response data

# Template rendering on a route:
Tina4::Router.get "/dashboard", template: "dashboard.twig" do |request, response|
  response.call({ title: "Dashboard", items: items }, Tina4::HTTP_OK)
end
```

### WebServer — Starting the server

```ruby
# Default host: 0.0.0.0, default port: 7147
app = Tina4::RackApp.new
Tina4::WebServer.new(app, host: "0.0.0.0", port: 7147).start
```

### Database — Multi-driver abstraction

```ruby
# v3 connection string format: driver://host:port/database
# Supported drivers: sqlite, postgres, mysql, mssql, firebird
# Driver aliases: sqlite3 -> sqlite, postgresql -> postgres, sqlserver -> mssql
db = Tina4::Database.new("sqlite://path/to/database.db")
db = Tina4::Database.new("postgres://localhost:5432/mydb", username: "user", password: "pass")
db = Tina4::Database.new("mysql://localhost:3306/mydb", username: "root", password: "secret")
db = Tina4::Database.new("mssql://localhost:1433/mydb", username: "sa", password: "pass")
db = Tina4::Database.new("firebird://localhost:3050/mydb", username: "sysdba", password: "pass")

# Or via environment variables:
# DATABASE_URL=postgres://localhost:5432/mydb
# DATABASE_USERNAME=user
# DATABASE_PASSWORD=pass
db = Tina4::Database.new  # reads from ENV

db.fetch(sql, params = [], limit: nil, offset: nil) -> DatabaseResult
db.fetch_one(sql, params = []) -> Hash | nil
db.execute(sql, params = []) -> DatabaseResult
db.insert(table, data) -> DatabaseResult
db.update(table, data, filter = {}) -> DatabaseResult
db.delete(table, filter = {}) -> DatabaseResult
db.transaction { |db| yield }
db.tables -> Array
db.columns(table_name) -> Array
db.table_exists?(table_name) -> Boolean
db.close
```

### ORM — Active Record base class

```ruby
class MyModel < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

model = MyModel.new(attributes = {})
model.save -> Boolean
model.delete -> Boolean
model.load(id = nil) -> Boolean
model.persisted? -> Boolean
model.to_h -> Hash              # Ruby idiom (alias: to_hash)
model.to_json -> String

MyModel.find(id) -> MyModel | nil
MyModel.where(conditions, params = []) -> Array
MyModel.all(limit: nil, offset: nil, order_by: nil) -> Array
MyModel.count(conditions = nil, params = []) -> Integer
MyModel.create(attributes = {}) -> MyModel
```

### Template — ERB/Twig engine

```ruby
Tina4::Template.render(template_path, data = {}) -> String
Tina4::Template.add_global(key, value)
Tina4::Template.globals -> Hash
Tina4::Template.render_error(code) -> String
```

### FakeData — Fake data generation

```ruby
fake = Tina4::FakeData.new(seed: nil)
fake.name -> String
fake.email(from_name: nil) -> String
fake.phone -> String
fake.sentence(words: 6) -> String
fake.integer(min: 0, max: 10_000) -> Integer
fake.numeric(min: 0.0, max: 1000.0, decimals: 2) -> Float
fake.datetime(start_year: 2020, end_year: 2026) -> Time
fake.for_field(field_def, column_name = nil) -> Object

Tina4.seed_orm(orm_class, count: 10, overrides: {}, clear: false, seed: nil) -> Integer
Tina4.seed_table(table_name, columns, count: 10, overrides: {}, clear: false, seed: nil) -> Integer
Tina4.seed(seed_folder: "seeds", clear: false)
```

### Migration

```ruby
migration = Tina4::Migration.new(db, migrations_dir: nil)
migration.run
migration.rollback(steps = 1)
migration.status -> Array
migration.create(name) -> String
```

### Auth — JWT authentication & password hashing

```ruby
Tina4::Auth.setup(root_dir = Dir.pwd)
Tina4::Auth.get_token(payload, expires_in: 60) -> String
Tina4::Auth.valid_token(token) -> Hash | nil
Tina4::Auth.get_payload(token) -> Hash | nil
Tina4::Auth.refresh_token(token, expires_in: 60) -> String | nil
Tina4::Auth.authenticate_request(headers) -> Hash | nil
Tina4::Auth.hash_password(password) -> String
Tina4::Auth.check_password(password, hash) -> Boolean
Tina4::Auth.validate_api_key(provided, expected: nil) -> Boolean
Tina4::Auth.bearer_auth -> Lambda
Tina4::Auth.private_key -> OpenSSL::PKey::RSA
Tina4::Auth.public_key -> OpenSSL::PKey::RSA
```

### Log — Logging

```ruby
Tina4::Log.info(message, *args)
Tina4::Log.debug(message, *args)
Tina4::Log.warning(message, *args)
Tina4::Log.error(message, *args)
# Controlled by TINA4_LOG_LEVEL env var: [TINA4_LOG_ALL], [TINA4_LOG_DEBUG], [TINA4_LOG_INFO], etc.
# Tina4::Debug is a backward-compat alias for Tina4::Log
```

### Events — Observer pattern

```ruby
# Register a listener (higher priority runs first)
Tina4::Events.on("user.created", priority: 0) { |user| puts user[:name] }

# One-time listener (auto-removes after first fire)
Tina4::Events.once("app.ready") { puts "Started!" }

# Fire an event — returns array of listener results
results = Tina4::Events.emit("user.created", { name: "Alice" })

# Remove a specific listener or all listeners for an event
handler = Tina4::Events.on("evt") { }
Tina4::Events.off("evt", handler)   # remove specific
Tina4::Events.off("evt")            # remove all for event

# Introspection
Tina4::Events.listeners("evt")      # -> Array of callbacks (priority order)
Tina4::Events.events                 # -> Array of registered event names
Tina4::Events.clear                  # remove all listeners for all events
```

### AI — AI tool detection & context scaffolding

```ruby
# Detect AI coding tools present in a project directory
tools = Tina4::AI.detect_ai("/path/to/project")
# -> [{ name: "claude-code", description: "Claude Code (Anthropic CLI)",
#        config_file: "CLAUDE.md", status: "detected" }, ...]

names = Tina4::AI.detect_ai_names("/path/to/project")  # -> ["claude-code", "cursor"]

# Install Tina4 context files for detected tools (or specific ones)
files = Tina4::AI.install_ai_context(".", tools: ["claude-code"], force: false)

# Install context for ALL known AI tools
files = Tina4::AI.install_all(".", force: true)

# Human-readable status report
puts Tina4::AI.status_report(".")
```

Supported tools: claude-code, cursor, copilot, windsurf, aider, cline, codex.

### ResponseCache — In-memory GET response cache

```ruby
cache = Tina4::ResponseCache.new(ttl: 60, max_entries: 1000, status_codes: [200])

cache.enabled?                              # -> Boolean (ttl > 0)
cache.cache_response("GET", "/api/users", 200, "application/json", body)
hit = cache.get("GET", "/api/users")        # -> CacheEntry | nil
  # hit.body, hit.content_type, hit.status_code, hit.expires_at

cache.cache_stats                           # -> { size: N, keys: [...] }
cache.sweep                                 # evict expired entries, returns count
cache.clear_cache                           # remove all entries

# Environment: TINA4_CACHE_TTL sets default TTL (0 = disabled)
```

### Container — Dependency injection

```ruby
# Register a concrete instance
Tina4::Container.register(:mailer, MailService.new)

# Register a lazy factory (called once, memoized)
Tina4::Container.register(:db) { Tina4::Database.new(ENV["DB_URL"]) }

# Resolve a service (raises KeyError if not registered)
db = Tina4::Container.resolve(:db)

Tina4::Container.registered?(:mailer)  # -> Boolean
Tina4::Container.clear!                # remove all (useful in tests)
```

### ErrorOverlay — Rich HTML error page (dev mode)

```ruby
# Render a rich, syntax-highlighted HTML error page (Catppuccin Mocha theme)
html = Tina4::ErrorOverlay.render(exception, request: rack_env)

# Render a safe, generic error page for production
html = Tina4::ErrorOverlay.render_production(status_code: 500, message: "Internal Server Error")

# Check if the overlay should be shown (TINA4_DEBUG = true)
Tina4::ErrorOverlay.debug_mode?  # -> Boolean
```

### HtmlElement — Programmatic HTML builder

```ruby
# Direct construction
el = Tina4::HtmlElement.new("div", { class: "card" }, ["Hello"])
el.to_s  # => '<div class="card">Hello</div>'

# Builder pattern via call (returns new element)
el = Tina4::HtmlElement.new("div").call(
  { class: "card" },
  Tina4::HtmlElement.new("p").call("Text")
)

# HtmlHelpers — _div, _p, _span, _a, _form, etc. for every HTML tag
include Tina4::HtmlHelpers
html = _div({ class: "card" }, _p("Hello"), _a({ href: "/" }, "Home"))
html.to_s
```

### Testing — Inline test framework

```ruby
Tina4::Testing.describe "Widget API" do
  before_each { }
  after_each  { }

  it "returns 200 for GET /api/widgets" do
    status, headers, body = get("/api/widgets")
    assert_status([status, headers, body], 200)
  end

  it "creates a widget" do
    status, _, body = post("/api/widgets", body: { name: "Bolt" })
    assert_equal(201, status)
    data = assert_json(body.first)
    assert_not_nil(data["id"])
  end
end

Tina4::Testing.run_all   # execute all suites, print results
Tina4::Testing.reset!    # clear all suites and results

# Assertions: assert, assert_equal, assert_not_equal, assert_nil,
#   assert_not_nil, assert_includes, assert_raises, assert_match,
#   assert_json, assert_status
# HTTP helpers: get, post, put, delete, simulate_request
```

### SQLTranslator — Cross-engine SQL translation

```ruby
# LIMIT/OFFSET -> Firebird ROWS...TO
Tina4::SQLTranslator.limit_to_rows("SELECT * FROM t LIMIT 10 OFFSET 5")
# => "SELECT * FROM t ROWS 6 TO 15"

# LIMIT -> MSSQL TOP
Tina4::SQLTranslator.limit_to_top("SELECT * FROM t LIMIT 10")
# => "SELECT TOP 10 * FROM t"

# || concatenation -> CONCAT()
Tina4::SQLTranslator.concat_pipes_to_func("a || b || c")
# => "CONCAT(a, b, c)"

Tina4::SQLTranslator.boolean_to_int("WHERE active = TRUE")    # TRUE->1, FALSE->0
Tina4::SQLTranslator.ilike_to_like("name ILIKE ?")            # -> LOWER() LIKE LOWER()
Tina4::SQLTranslator.auto_increment_syntax(ddl, "postgresql") # AUTOINCREMENT -> SERIAL
Tina4::SQLTranslator.placeholder_style("? AND ?", ":")        # -> :1 AND :2
Tina4::SQLTranslator.query_key("SELECT 1", [42])              # SHA256 cache key

# QueryCache — in-memory TTL cache for query results
cache = Tina4::QueryCache.new(default_ttl: 300, max_size: 1000)
cache.set("key", value, ttl: 60, tags: ["users"])
cache.get("key")
cache.has?("key")
cache.delete("key")
cache.clear_tag("users")    # invalidate all entries tagged "users"
cache.sweep                  # evict expired entries
cache.remember("key", 60) { expensive_query() }  # fetch-or-compute
cache.size
cache.clear
```

### DevAdmin — Dev toolbar & dashboard

The dev toolbar is automatically available in debug mode (`TINA4_DEBUG=true`).

```ruby
Tina4::DevAdmin.enabled?             # -> Boolean (true in debug mode)
Tina4::DevAdmin.message_log          # -> MessageLog instance
Tina4::DevAdmin.request_inspector    # -> RequestInspector instance
Tina4::DevAdmin.mailbox              # -> DevMailbox instance (email capture)

# MessageLog — in-memory message log (last 500 entries)
Tina4::DevAdmin.message_log.log(category, level, message)
Tina4::DevAdmin.message_log.get(category: nil)
Tina4::DevAdmin.message_log.clear(category: nil)
Tina4::DevAdmin.message_log.count

# RequestInspector — captured HTTP requests (last 200)
Tina4::DevAdmin.request_inspector.capture(method:, path:, status:, duration:)
Tina4::DevAdmin.request_inspector.get(limit: 50)
Tina4::DevAdmin.request_inspector.stats  # -> { total:, avg_ms:, errors:, slowest_ms: }
Tina4::DevAdmin.request_inspector.clear
```

## Key Architecture

- Rack 3-based web server with Puma (falls back to WEBrick)
- Routes auto-discovered from `routes/`
- ORM uses DSL methods (`integer_field`, `string_field`) with `FieldTypes` module
- Templates use ERB and Twig (custom engine)
- CLI (Thor): `tina4ruby serve` (--dev, --port), `tina4ruby seed` (--clear), `tina4ruby seed_create NAME`, `tina4ruby migrate`, `tina4ruby ai` (--all)
- SCSS compilation built-in
- JWT auth via `jwt` gem
- Password hashing via `bcrypt`
- File watching via `listen`
- Event system (observer pattern) for decoupled module communication
- DI container with lazy factories and memoization
- In-memory response cache (GET only, TTL-based, thread-safe)
- Cross-engine SQL translator (Firebird ROWS, MSSQL TOP, CONCAT, boolean, ILIKE, placeholders)
- Query cache with TTL, tagging, and `remember` pattern
- AI coding-tool detection and context file scaffolding (7 tools supported)
- Rich HTML error overlay in dev mode (Catppuccin Mocha theme, source context)
- Programmatic HTML builder with tag helper methods (`_div`, `_p`, etc.)
- Inline testing framework (`describe`/`it` with HTTP simulation and assertions)
- Dev toolbar dashboard with request inspector, message log, and dev mailbox (debug mode)
- Rate limiting middleware
- CORS middleware
- Graceful shutdown handling
- Health check endpoint
- HTTP status code constants (`Tina4::HTTP_OK`, `Tina4::HTTP_NOT_FOUND`, etc.)
- Default host: 0.0.0.0, default port: 7147
- Messenger (.env driven SMTP/IMAP)
- CLI scaffolding: `tina4ruby generate model/route/migration/middleware`
- Production server auto-detect: `tina4ruby serve --production` (auto-installs Puma, 2.8x improvement)
- Frond pre-compilation for 2.8x template render improvement
- DB query caching: `TINA4_DB_CACHE=true` env var, `cache_stats`, `cache_clear`
- ORM relationships: `has_many`, `has_one`, `belongs_to` with eager loading (`include:`)
- Queue backends: SQLite (default), RabbitMQ, Kafka, MongoDB
- Cache backends: memory (default), Redis, file
- Session handlers: file, Redis, MongoDB
- Gallery: 7 interactive examples with Try It deploy at `/__dev/`
- Tests: 1,577 passing (38 features)
- Version: 3.0.0

## Links

- Website: https://tina4.com
- GitHub: https://github.com/tina4stack/tina4-ruby

## Skills

- **tina4-maintainer** — Always read and follow `.claude/skills/tina4-maintainer/SKILL.md` when working on this codebase. Read its referenced files in `.claude/skills/tina4-maintainer/references/` as needed for specific subsystems.
- **tina4-developer** — Always read and follow `.claude/skills/tina4-developer/SKILL.md` when building applications with this framework. Read its referenced files in `.claude/skills/tina4-developer/references/` as needed.
- **tina4-js** — Always read and follow `.claude/skills/tina4-js/SKILL.md` when working with tina4-js frontend code. Read its referenced files in `.claude/skills/tina4-js/references/` as needed.
