# Tina4 Ruby

Version 3.13.84 - TINA4: The Intelligent Native Application 4ramework. Simple. Fast. Human. Built for AI. Built for you. See https://tina4.com for full documentation.

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
- **Parity across all frameworks** — Every new feature, fix, or optimization must be implemented with equivalent logic AND tests in all 4 Tina4 frameworks (Python, PHP, Ruby, Node.js). Never ship to one without shipping to all.
- **NO mock testing. Mocks are not acceptable in any circumstances.** A test double (mock, stub, fake, spy, monkeypatch, RSpec double/instance_double, or any in-test object standing in for a real collaborator) may never substitute for a real dependency, under any justification. There is no "supplement" exception and no "hard to reproduce" exception. Any test that touches a dependency (a DB engine, MongoDB, Redis/Valkey/Memcached, RabbitMQ/Kafka, an HTTP/SMTP service, the filesystem, a socket) must exercise the REAL service; if a failure mode is hard to trigger, reproduce it for real, never simulate it. "Verified"/"green" requires a real run; a passing mock test is not verification. CI provisions the services; use them and add any that is missing. The only tests that need no live dependency are pure functions with no dependency and no double; that is not a mock test. (The Node MongoDB queue re-delivered every completed job for two releases because its queue tests were mock-based and never ran against a real Mongo.)
- **Error handling in routes** — Wrap route logic in `begin/rescue`, log with `Tina4::Log.error()`, return response with appropriate status
- **All links and references** should point to https://tina4.com
- **Push to staging only** — Never push to production without explicit approval
- Linting: `rubocop`

## Development Mode (DevReload)

Set `TINA4_DEBUG=true` in `.env` to enable development features:

- **Auto-reload** — Browser auto-refreshes when `.rb`, `.twig`, `.html`, `.erb` files change
- **SCSS auto-compile** — `.scss` changes compiled to `src/public/css/`
- **Verbose logging** — Full debug output to console and `logs/debug.log`

### How DevReload works (WebSocket-primary)

DevReload is **WebSocket-primary** — the reload is instant, not polled. The `tina4` Rust CLI is the sole file watcher for the Tina4 stack (there is no framework-side watcher; the `listen`-gem based `dev_reload.rb` was removed in 3.11.x). The flow is:

1. `tina4 serve` (Rust CLI) watches `src/`, `migrations/`, `.env`. Noise is filtered (Access/Metadata events, `__pycache__`, `.git`, `node_modules`, `logs`, `.log`/`.db*`/`.swp` files) and a real mtime check defeats overlayfs spurious events. On a real change the CLI POSTs `/__dev/api/reload` to the **running** server — it does **not** restart the worker process.
2. The server re-runs route discovery (`Tina4::Router.rescan_routes!`) — registering new `src/routes/` files and re-loading changed ones **in-process** (mtime-tracked, routes dir only; framework files never), so the worker keeps the same PID — then bumps its `@reload_mtime` counter.
3. The server **broadcasts** a JSON message `{type, file, mtime}` to every browser connected on the `/__dev_reload` WebSocket (`type` is `"css"` for stylesheet changes, else `"reload"`). The injected dev-toolbar client and the dev-admin dashboard both connect here and act on it instantly: CSS changes swap `<link rel=stylesheet>` hrefs with a cache-bust query; everything else does a full page reload.
4. **Poll is fallback only.** The injected toolbar client stops polling the moment the socket connects, and only restarts the `GET /__dev/api/mtime` poll (every 3 s) when the socket drops — reconnecting after ~2 s. The poll seeds its last-seen mtime to a null sentinel (not 0) and reloads whenever the polled mtime *differs* (not just when greater), so the first change after load isn't swallowed and a counter reset on restart still triggers. In normal operation there is no polling.

The `/__dev_reload` WebSocket route is registered automatically when `TINA4_DEBUG=true` (`Tina4::RackApp.register_dev_reload_ws`), held open by the process-wide `Tina4::DevReload` manager so a single broadcast reaches every browser. WebSocket upgrades require a hijack-capable server (Puma); under WEBrick (the bare-`ruby app.rb` default) the upgrade is rejected and the client uses the poll fallback. The reload client is suppressed on the stable AI port. Running without the Rust CLI (e.g. Docker, `TINA4_OVERRIDE_CLIENT=true`) means no automatic reload.

### Route hot-reload (changed files re-load — no restart)

`rescan_routes!` is mtime-tracked: it walks the route files under the discovered routes/`src` directory and `load`s a file when it is **new** OR its **mtime has increased** since the last scan; unchanged files are skipped. Ruby's `load` re-executes the file, so editing an existing route file re-runs its `Tina4::Router.get`/`.post`/… calls — and `Router.add` now **replaces** a re-registered `(method, path)` in place rather than appending, so the fresh handler wins instead of being shadowed by the stale one. New route files register the same way. The scope is the routes/`src` directory only — framework files are never re-loaded.

Honest caveat: cross-module references captured earlier (e.g. an ORM class identity, or a symbol imported by name into another *unchanged* file) keep the old reference until that other file is itself touched. The edited route file re-loads, but a separate module that grabbed the old reference still holds it.

## Project Structure

```
lib/
  tina4.rb             # Main require file
  tina4/               # Core framework modules
    router.rb, orm.rb, database.rb, seeder.rb,
    migration.rb, template.rb, swagger.rb, webserver.rb,
    queue.rb, session.rb, graphql.rb, wsdl.rb, crud.rb,
    websocket.rb,        # WebSocket with backplane support localization.rb, middleware.rb, cli.rb,
    auth.rb, field_types.rb, rack_app.rb, scss_compiler.rb,
    log.rb, debug.rb (compat alias), env.rb,
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
    test_client.rb,     # In-process HTTP test client (dispatches through RackApp)
    validator.rb,       # Request body validator (Tina4::Validator)
    cache.rb,           # QueryCache — in-memory TTL/tagged query result cache
    sql_translator.rb   # Cross-engine SQL translator (dialects + cache KEY only)
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
Tina4.secure_get(path, auth: nil, swagger_meta: {}, &handler)
Tina4.secure_post(path, auth: nil, swagger_meta: {}, &handler)
Tina4.websocket(path, secure: false, &handler)        # WS route — PUBLIC by default (mirrors GET)
Tina4.secure_websocket(path, &handler)                # WS route requiring a valid JWT on the upgrade
Tina4.group(prefix, auth_handler: nil, &block)

# Direct Router class methods (preferred in v3)
Tina4::Router.get(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.post(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.put(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.patch(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.delete(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.any(path, middleware: [], swagger_meta: {}, template: nil, &block)
Tina4::Router.add(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [], template: nil)
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
# TINA4_DATABASE_URL=postgres://localhost:5432/mydb
# TINA4_DATABASE_USERNAME=user
# TINA4_DATABASE_PASSWORD=pass
db = Tina4::Database.new  # reads from ENV

db.fetch(sql, params = [], limit: nil, offset: nil) -> DatabaseResult
# A DatabaseResult auto-serializes to a JSON array when returned from a route
# via response.json(...) / response.call(...).
# FAILS LOUD: a SQL error (bad SQL, missing table/column) RAISES — it never
# silently returns an empty result. The cause is captured on db.get_error
# before the re-raise. A failed read is never written into the query cache.
db.fetch_one(sql, params = []) -> Hash | nil
    # FAILS LOUD too: a SQL error RAISES and populates db.get_error (it does not
    # return nil/"no row" on a bad query). Mirrors fetch/execute and the Python
    # master. A SUCCESSFUL "no matching row" still returns nil.
db.execute(sql, params = []) -> true | DatabaseResult  # RAISES on SQL error (never returns false)
    # FAILS LOUD: a SQL error (bad SQL, constraint violation, dead/aborted
    # connection) RAISES — it never silently returns false. The cause is still
    # readable via db.get_error after the raise. Mirrors fetch/fetch_one and the
    # Python master. On success returns true (or a DatabaseResult for
    # RETURNING/CALL/EXEC/SELECT) — always truthy. Wrap writes in begin/rescue
    # instead of testing the return value.
db.insert(table, data) -> DatabaseResult
db.update(table, data, filter = {}) -> DatabaseResult
db.delete(table, filter = {}) -> DatabaseResult
db.transaction { |db| yield }
db.tables -> Array
db.columns(table_name) -> Array
db.table_exists?(table_name) -> Boolean
db.get_next_id(table, pk_column: "id", generator_name: nil) -> Integer
    # ATOMIC ID generation — N concurrent callers never get duplicate ids.
    # SQLite: single UPDATE ... RETURNING (lib >= 3.35; else UPDATE+SELECT)
    #   under a process-wide write lock — no read-increment-read race.
    # MySQL: UPDATE ... LAST_INSERT_ID(current_value+1) then SELECT
    #   LAST_INSERT_ID() on the SAME connection (per-connection, race-safe).
    # MSSQL: single UPDATE ... OUTPUT inserted.current_value.
    # PostgreSQL: auto-creates a sequence if missing, uses nextval() (atomic).
    # Firebird: uses GEN_ID generator (atomic). Seeding is atomic
    #   insert-if-absent from MAX(pk); raises on error (never falls back to 1).
db.start_transaction
db.commit    # RAISES on a failed commit (captures db.get_error) and RETAINS the
             # transaction pin so a follow-up rollback lands on the same
             # connection. The pin is released only on a successful commit.
db.rollback  # terminal cleanup — ALWAYS releases the pin (even after a failed
             # commit). A second start_transaction on the same thread warns and
             # is a guarded no-op (nested transactions are not supported).
db.close
```

