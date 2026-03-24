# Tina4 Ruby -- Feature Demos

Practical, copy-paste ready examples for every feature in the Tina4 Ruby framework.

## How to Run the Interactive Demo

```bash
cd tina4-ruby/demo
bundle install          # from the tina4-ruby root if not already done
ruby app.rb
```

Then visit **http://localhost:7147** in your browser.

The demo app starts a WEBrick server on port 7147 and provides an HTML landing page
with links to every feature demo. Each demo route returns JSON with the feature name,
status (working/partial/missing), output data, and notes.

**Requirements:** Ruby >= 3.1, sqlite3 gem, jwt gem, bcrypt gem (all listed in the gemspec).

## Getting Started

```bash
gem install tina4ruby
tina4ruby init myapp
cd myapp && bundle install
tina4ruby start --dev
```

## Demos

| # | Feature | File |
|---|---------|------|
| 01 | [Routing](01-routing.md) | Route definition, path params, HTTP methods, groups |
| 02 | [ORM](02-orm.md) | Model definition, field types, CRUD, relationships, soft delete |
| 03 | [Database](03-database.md) | Multi-driver abstraction (SQLite, Postgres, MySQL, MSSQL, Firebird) |
| 04 | [Templates](04-templates.md) | Twig engine, ERB, variables, loops, filters, inheritance |
| 05 | [Middleware](05-middleware.md) | Before/after hooks, pattern matching, per-route middleware |
| 06 | [Auth](06-auth.md) | JWT tokens, password hashing, bearer auth, secured routes |
| 07 | [Sessions](07-sessions.md) | Session management with file, Redis, and MongoDB backends |
| 08 | [GraphQL](08-graphql.md) | Schema, queries, mutations, ORM auto-schema, GraphiQL |
| 09 | [WebSocket](09-websocket.md) | WebSocket connections, events, broadcasting |
| 10 | [Swagger](10-swagger.md) | OpenAPI 3.0 auto-generation from routes |
| 11 | [API Client](11-api-client.md) | HTTP client for consuming external APIs |
| 12 | [WSDL / SOAP](12-wsdl.md) | WSDL generation, SOAP request handling |
| 13 | [Queue](13-queue.md) | Queue with produce/consume, Lite, RabbitMQ, Kafka, and MongoDB backends |
| 14 | [Seeder](14-seeder.md) | FakeData generator, ORM seeding, seed files |
| 15 | [Localization](15-localization.md) | i18n with JSON/YAML, interpolation, fallback |
| 16 | [Migrations](16-migrations.md) | Schema migrations with Ruby and SQL files |
| 17 | [AutoCRUD](17-auto-crud.md) | Auto-generated REST endpoints from ORM models |
| 18 | [CLI](18-cli.md) | `tina4ruby` commands: init, start, migrate, seed, routes, console |
| 19 | [Deployment](19-deployment.md) | Dockerfile, .env, CORS, rate limiting, logging |

## Links

- Website: https://tina4.com
- GitHub: https://github.com/tina4stack/tina4-ruby
