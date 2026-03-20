# Tina4 Ruby

Lightweight Ruby web framework. See https://tina4.com for full documentation.

## Build & Test

- Ruby: >=3.1.0 (homebrew: `/opt/homebrew/opt/ruby/bin/ruby`)
- Install: `bundle install`
- Run all tests: `bundle exec rspec`
- Run single test: `bundle exec rspec spec/file_spec.rb:LINE`
- Start server: `ruby app.rb` or `tina4` CLI
- CLI: `tina4` (Thor-based, exe in `exe/tina4`)

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
tina4 serve --dev
```

Or set `TINA4_DEBUG_LEVEL=ALL` / `DEBUG` in `.env`:

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
    api.rb, version.rb ...
    drivers/            # Database drivers (sqlite, postgres, mysql, mssql, firebird)
    queue_backends/     # Queue backends (lite, rabbitmq, kafka)
    session_handlers/   # Session storage (file, redis, mongo)
    templates/          # Built-in framework templates
    public/             # Built-in static assets
    scss/               # Built-in SCSS
exe/
  tina4                # CLI executable
spec/                  # RSpec test files (19 spec files)
```

## Key Method Stubs

### Router — Route registration

```ruby
Tina4.get(path, swagger_meta: {}, &handler)
Tina4.post(path, swagger_meta: {}, &handler)
Tina4.put(path, swagger_meta: {}, &handler)
Tina4.patch(path, swagger_meta: {}, &handler)
Tina4.delete(path, swagger_meta: {}, &handler)
Tina4.any(path, swagger_meta: {}, &handler)
Tina4.secure_get(path, &handler)
Tina4.secure_post(path, &handler)
Tina4.group(prefix, auth_handler: nil, &block)

Tina4::Router.add_route(method, path, handler, auth_handler: nil, swagger_meta: {})
Tina4::Router.find_route(path, method)
Tina4::Router.clear!
Tina4::Router.routes
# Route params use {id} syntax (NOT :id). Matches Python exactly.
# Type hints: {id:int}, {amount:float}, {slug:path}
# Handler receives |request, response| block params
```

### Database — Multi-driver abstraction

```ruby
db = Tina4::Database.new(connection_string, driver_name: nil)

db.fetch(sql, params = [], limit: nil, skip: nil) -> DatabaseResult
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
MyModel.all(limit: nil, skip: nil, order_by: nil) -> Array
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

### Seeder — Fake data generation

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

### Auth — JWT authentication

```ruby
auth = Tina4::Auth.new
auth.get_token(payload = {}) -> String
auth.valid_token?(token) -> Boolean
auth.get_payload(token) -> Hash | nil
auth.generate_secure_keys!
```

### Log — Logging

```ruby
Tina4::Log.info(message, *args)
Tina4::Log.debug(message, *args)
Tina4::Log.warning(message, *args)
Tina4::Log.error(message, *args)
# Controlled by TINA4_DEBUG_LEVEL env var: [TINA4_LOG_ALL], [TINA4_LOG_DEBUG], [TINA4_LOG_INFO], etc.
# Tina4::Debug is a backward-compat alias for Tina4::Log
```

## Key Architecture

- Rack 3-based web server with Puma (falls back to WEBrick)
- Routes auto-discovered from `routes/`
- ORM uses DSL methods (`integer_field`, `string_field`) with `FieldTypes` module
- Templates use ERB and Twig (custom engine)
- CLI (Thor): `tina4 serve` (--dev, --port), `tina4 seed` (--clear), `tina4 seed_create NAME`, `tina4 migrate`
- SCSS compilation built-in
- JWT auth via `jwt` gem
- Password hashing via `bcrypt`
- File watching via `listen`
- Version: 0.3.0

## Links

- Website: https://tina4.com
- GitHub: https://github.com/tina4stack/tina4-ruby