**`tina4_sequences` table** — Auto-created by `get_next_id` on first use for SQLite, MySQL, and MSSQL. Stores the current sequence value per table. Do not modify this table manually.

### Database binding — connecting models to a database

```ruby
# (a) .env auto-default — NO call required.
#     If TINA4_DATABASE_URL is set, auto_discover_db binds it as the default
#     connection on boot, and all models use it automatically.

# (b) Override the default connection explicitly:
Tina4.bind_database(Tina4::Database.new("sqlite://app.db"))

# (c) Register a NAMED (secondary) connection and point a model at it:
Tina4.bind_database(
  Tina4::Database.new("postgres://localhost:5432/analytics", username: "u", password: "p"),
  name: :analytics
)

class Visit < Tina4::ORM
  self.db = :analytics    # symbol selects the named connection registered above
end

# Tina4.database (READER) returns the current default connection.
Tina4.database -> Tina4::Database
```

`Tina4.bind_database(db)` is the writer (the old `Tina4.database = db` writer was
removed in 3.13.19 — there is no alias). `Tina4.bind_database(db, name: :…)` registers
a named connection; a model selects it with `self.db = :…`. A missing named connection
raises a clear error.

### ORM — Active Record base class

```ruby
class MyModel < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

# Instance methods
model = MyModel.new(attributes = {})
# Constructor accepts a Hash, keyword args, OR a JSON object string:
#   MyModel.new(name: "Alice")           # kwargs
#   MyModel.new("name" => "Alice")       # Hash
#   MyModel.new('{"name": "Alice"}')     # JSON object string -> one record
# Passing an Array raises ArgumentError (a single-record constructor); map over
# the list to build many records.
model.save -> self | false            # Returns self on success (fluent), false on failure
model.delete -> Boolean               # Soft-delete if enabled, else hard delete
model.force_delete -> Boolean         # Hard delete (bypasses soft-delete)
model.restore -> Boolean              # Restore soft-deleted record
model.load(sql, params = [], include: nil) -> Boolean  # selectOne into self; true if found
model.validate -> Array[String]       # Validate fields; empty = valid
model.persisted? -> Boolean
model.to_h(include: nil) -> Hash      # Ruby idiom (aliases: to_hash, to_dict, to_object)
model.to_json(include: nil) -> String
model.to_array -> Array              # List of values
model.to_list -> Array               # Alias for to_array
# Relationships are declared at the class level (DSL); each generates a named accessor.
# class User < Tina4::ORM
#   has_one :profile, class_name: "Profile", foreign_key: "user_id"
#   has_many :posts, class_name: "Post", foreign_key: "user_id"
#   belongs_to :team, class_name: "Team", foreign_key: "team_id"
# end
# user.profile -> Profile | nil      # generated accessor (has_one)
# user.posts   -> Array[Post]        # generated accessor (has_many)
# user.team    -> Team | nil         # generated accessor (belongs_to)

# Class methods
MyModel.has_one(name, class_name: nil, foreign_key: nil)    # Declare 1:1 relationship
MyModel.has_many(name, class_name: nil, foreign_key: nil)   # Declare 1:many relationship
MyModel.belongs_to(name, class_name: nil, foreign_key: nil) # Declare many:1 relationship
MyModel.find(id) -> MyModel | nil
MyModel.find_or_fail(id) -> MyModel   # Find or raise error
MyModel.create(attributes = {}) -> MyModel
MyModel.where(conditions, params = [], limit: nil, offset: nil, order_by: nil, include: nil) -> Array
MyModel.all(limit: nil, offset: nil, order_by: nil, include: nil) -> Array
MyModel.count(conditions = nil, params = []) -> Integer
MyModel.select(sql, params = [], limit: nil, offset: nil, include: nil) -> Array
MyModel.select_one(sql, params = [], include: nil) -> MyModel | nil
MyModel.with_trashed(conditions = "1=1", params = [], limit: 20, offset: 0) -> Array
MyModel.create_table -> Boolean
MyModel.query -> QueryBuilder         # Fluent query builder
MyModel.scope(name, filter_sql, params = [])  # Register reusable query scope
MyModel.from_hash(hash) -> MyModel    # Create instance from DB row hash

# Relationship definitions (class level)
has_one :profile, class_name: "Profile", foreign_key: :user_id
has_many :posts, class_name: "Post", foreign_key: :user_id
belongs_to :company, class_name: "Company", foreign_key: :company_id

# Foreign key auto-wire DSL — one line wires BOTH sides
# foreign_key_field :user_id, references: User
# → declaring class gets: belongs_to :user (association name = column minus _id)
# → referenced class gets: has_many :<declaringClass.downcase>s (or related_name: override)
#   e.g. class Post → User.posts; matches Python's declaring-class-lowercased + "s"
foreign_key_field :user_id, references: User
foreign_key_field :category_id, references: Category, related_name: :blog_posts
```

NoSQL support: `to_mongo()` generates MongoDB query documents from the same fluent API.

### File Uploads

Multipart file uploads are available via `request.files` (hash keyed by field name). Each file is an **indifferent-access** hash — string and symbol keys both work (`file["content"]` and `file[:content]` are equivalent), matching the string-key access used by Python/PHP/Node:

```ruby
# request.files["avatar"] =>
{
  filename: "photo.png",
  type: "image/png",
  tempfile: <File>,          # Rack tempfile — for large-file streaming (.read)
  size: 102400,
  content: "<raw bytes>"     # raw file bytes (NOT base64) — parity with Python/PHP/Node
}
```

```ruby
post "/api/upload" do |request, response|
  file = request.files["avatar"]
  return response.json({ error: "No file" }, 400) unless file
  # Use file["content"] (raw bytes) for small files...
  File.binwrite("src/public/uploads/#{file["filename"]}", file["content"])
  # ...or stream the tempfile for large uploads:
  # IO.copy_stream(file[:tempfile], "src/public/uploads/#{file[:filename]}")
  response.json({ ok: true })
end
```

