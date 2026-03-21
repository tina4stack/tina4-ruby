# CLI

The `tina4ruby` command-line tool provides project scaffolding, server management, migrations, seeding, route inspection, and an interactive console.

## Installation

```bash
gem install tina4ruby
```

## Commands

### init -- Scaffold a New Project

```bash
tina4ruby init myapp
cd myapp && bundle install
```

Creates the following structure:

```
myapp/
  app.rb              # Entry point with sample routes
  Gemfile             # Ruby dependencies
  Dockerfile          # Multi-stage Docker build
  .dockerignore
  .gitignore
  routes/             # File-based route directory
  templates/          # Twig/ERB templates
    base.twig         # Base template with blocks
  public/             # Static assets
    css/
    js/
    images/
  migrations/
  src/
  logs/
```

Initialize in the current directory:

```bash
tina4ruby init .
```

### start -- Run the Web Server

```bash
# Default: port 7147, all interfaces
tina4ruby start

# Custom port
tina4ruby start --port 3000

# Custom host
tina4ruby start --host 127.0.0.1

# Development mode (auto-reload, SCSS compilation, verbose logging)
tina4ruby start --dev
```

Uses Puma if available, falls back to WEBrick.

### migrate -- Database Migrations

```bash
# Run pending migrations
tina4ruby migrate

# Create a new migration
tina4ruby migrate --create add_orders_table

# Rollback last batch
tina4ruby migrate --rollback 1

# Rollback last 3 batches
tina4ruby migrate --rollback 3
```

### seed -- Populate Data

```bash
# Run all seed files in seeds/
tina4ruby seed

# Clear tables before seeding
tina4ruby seed --clear
```

### seed:create -- Create a Seed File

```bash
tina4ruby seed:create users
# Creates seeds/001_users.rb

tina4ruby seed:create products
# Creates seeds/002_products.rb
```

### routes -- List Registered Routes

```bash
tina4ruby routes
```

Output:

```
Registered Routes:
------------------------------------------------------------
  GET      /
  GET      /api/hello
  POST     /api/users [AUTH]
  GET      /api/users/{id:int}
  DELETE   /api/users/{id:int} [AUTH]
------------------------------------------------------------
Total: 5 routes
```

### console -- Interactive REPL

```bash
tina4ruby console
```

Opens an IRB session with Tina4 loaded, routes discovered, and database connected. Useful for testing ORM queries.

```ruby
irb> User.all(limit: 5)
irb> User.count
irb> Tina4::Router.routes.length
```

### test -- Run Inline Tests

```bash
tina4ruby test
```

Runs test files from `tests/`, `test/`, `spec/`, or `src/tests/` directories.

### version

```bash
tina4ruby version
# Tina4 Ruby v0.3.0
```

### help

```bash
tina4ruby help
tina4ruby --help
tina4ruby start --help
```

## Development Mode

Start with `--dev` to enable:
- **Auto-reload**: File watcher detects changes to `.rb`, `.twig`, `.html`, `.erb` files
- **SCSS auto-compile**: `.scss` changes compiled automatically
- **Verbose logging**: Full debug output

```bash
tina4ruby start --dev
```

Or set the debug level in `.env`:

```
TINA4_DEBUG_LEVEL=[TINA4_LOG_ALL]
```