`file["content"]` is the raw bytes (the tempfile is read once and rewound, so `:tempfile` stays usable for streaming large files).

Max upload size: `TINA4_MAX_UPLOAD_SIZE` env var (default 10MB).

### Auth

```ruby
# expires_in is in MINUTES (default 60). Reads SECRET from env.
Tina4::Auth.get_token(payload, expires_in: 60) -> String
Tina4::Auth.valid_token(token) -> Hash | nil
Tina4::Auth.get_payload(token) -> Hash | nil
Tina4::Auth.refresh_token(token, expires_in: 60) -> String | nil
Tina4::Auth.hash_password(password, salt=nil, iterations=260000) -> String  # PBKDF2-SHA256, $ delimiter
Tina4::Auth.check_password(password, hash) -> Boolean  # timing-safe
Tina4::Auth.validate_api_key(provided, expected: nil) -> Boolean  # timing-safe, reads TINA4_API_KEY
Tina4::Auth.authenticate_request(headers) -> Hash | nil  # Bearer JWT, falls back to API key
Tina4::Auth.ensure_dev_secret(root_dir = Dir.pwd) -> String | nil  # boot-time fail-safe dev secret
```

**`TINA4_SECRET` and the fail-safe dev secret.** There is **no guessable
built-in default** for `TINA4_SECRET` — a blank secret is the signal for the
fail-safe bootstrap. At boot (after env load, before auth is used)
`Tina4::Auth.ensure_dev_secret` runs once:

- **Dev** (`TINA4_DEBUG` truthy, `CI` unset, `TINA4_ENV` != `production`) with a
  **blank** secret → it mints a cryptographically-random secret
  (`SecureRandom.hex(32)`, 64 hex chars), sets it in the process env for this
  run, and **appends** it to a gitignored `.env.local` (created if missing). On
  any write failure it keeps the in-memory secret and warns — it never crashes
  boot. Logs `INFO`: "generated a development secret, saved to .env.local
  (gitignored)".
- **CI or production** with a blank secret → it **never** generates and
  **never** writes. It emits the actionable warning: *"Set TINA4_SECRET to a
  random value (e.g. `openssl rand -hex 32`)"*.

`.env.local` is loaded as an **override** on top of `.env` at every boot (so the
generated dev secret is picked up on the next run) and is gitignored in both the
framework repo and the scaffolded-project `.gitignore` template.

### Session

```ruby
session.start(session_id = nil) -> String
session.get(key, default = nil)
session.set(key, value)
session.delete(key)
session.has?(key) -> Boolean
session.all -> Hash
session.clear
session.destroy
session.regenerate -> String           # Returns new session ID
session.flash(key, value = nil)        # Dual-mode: set with value, get+remove without
session.get_flash(key, default = nil)  # Explicit getter
session.save
session.cookie_header -> String
session.gc(max_age = nil)
```

Backends: file, redis, valkey, mongodb, database.

**Backend-failure policy (all 4 frameworks): log-loud + degrade.** A backend (Redis/Valkey/Mongo/DB) that becomes unreachable mid-request is logged via `Tina4::Log.error` and degraded rather than crashing the app or losing data silently: a read failure yields an empty session (the request still serves), and `save` returns `false` (best-effort, the modified flag retained for a later retry). A genuinely empty session (no data yet) is NOT an error and is never logged. Set `TINA4_SESSION_STRICT=true` to re-raise instead. Call `regenerate` right after a successful login or privilege change to defeat session fixation. (`authenticate_request`/`bearer_auth` route the API-key fast-path through the timing-safe `validate_api_key`, and the session no longer carries a guessable default secret.)

### Database extras

```ruby
db.execute(sql, params) -> true | result  # RAISES on SQL error (never false); true for writes, DatabaseResult for RETURNING/CALL/EXEC
    # On a SQL error execute RAISES (the cause is captured on db.get_error AND
    # re-raised) rather than returning false — callers should use begin/rescue,
    # not a return-value test. Parity with fetch/fetch_one and the Python master.
db.get_last_id -> Integer | nil
db.get_error -> String | nil  # cause of the last execute/fetch error (set before the raise)
```

### Request/Response extras

```ruby
request.body          -> Hash | Object  # PARSED body (JSON->Hash, form->Hash, multipart fields->Hash)
request.body_parsed   -> Hash | Object  # Alias of #body (backwards-compatible)
request.body_raw      -> String         # Raw body bytes exactly as sent (for SOAP/GraphQL/etc.)
request.json_body     -> Hash           # Parse the raw body as JSON ({} on failure)
request.cookies       -> Hash           # Parsed from Cookie header

response.xml(content, status: 200)         # XML response
response.call(data, status, content_type)  # Callable response (auto-detects type)

# Streaming / SSE — pass a positional generator (Enumerator, or anything
# responding to #each or #call yielding string chunks), OR use a block.
# Cross-framework parity: Python/PHP/Node use the positional-generator form.
response.stream(generator = nil, content_type: "text/event-stream", &block)
```

`request.body` returns the **parsed** payload (parity with Python/PHP/Node). Use
`request.body_raw` when you need the raw string (e.g. SOAP XML, custom parsing).

```ruby
# Streaming — positional generator (Python/PHP/Node parity):
Tina4::Router.get "/events" do |request, response|
  gen = Enumerator.new do |out|
    10.times { |i| out << "data: message #{i}\n\n" }
  end
  response.stream(gen)
end

# ...or the block form (Ruby-idiomatic, unchanged):
Tina4::Router.get "/events" do |request, response|
  response.stream do |out|
    10.times { |i| out << "data: message #{i}\n\n" }
  end
end
```

`response.json(...)` and `response.call(...)` auto-serialize domain objects to JSON:
an ORM model becomes a JSON object; an array of models or a `DatabaseResult`
(e.g. from `db.fetch(...)`) becomes a JSON array. Plain Hashes, Arrays and Strings
behave exactly as before — this is purely additive.

```ruby
Tina4::Router.get("/api/users") do |request, response|
  response.json(User.all)             # array of models -> JSON array
end
```

### DocStore — pymongo-style document store (zero-config SQLite fallback)

`Tina4::DocStore.get_collection(name)` returns a Mongo-style collection. When a Mongo URI is configured (and the `mongo` gem is present) it is a real Mongo collection; otherwise it is a `Tina4::DocStore::SqliteCollection` backed by a local SQLite file using JSON1. The call sites are identical either way — only the backend differs — so you develop against a zero-dependency local store and switch to MongoDB in production by setting one env var.

```ruby
orders = Tina4::DocStore.get_collection("orders")
res = orders.insert_one({ "customer_id" => 1, "total" => 9.99, "status" => "new" })
orders.find_one({ "_id" => res.inserted_id })
orders.update_one({ "_id" => res.inserted_id }, { "$set" => { "status" => "shipped" } })
orders.find({ "total" => { "$gt" => 5 } }).sort("total", -1).limit(10).each { |doc| }
orders.count_documents({ "status" => "shipped" })
Tina4::DocStore.serverless?   # true when running on the SQLite fallback
```

Filter operators: equality, `$in`, `$nin`, `$gt`, `$gte`, `$lt`, `$lte`, `$ne`, `$exists`, `$regex`, implicit AND, `$or`, `$and`, and dotted nested keys (`addr.city`). Updates: `$set`, `$unset`, `$inc`, replace, upsert. Cursors: `sort`, `limit`, `skip`, projection. Values round-trip (Time to/from ISO-8601, `ObjectId` to/from 24-hex) and stay queryable via `json_extract`. Non-goals: aggregation pipelines, `$elemMatch`, geo queries.

Selection and configuration:
- `TINA4_MONGO_URI` — app-wide Mongo URI. Falls back to `TINA4_SESSION_MONGO_URI`, then the legacy `TINA4_SESSION_MONGO_URL`. When one is set and the gem is present, `get_collection` returns a real Mongo collection.
- `TINA4_DOC_STORE_PATH` — SQLite file for the fallback store (default `data/tina4_docstore.db`).

### Template — ERB/Twig engine

```ruby
Tina4::Template.render(template_path, data = {}) -> String
Tina4::Template.add_global(key, value)
Tina4::Template.globals -> Hash
Tina4::Template.render_error(code) -> String
```

### Frond — Twig-compatible template engine

```ruby
engine = Tina4::Frond.new(template_dir: "src/templates")
engine.render(template, data = {}) -> String
engine.render_string(source, data = {}) -> String
engine.add_filter(name) { |value, *args| ... }
engine.add_test(name) { |value, *args| ... }
engine.add_global(name, value)
engine.clear_cache
```

- **SafeString**: Custom filters can return a SafeString to bypass auto-HTML-escaping.
- **Fragment caching**: `{% cache "key" 300 %}...{% endcache %}` caches rendered block content for TTL seconds.
- **Raw blocks**: `{% raw %}...{% endraw %}` outputs literal template syntax without parsing.

### QueryBuilder — Fluent query construction

Use `QueryBuilder` for complex queries with JOINs, aggregates, GROUP BY. Prefer over raw `db.fetch` for multi-table reads.

```ruby
# JOINs
orders = Tina4::QueryBuilder.from_table("orders o")
  .select("o.*", "c.name AS customer_name")
  .join("customers c", "o.customer_id = c.id")
  .where("o.status = ?", ["pending"])
  .order_by("o.created_at DESC")
  .limit(20)
  .get                       # -> DatabaseResult

# LEFT JOIN
products = Tina4::QueryBuilder.from_table("products p")
  .select("p.*", "c.name AS category_name")
  .left_join("categories c", "p.category_id = c.id")
  .get

# Aggregates
total = Tina4::QueryBuilder.from_table("orders")
  .select("coalesce(sum(total), 0) AS total")
  .where("status != ?", ["cancelled"])
  .first["total"]            # -> single row hash

# From ORM model
results = User.query.where("age > ?", [18]).order_by("name").get

# Methods: from_table, select, where, or_where, join, left_join,
#          group_by, having, order_by, limit, get, first, count,
#          exists?, to_sql, to_mongo
```

NoSQL support: `to_mongo` generates MongoDB query documents from the same fluent API.

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

Tina4.seed_orm(orm_class, count: 10, overrides: {}, clear: false, seed: nil, strict: false) -> SeedSummary
Tina4.seed_table(table_name, columns, count: 10, overrides: {}, clear: false, seed: nil, strict: false) -> SeedSummary
Tina4.seed_models(orm_classes, count: 10, overrides: {}, clear: false, seed: nil, strict: false) -> { "ModelName" => SeedSummary }
Tina4.seed_batch(tasks, clear: false, strict: false) -> { "ClassName" => SeedSummary }
Tina4.run_seeds(seed_folder: "seeds", clear: false)
```

**Seeding is visible-but-resilient.** `seed_orm` / `seed_table` wrap each row:
on a row failure the cause is logged (with the 0-based row index) and the row is
skipped, incrementing `failed`; with `strict: true` the FIRST failure re-raises
instead of skipping. Both return a `SeedSummary` — `{ seeded:, failed:, errors: }`
where `errors` is an array of `{ row:, message: }`. `SeedSummary` defines `to_i`
/ `==` against an Integer, so the old count contract (`expect(seed_orm(...)).to
eq(5)`) still holds while `summary.seeded` / `summary.failed` / `summary.errors`
/ `summary.to_h` expose the struct.

- **clear:** truncates the target table before seeding (parity across
  `seed_table` / `seed_orm` / `seed_models`) so re-runs don't duplicate rows or
  trip unique-PK violations.
- **seed:** seeds the FakeData RNG for reproducible data.
- **FK ordering:** `seed_models` / `seed_batch` topologically sort models by
  their `foreign_key_field` (belongs_to) dependency graph — parents seed before
  children, and `clear: true` clears in reverse order. Child FK columns are
  filled from a pool of REAL parent primary keys so no FK constraint is tripped.
- **dev-admin** `POST /__dev/api/seed` accepts `{table, count, seed, clear,
  strict}` and delegates to `seed_table` (shared per-row wrap; returns
  `{table, seeded, failed, errors}`).

### Api — External HTTP client

`verify_ssl: false` disables TLS verification (before 3.13.1 it was a stored-but-unused kwarg that silently did nothing). Opt-in retry/backoff: `max_retries:` (default `0` = off) plus `retry_backoff:` (default `0.5`s base, exponential) retries a transport error (`status == 0`) or a retryable status (429/500/502/503/504); 4xx is never retried (a retried non-idempotent request may be re-sent, so retries are opt-in). Net::HTTP does NOT auto-follow redirects, so the client follows them itself in a bounded loop (up to 10 hops) and strips the `Authorization` AND `Cookie` headers on a cross-origin hop (a different scheme/host/port), matching the Python master; same-origin redirects keep them. (This corrects a prior note that claimed the redirect auth-strip was Python-only.)

```ruby
api = Tina4::API.new("https://api.example.com", headers: {}, timeout: 30,
                     bearer_token: nil, username: nil, password: nil,
                     verify_ssl: nil, max_retries: 0, retry_backoff: 0.5,
                     transport: nil, cookies: false)
api.get(path, params: {}) -> ApiResponse
api.post(path, body: nil, content_type: "application/json") -> ApiResponse
api.put(path, body: nil, content_type: "application/json") -> ApiResponse
api.patch(path, body: nil, content_type: "application/json") -> ApiResponse
api.delete(path, body: nil) -> ApiResponse
api.upload(path, file_path: nil, field_name: "file", extra_fields: {},
           headers: {}, file_bytes: nil, filename: nil) -> ApiResponse
api.download(path, dest_path: nil, params: {}) -> ApiResponse
api.send_request(method, path, body: nil, content_type: "application/json") -> ApiResponse
api.set_basic_auth(username, password)
api.set_bearer_token(token)
api.add_headers(headers)

# ApiResponse
resp.status          # -> Integer (HTTP status code; 0 on a transport failure)
resp.body            # -> String
resp.headers         # -> Hash
resp.error           # -> String | nil
resp.success?        # -> Boolean (2xx)
resp.json            # -> Hash | Array (parsed body)
resp.path            # -> String | nil (download destination; nil on every other verb)
```

- **Multipart upload** (`upload`): POSTs a `multipart/form-data` body from a file on
  disk (`file_path:`) OR from in-memory bytes (`file_bytes:` + `filename:`), so no
  temp file is needed. `field_name:` is the file's form field (default `file`),
  `extra_fields:` become extra text parts, `headers:` are extra per-call headers. The
  part Content-Type is guessed from the filename (fallback `application/octet-stream`),
  and the client's default headers (including any Authorization) are sent too. A
  missing file or no source given returns a clean error response (`status` 0, `error`
  set); it never raises and nothing is sent over the wire.
  BREAKING (3.13.69): `file_path` was a REQUIRED positional argument; it is now the
  keyword `file_path:`, reconciled to the canonical cross-framework signature.
- **Streaming download** (`download`): streams the GET body to `dest_path:` in 64KB
  chunks, so a multi-megabyte response never lands in memory whole. The returned
  `ApiResponse` carries `path` (and no body); `path` is nil and no file is written on
  any error (missing `dest_path`, an HTTP error status, or a transport failure).
- **Transport seam** (`transport:`): an injectable object responding to
  `#call(method, url, headers, body, timeout)` and returning a Hash shaped like
  `{http_code:/status:, body:, headers:, error:}`, that fully REPLACES the network
  call so APPLICATION developers can unit-test code that calls an `Api`. Default nil
  means the real Net::HTTP path. Tina4's own suite NEVER injects a fake transport (the
  no-mock rule stands); framework tests always hit a real local server.
- **Cookie jar** (`cookies: true`): opt-in, off by default. Keeps a per-client,
  in-memory jar: parses `Set-Cookie` (leading `name=value` only, last write wins) and
  replays the accumulated `Cookie` header on later requests. Not persisted; scoped to
  the instance.

### Queue — Pluggable job queue

```ruby
queue = Tina4::Queue.new(topic: "tasks", backend: nil, max_retries: 3)
queue.push(payload, priority: 0, delay_seconds: 0) -> Integer  # job id
queue.pop -> Job | nil
queue.pop_batch(count) -> Array<Job>
queue.pop_by_id(id) -> Job | nil
queue.size(status: "pending") -> Integer
queue.clear -> Integer
queue.failed -> Array<Hash>
queue.dead_letters(max_retries: nil) -> Array<Hash>
queue.purge(status, max_retries: nil) -> Integer
queue.retry(job_id = nil, delay_seconds: 0) -> Boolean
queue.retry_failed(max_retries: nil) -> Integer
queue.produce(topic, payload, priority: 0, delay_seconds: 0)
queue.consume(topic = nil, id: nil, poll_interval: 1.0, iterations: 0, batch_size: 1) { |job| ... }
queue.process(topic: nil, max_jobs: nil, batch_size: 1) { |job| ... }

# Job methods
job.complete                       # mark as completed
job.fail(reason = "")              # mark as failed
job.reject(reason = "")            # alias for fail
job.retry(delay_seconds: 0)        # re-queue with optional delay
job.to_hash
job.to_json
```

Backends: lite (default file-based), rabbitmq, kafka, mongo. Configured via `TINA4_QUEUE_BACKEND` and backend-specific env vars.

### Background Tasks — Periodic background work

Register callbacks that run periodically in a dedicated thread. Tasks integrate with the server lifecycle and stop cleanly on shutdown.

```ruby
# Register a periodic task
Tina4::Background.register(interval: 2.0) { process_orders(queue) }

# Or pass an explicit callable
task = Tina4::Background.register(->{ check_health }, interval: 30.0)

Tina4::Background.tasks                 # -> Array of registered tasks
Tina4::Background.stop_task(task, timeout: 2.0)
Tina4::Background.stop_all(timeout: 2.0)
```

For long-running named services (cron, daemon, interval), use `Tina4::ServiceRunner` instead — it supports cron patterns, retries, and discovery from a `services/` folder.

### Migration

```ruby
migration = Tina4::Migration.new(db, migrations_dir: nil)
migration.run
migration.rollback(steps = 1)
migration.status -> Array
migration.create(name) -> String
```

**Auto-run on startup (`TINA4_AUTO_MIGRATE`, default on).** When a `migrations/`
folder (or `src/migrations/`) exists with at least one `.sql` file, boot
(`initialize!` → `run!`, after route discovery / DB bind, before serving) calls
`Tina4.auto_migrate_on_startup!` to apply pending migrations — no manual
`tina4ruby migrate` step. It is **non-breaking**: a failure (a raise from the
runner, or a recorded `failed` migration) is logged (`Tina4::Log.error`) and the
service still starts (a bad migration must never take the backend down — the
hook never re-raises). Set `TINA4_AUTO_MIGRATE=false` (also `0`/`no`/`off`) to
disable — e.g. multi-instance production that migrates as a separate deploy step
(concurrent first-apply can race). The explicit `tina4ruby migrate` CLI is
unaffected and stays **fail-fast** (a failed migration → non-zero exit) so CI
keeps the exit code.

**How migrations work internally.**

- SQL/Ruby files live in the `migrations/` (or `src/migrations/`) folder, named
  `NNNNNN_description.sql` (sequential) or `YYYYMMDDHHMMSS_description.sql`
  (timestamp). Files are discovered in **numeric-prefix order** (`9_` before
  `10_`) via a numeric-aware sort key — a plain lexical sort misorders unpadded
  prefixes. A file with no numeric/timestamp prefix logs a **WARNING** (its order
  relative to numbered files is undefined) and sorts after them. SQL is split on
  the `;` delimiter; `$$ … $$` / `// … //` stored-proc blocks are kept intact (a
  `://` URL literal is NOT mistaken for a `//` block).
- State is tracked in the `tina4_migration` table (auto-created per engine). The
  canonical column set is `id, migration_name VARCHAR(500) NOT NULL UNIQUE,
  description VARCHAR(500), batch INTEGER NOT NULL DEFAULT 1, executed_at
  VARCHAR(50) NOT NULL, passed INTEGER NOT NULL DEFAULT 1` — identical across all
  four Tina4 frameworks. A migration is **applied** when a row exists for it with
  `passed = 1` (the applied-read is `WHERE passed = 1`). `migrate` writes **only
  `passed = 1` rows**: on a failure the file rolls back, **no row is written** (it
  is NOT recorded as `passed = 0`), nothing is deleted, and the run stops (a
  `failed` result entry; the explicit `tina4ruby migrate` CLI exits non-zero). The
  public `record_migration(name, batch, passed:)` API can write a `passed = 0`
  row; any `passed = 0` row is treated as **not applied**, so it is reported
  pending. A leftover `passed = 0` row **re-applies cleanly**: both the success
  path and `record_migration` route through `_record_migration`, which **deletes
  any existing row for the `migration_name` before inserting** the fresh row, so
  a previously-failed migration is superseded instead of colliding on the unique
  `migration_name`. Invariant: the table holds **at most one row per
  `migration_name`**, latest state wins. Already-applied files stay applied — fix
  the bad file and re-run.
- **Each migration FILE is wrapped in its own transaction** (`start_transaction`
  / `commit`, `rollback` on error). On a failure the file rolls back as a unit.
- **Atomicity caveat:** the per-file transaction is truly atomic only on engines
  with **transactional DDL (PostgreSQL)**. MySQL, Firebird, and SQLite
  auto-commit DDL, so a multi-statement migration that fails midway on those
  engines leaves earlier statements applied — keep one logical change per file.
- **Idempotency on engines lacking `IF NOT EXISTS`:** on Firebird, `ALTER TABLE
  … ADD <column>` is existence-checked against `RDB$RELATION_FIELDS`; on Firebird
  AND MSSQL, a raw `CREATE TABLE` is skipped when the table already exists
  (`table_exists?`), so a re-run doesn't error object-already-exists.
  SQLite/MySQL/PostgreSQL support `IF NOT EXISTS` and are left to the engine.
  Only a genuine already-exists is skipped — every other error still raises.

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
Tina4::Log.critical(message, *args)  # HIGHEST severity (4, above error 3) — first-class, ALWAYS emits (subject only to the threshold); renders magenta. No opt-in toggle.
Tina4::Log.enabled?(level) -> Boolean  # would a message at `level` pass the console TINA4_LOG_LEVEL? (String/Symbol, case-insensitive; reflects CONSOLE visibility only — the file records every level). "critical" is a first-class top level (severity 4), not an error alias — it passes at every threshold except none.
# Severity ladder: debug(0) < info(1) < warning(2) < error(3) < critical(4); none = 5 (silences all).
# Controlled by TINA4_LOG_LEVEL env var: [TINA4_LOG_ALL], [TINA4_LOG_DEBUG], [TINA4_LOG_INFO], [TINA4_LOG_CRITICAL], etc.
# TINA4_LOG_STRICT=true raises on a log-write failure (renamed from TINA4_LOG_CRITICAL in v3.13.39).
# TINA4_LOG_OUTPUT (stdout|file|both) — stdout is ALWAYS on. When UNSET the log FILE is
#   dev-gated: written only in development (TINA4_DEBUG truthy); production/containers are
#   stdout-only (NO file — a container log file bloats the writable layer; 12-factor wants stdout).
#   An explicit TINA4_LOG_OUTPUT=file/both OR an explicit TINA4_LOG_FILE path always wins and forces
#   a file regardless of TINA4_DEBUG. Mirrors the Python master (v3.13.39).
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

# Listener isolation (visible-but-resilient): a throwing listener never
# aborts the rest. emit() wraps EACH listener — on a throw it LOGS via
# Tina4::Log.warning (event name + error class+message; falls back to $stderr
# if the logger itself fails — never silent) and CONTINUES. A failed listener
# contributes a nil slot, so N listeners always yield N results in priority
# order. Pass strict: true to RE-RAISE on the first listener error instead
# (later listeners then do NOT run).
results = Tina4::Events.emit("calc", 5, strict: true)
# emit_async isolates each threaded listener the same way; strict: true
# re-raises the listener error on Thread#join.
threads = Tina4::Events.emit_async("user.created", { name: "Alice" })

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
# Check whether a single tool's context file already exists in `root`.
# `tool` is one entry from Tina4::AI::AI_TOOLS (has :name, :context_file).
Tina4::AI.is_installed("/path/to/project", tool) # -> Boolean

# Print the numbered tool menu (with [installed] markers) and read a
# comma-separated selection (or "all") from STDIN. Returns the raw line.
Tina4::AI.show_menu("/path/to/project") # -> String

# Install context files for the tools listed in `selection` ("1,3,5" or "all").
# Returns relative paths of created/updated files.
files = Tina4::AI.install_selected(".", "1,2") # -> Array<String>

# Install context files for ALL known AI tools (non-interactive).
files = Tina4::AI.install_all(".") # -> Array<String>

# Generate the tool-specific Tina4 context body (used by install_selected).
body = Tina4::AI.generate_context("claude-code") # -> String

# Re-rendering the menu shows [installed] markers per tool — that's the
# human-readable status surface.
Tina4::AI.show_menu(".")
```

Supported tools: claude-code, cursor, copilot, windsurf, aider, cline, codex.

### ResponseCache — GET response cache middleware

Public surface mirrors Python's `tina4_python.cache`: middleware-only, plus
module-level `Tina4.cache_stats` / `Tina4.clear_cache`. Internal lookup/store
of GET responses is performed by middleware hooks and is NOT public.

```ruby
# Use as middleware on a route
cache = Tina4::ResponseCache.new(ttl: 60, max_entries: 1000, status_codes: [200])
cache.enabled?                              # -> Boolean (ttl > 0)

# Module-level API (parity with Python cache_stats() / clear_cache())
Tina4.cache_stats                           # -> { hits:, misses:, size:, backend:, keys: }
Tina4.clear_cache                           # flush all entries
Tina4.cache_get(key)                        # KV get (parity with Python cache_get)
Tina4.cache_set(key, value, ttl: 0)         # KV set (parity with Python cache_set)
Tina4.cache_delete(key)                     # KV delete (parity with Python cache_delete)

# Environment:
#   TINA4_CACHE_BACKEND  memory (default) | file | redis | valkey | memcached | mongodb | database
#   TINA4_CACHE_URL      connection for redis/valkey/memcached/mongodb, OR a SQL URL for database (falls back to TINA4_DATABASE_URL)
#   TINA4_CACHE_USERNAME / TINA4_CACHE_PASSWORD  credentials (mirror TINA4_DATABASE_USERNAME/_PASSWORD); may also be embedded
#                        in TINA4_CACHE_URL (redis://user:pass@host, redis://:pass@host, mongodb://user:pass@host). memcached is unauthenticated
#   TINA4_CACHE_TTL      default TTL in seconds (default: 60)
#   TINA4_CACHE_MAX_ENTRIES  max cached entries (default: 1000)
#   TINA4_CACHE_DIR      directory for the file backend (default: data/cache)
```

The response/KV cache supports seven backends, selected by `TINA4_CACHE_BACKEND`. **Graceful fallback**: if a configured backend's driver is missing or the service/credentials are unreachable or wrong, the cache logs a warning and falls back to the **file** backend — a real persistent cache, never a silent no-op.

### Container — Dependency injection

```ruby
# Register a concrete instance
Tina4::Container.register(:mailer, MailService.new)

# Register a lazy factory (called once, memoized)
Tina4::Container.register(:db) { Tina4::Database.new(ENV["DB_URL"]) }

# Resolve a service (raises KeyError if not registered)
db = Tina4::Container.get(:db)

Tina4::Container.has?(:mailer)         # -> Boolean
Tina4::Container.reset                  # remove all (useful in tests)
```

### ErrorOverlay — Rich HTML error page (dev mode)

```ruby
# Render a rich, syntax-highlighted HTML error page (Catppuccin Mocha theme)
html = Tina4::ErrorOverlay.render_error_overlay(exception, request: rack_env)

# Render a safe, generic error page for production
html = Tina4::ErrorOverlay.render_production_error(status_code: 500, message: "Internal Server Error")

# Check if the overlay should be shown (TINA4_DEBUG = true)
Tina4::ErrorOverlay.is_debug_mode  # -> Boolean
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

**XSS-safe by default.** String/scalar children are HTML-escaped on render
(`< > & " '` encoded) to defeat stored/reflected XSS; attribute values are
escaped too. Nested `HtmlElement` children render themselves (already escaped —
no double-escape). To emit trusted, pre-sanitised markup verbatim, wrap it in
`Tina4::Raw` (primary name) or its alias `Tina4::SafeString` — both are the
same class Frond uses to mark safe output.

```ruby
Tina4::HtmlElement.new("div").call("<b>x</b>")               # <div>&lt;b&gt;x&lt;/b&gt;</div>  (escaped)
Tina4::HtmlElement.new("div").call(Tina4::Raw.new("<b>x</b>"))   # <div><b>x</b></div>          (raw)
Tina4::HtmlElement.new("div").call(Tina4.Raw("<b>x</b>"))        # convenience constructor
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

Defined in `lib/tina4/sql_translator.rb`.

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
```

### QueryCache — in-memory TTL cache for query results

Defined in `lib/tina4/cache.rb:13` — NOT in `sql_translator.rb`. `SQLTranslator`
only computes the cache KEY (`query_key`, above); the cache itself is a separate
class in its own file.

```ruby
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

### Swagger / OpenAPI

Auto-generated docs are served at `/swagger` (UI) and `/swagger/openapi.json`
(spec). The spec is OpenAPI **3.0.3**. ORM models become reusable
`components.schemas` referenced by `$ref`, and any secured route emits a
`bearerAuth` security requirement.

Environment variables (read by `lib/tina4/swagger.rb` and
`lib/tina4/rack_app.rb`):

| Env var | Default | Purpose |
| --- | --- | --- |
| `TINA4_SWAGGER_ENABLED` | falls back to `TINA4_DEBUG` | Production on/off switch for the `/swagger` UI + `/swagger/openapi.json` endpoints. Explicit `true`/`false` wins; unset falls back to `TINA4_DEBUG`. Set `false` to DISABLE swagger in ANY environment (including dev); set `true` to expose it in production. Wired for real in 3.13.40 (previously ignored). |
| `TINA4_SWAGGER_SERVERS` | `SWAGGER_DEV_URL`, else `/` | Comma-separated list of server URLs for the OpenAPI `servers[]` block (multi-server / multi-environment). |
| `TINA4_SWAGGER_UI_CDN` | `https://cdn.jsdelivr.net/npm/swagger-ui-dist@5` | Base URL for the Swagger UI assets (`swagger-ui.css` + `swagger-ui-bundle.js`). Point it at a self-hosted mirror for air-gapped deployments. |
| `TINA4_SWAGGER_TITLE` | `PROJECT_NAME`, else `Tina4 API` | `info.title`. |
| `TINA4_SWAGGER_VERSION` | `Tina4::VERSION` | `info.version`. |
| `TINA4_SWAGGER_DESCRIPTION` | `Auto-generated API documentation` | `info.description`. |
| `TINA4_SWAGGER_CONTACT_EMAIL` | (unset) | `info.contact.email` (block emitted only when a contact field is set). |
| `TINA4_SWAGGER_CONTACT_TEAM` | `SWAGGER_CONTACT_TEAM` | `info.contact.name`. |
| `TINA4_SWAGGER_CONTACT_URL` | `SWAGGER_CONTACT_URL` | `info.contact.url`. |
| `TINA4_SWAGGER_LICENSE` | (unset) | SPDX license name (e.g. `MIT`) -> `info.license.name`. |
| `TINA4_SWAGGER_OPENAPI` | `3.0.3` | OpenAPI version; `3.1`/`3.1.0` -> emits `3.1.0`. |
| `TINA4_SWAGGER_BEARER_FORMAT` | `JWT` | `bearerFormat` on the built-in `bearerAuth` scheme (e.g. `opaque` for `sk_live_` keys). |
| `TINA4_SWAGGER_API_KEY_NAME` / `_IN` | (unset) / `header` | When the name is set, emit an `apiKeyAuth` scheme; `_IN` is header/query/cookie. |
| `TINA4_SWAGGER_DEFAULT_SCHEME` | `bearerAuth` | Scheme a secured route uses when `swagger_meta` declares no `security`. |
| `TINA4_SWAGGER_INCLUDE` / `_EXCLUDE` | (unset) | Comma-separated path-prefix allow-list / deny-list (`/swagger` + `/__dev` always excluded). |

**Per-route security + reusable schemas (v3.13.42).** Declare via `swagger_meta:`:
`security:` (scheme name, a `{name => [scopes]}` map, a list of maps for OR, or
`"public"`) and a sibling `scopes:` array; `request_schema:` / `response_schemas:`
reference schemas registered with `Tina4::Swagger.add_schema(name, schema)`.
Register arbitrary schemes (incl. `oauth2` + scopes) via
`Tina4::Swagger.add_security_scheme(name, definition)`. Scopes are kept valid:
only `oauth2`/`openIdConnect` carry them; `http`/`apiKey` get `[]`.

### MCP (Model Context Protocol)

The dev MCP server is mounted at `/__dev/mcp` (plus `/__dev/mcp/message` and an
SSE channel) and lets an AI client call built-in tools. It is gated on debug
mode and protected for remote callers. Environment variables (read by
`lib/tina4/mcp.rb` and `lib/tina4/dev_admin.rb`):

| Env var | Default | Purpose |
| --- | --- | --- |
| `TINA4_MCP` / `TINA4_DEBUG` | (unset) | Capability gate - whether MCP is enabled at all. `TINA4_MCP` set explicitly wins (sysadmin override, any host); else a truthy `TINA4_DEBUG` enables it. |
| `TINA4_MCP_REMOTE` | `false` | Set `true` to allow non-loopback MCP callers at all (still requires a valid token). Loopback callers never need a token. |
| `TINA4_MCP_TOKEN` | falls back to `TINA4_API_KEY` | Bearer token authorising a REMOTE MCP request. Accepted as `Authorization: Bearer`, `X-MCP-Token`, or `X-Api-Key`, compared timing-safe. With NO token configured a remote caller is always denied. |

## Key Architecture

- Rack 3-based web server with Puma (falls back to WEBrick)
- Routes auto-discovered from `routes/`
- ORM uses DSL methods (`integer_field`, `string_field`) with `FieldTypes` module
- Templates use ERB and Twig (custom engine)
- CLI (Thor): `tina4ruby serve` (--dev, --port), `tina4ruby seed` (--clear), `tina4ruby seed_create NAME`, `tina4ruby migrate`, `tina4ruby ai` (--all)
- SCSS compilation built-in
- JWT auth via `jwt` gem
- Password hashing via `bcrypt`
- File watching handled by the `tina4` Rust CLI (no framework-side watcher)
- Event system (observer pattern) for decoupled module communication — listener isolation: a throwing listener is logged (never silent) and the rest of `emit`/`emit_async` still run (N listeners → N results, failed slot = nil); `strict: true` re-raises on the first error
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
- Middleware ordering & error handling (visible-but-resilient): cross-class order = **registration order** (the order classes are attached via `Router.use` / `route.middleware`); within a class, `before_*`/`after_*` run in **source-definition order** (resolved by `source_location` line number, immune to Ruby's symbol-table reordering of `instance_methods`), inherited methods (base→derived) before a subclass's own. `before_*` run before the handler, `after_*` after. A middleware that **throws** is caught, logged via `Tina4::Log.error`, and produces a deterministic clean 500 (`{"error":"Internal Server Error","status":500}`) — never an unhandled crash. `after_*` ALWAYS run, even when a `before_*` short-circuited with status >= 400 (handler skipped) or threw, so they can still add headers/logging.
- Graceful shutdown handling
- Health check endpoint
- HTTP status code constants (`Tina4::HTTP_OK`, `Tina4::HTTP_NOT_FOUND`, etc.)
- Default host: 0.0.0.0, default port: 7147
- Messenger (.env driven SMTP/IMAP). IMAP reads FAIL LOUD: `inbox`/`read`/`unread`/`search`/`folders` LOG and RAISE `Tina4::MessengerConnectionError` (a `Tina4::MessengerError` subclass) on a connection/auth/protocol failure instead of returning empty — empty would be indistinguishable from a genuinely empty mailbox. A successful fetch with no messages still returns empty (`[]`/`nil`/`0`) normally. `send` is unchanged — it keeps returning `{success, message, id}` and logging.
- CLI scaffolding: `tina4ruby generate model/route/migration/middleware`
- Production server auto-detect: `tina4ruby serve --production` (auto-installs Puma, 2.8x improvement)
- Frond pre-compilation for 2.8x template render improvement
- DB query caching: request-scoped auto cache **off by default — opt-in** via `TINA4_AUTO_CACHING=true` (TTL `TINA4_AUTO_CACHING_TTL=5`s) for read-heavy endpoints; it dedupes identical reads within a request and flushes on writes. It defaults OFF because a request-scoped cache that defaults on is a footgun: a `SELECT MAX(id)`/generator read right before an `INSERT` in the **same** request would return a cached pre-write value (duplicate keys), and any read-after-write in one request would show stale state. Persistent cross-request cache is also opt-in via `TINA4_DB_CACHE=true` (TTL `TINA4_DB_CACHE_TTL=30`s) routed through the unified backend set via `TINA4_DB_CACHE_BACKEND` (memory/file/redis/valkey/memcached/mongodb/database) + `TINA4_DB_CACHE_URL` so instances share one cache with global write-invalidation; `cache_stats` reports `mode` (request/persistent/off — `off` when neither layer is enabled) and `backend`, `cache_clear`
- ORM relationships: `has_many`, `has_one`, `belongs_to` with eager loading (`include:`)
- Queue backends: file (default), RabbitMQ, Kafka, MongoDB. **Reservation/visibility timeout** (file + MongoDB): a popped job is reserved for `TINA4_QUEUE_VISIBILITY_TIMEOUT` seconds (default 300; `Queue.new(visibility_timeout:)`; `<= 0` disables) — if the consumer dies before `complete`/`fail`, the next `dequeue` reclaims it (incrementing `attempts`, dead-lettering past `max_retries`), so a crashed/evicted consumer never strands a job. RabbitMQ/Kafka delegate redelivery to the broker.
- Cache backends: unified set across response/KV and persistent DB cache — `memory` (default), `file`, `redis`, `valkey`, `memcached`, `mongodb`, `database` — selected via `TINA4_CACHE_BACKEND` (+ `TINA4_CACHE_URL`/credentials); falls back to the file backend if a backend is unreachable
- Session handlers: file, Redis, MongoDB. `TINA4_SESSION_SAMESITE` env var (default: Lax)
- QueryBuilder with NoSQL/MongoDB support (`to_mongo()`)
- WebSocket backplane (Redis/NATS pub/sub) for horizontal scaling — **wired for real**: each `broadcast`/`broadcast_all`/`broadcast_to_room` delivers to LOCAL connections first (resilient — one dead/slow client never aborts the rest; it is logged + pruned), then publishes an envelope `{src,kind,exclude,room,path,+text|b64}` to the shared channel `tina4:ws`. A sibling instance's backplane listener thread relays it to its own LOCAL connections only (origin guard drops the instance's own echo by `src`; the relay never re-publishes, so no cluster loop). Lazily started on first broadcast (best-effort — a backplane failure logs + degrades to local-only, never crashes a broadcast). Configured via `TINA4_WS_BACKPLANE` and `TINA4_WS_BACKPLANE_URL`. Rooms API: `conn.join_room(name)`, `conn.leave_room(name)`, `conn.rooms`, `conn.broadcast_to_room(name, msg)`, `ws.room_count(name)`, `ws.get_room_connections(name)`, `ws.broadcast_to_room(name, msg, exclude: nil)`
- WebSocket upgrade security — origin allow-list via `TINA4_WS_ALLOWED_ORIGINS` (comma-separated exact origins). Empty/unset = allow all (non-breaking, current behaviour); when set, an upgrade whose `Origin` isn't listed is refused 403. Enforced on every upgrade path (`Tina4.websocket_origin_allowed?`). Idle reaper via `TINA4_WS_IDLE_TIMEOUT` (seconds; 0/unset = disabled) — tracks last-activity per connection and closes/prunes connections idle past the timeout. WS upgrades need a hijack-capable server (Puma); under WEBrick the upgrade is correctly rejected 426
- Per-route WebSocket auth — a WS route is **PUBLIC by default** (mirrors GET). Declare a route secured either way (both set the same `auth_required` flag): declaratively via `Tina4::Router.secure_websocket(path)` / `Tina4.secure_websocket(path)` / `Tina4::Router.websocket(path, secure: true)`, or imperatively by chaining `.secure` on the returned `WebSocketRoute` (`.no_auth` flips back). On EVERY upgrade (in `WebSocket#handle_upgrade`, after the origin allow-list, before accepting the handshake) a secured route requires a valid JWT — missing/invalid → the upgrade is **rejected with 401, never accepted**; public routes always pass. Token transports (checked in order, all three accepted): `Authorization: Bearer <jwt>` header, the `Sec-WebSocket-Protocol: "bearer, <jwt>"` subprotocol (browsers — `new WebSocket(url, ['bearer', token])`), and `?token=<jwt>`. Validated via `Tina4::Auth.valid_token` (the same one HTTP uses). When the client offered the `bearer` subprotocol, the handshake **echoes `Sec-WebSocket-Protocol: bearer`** back. The verified payload is exposed on `connection.auth` (a Hash; `nil` on public routes). Helpers: `Tina4.ws_token(headers, query_string, subprotocol)` and `Tina4.ws_authorized(auth_required, headers, query_string, subprotocol) -> [payload, ok]`
- SameSite=Lax default on session cookies (`TINA4_SESSION_SAMESITE`)
- `tina4 deploy docker` generates Dockerfile and .dockerignore
- Gallery: 7 interactive examples with Try It deploy at `/__dev/`
- Race-safe `get_next_id` with atomic sequence table (`tina4_sequences`) for SQLite/MySQL/MSSQL; PostgreSQL auto-creates sequences
- Frond template engine optimizations: pre-compiled regexes, lazy loop context (copy-on-write), filter chain caching, path split caching, inline common filters (11-15% speedup)
- SSE/Streaming via `response.stream()` — Server-Sent Events support for real-time data push. Pass a generator/Enumerator; framework handles chunked transfer encoding, `text/event-stream` content type, and connection keep-alive. Hardened: a streaming source that raises mid-stream (generator/block error) or a client disconnect (IOError/EPIPE/ECONNRESET on the socket) is caught — chunks emitted before the failure are still delivered, the error is logged, and the stream ends cleanly so the worker never crashes
- WSDL/SOAP security (`lib/tina4/wsdl.rb`): a SOAP message containing a `<!DOCTYPE>` (DTD) is rejected with a `Client` fault ("DOCTYPE declarations are not allowed in SOAP messages") **before** parsing — SOAP 1.1 §3 forbids DTDs, and rejecting up front closes the REXML internal-entity-expansion (billion-laughs) and XXE attack surface (enforced on both `process_soap` and the legacy `Service#handle_soap_request`). An operation that raises returns a `Server` fault whose `<faultstring>` is the real cause **only** in debug mode (`TINA4_DEBUG`); in production it is a generic "Internal server error" and the real cause is logged via `Tina4::Log.error` — a resolver exception never leaks internal state to a SOAP client
- GraphQL security (`lib/tina4/graphql.rb`): **depth guard** — selection-set nesting is bounded by `TINA4_GRAPHQL_MAX_DEPTH` (default `50`; set `<= 0` to disable). An over-deep query or a circular fragment fails with a `"Query exceeds maximum depth of N"` error instead of overflowing the stack (depth counts sub-selections AND fragment spreads AND inline fragments; top-level starts at 1). **Resolver errors** are masked: the message is the real cause only in debug mode (`TINA4_DEBUG`), else a generic "Internal server error" (the real cause is logged via `Tina4::Log.error`, path preserved). **Directives are honored** — `parse_field` parses leading `@directive(args)` tokens into `:directives`, so `@skip`/`@include`/`@auth`/`@role`/`@guest` actually fire (previously the parser never populated directives, so they were silently ignored)
- Tests: 3,882 examples, 0 failures, 84 pending (PostgreSQL/MSSQL service-gated)
- Version: 3.13.84

## Links

- Website: https://tina4.com
- GitHub: https://github.com/tina4stack/tina4-ruby

## Skills

- **tina4-maintainer** — Always read and follow `.claude/skills/tina4-maintainer/SKILL.md` when working on this codebase. Read its referenced files in `.claude/skills/tina4-maintainer/references/` as needed for specific subsystems.
- **tina4-developer-ruby** — Always read and follow `.claude/skills/tina4-developer-ruby/SKILL.md` when building applications with this framework. Read its referenced files in `.claude/skills/tina4-developer-ruby/references/` as needed.
- **tina4-js** — Always read and follow `.claude/skills/tina4-js/SKILL.md` when working with tina4-js frontend code. Read its referenced files in `.claude/skills/tina4-js/references/` as needed.

## First Principle: Documentation Matches Code Reality

**This rule overrides everything else in this file.**

Every command, env var, method, class, or feature mentioned in any
documentation file (`*.md` in this repo, or any tina4-book chapter,
or `tina4-documentation/docs/`) MUST exist in code. No exceptions.
No "we'll build it later" entries. No Laravel/Rails-style commands
that look right but don't exist. No env vars that the framework
doesn't actually read.

When you add a doc reference, add the implementation in the same PR.
When you remove a feature, remove every doc reference in the same PR.
When you find drift, fix it both ways: build the real thing OR delete
the doc.

The `tina4-documentation/scripts/audit-truth.py` script is the source
of truth. It runs as a CI gate (`audit-truth.yml`) on every PR — the
build fails on CLI drift. Run it locally before pushing if you've
touched docs:

```bash
cd /path/to/tina4-documentation
python3 scripts/audit-truth.py --strict
```

If you're unsure whether something exists, run `tina4 <command> --help`
or grep the framework source. Don't guess.
