<p align="center">
  <img src="https://tina4.com/logo.svg" alt="Tina4" width="200">
</p>
<h1 align="center">Tina4 Ruby</h1>
<h3 align="center">TINA4 — The Intelligent Native Application 4ramework</h3>
<p align="center"><em>Simple. Fast. Human. &nbsp;|&nbsp; Built for AI. Built for you.</em></p>
<p align="center">54 built-in features. Zero runtime dependencies. One require, everything works.</p>
<p align="center">
  <a href="https://rubygems.org/gems/tina4ruby"><img src="https://img.shields.io/gem/v/tina4ruby?color=7b1fa2&label=RubyGems" alt="RubyGems"></a>
  <img src="https://img.shields.io/badge/tests-1%2C578%20passing-brightgreen" alt="Tests">
  <img src="https://img.shields.io/badge/features-54-blue" alt="Features">
  <img src="https://img.shields.io/badge/dependencies-0-brightgreen" alt="Zero Deps">
  <a href="https://tina4.com"><img src="https://img.shields.io/badge/docs-tina4.com-7b1fa2" alt="Docs"></a>
</p>

---

## Quick Start

```bash
gem install tina4ruby
tina4ruby init my-app
cd my-app && tina4ruby serve
```

Open http://localhost:7147

---

## Code Examples

```ruby
Tina4.get "/api/hello" do |request, response|
  response.call({ message: "Hello from Tina4!" }, Tina4::HTTP_OK)
end

class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  string_field :email
end

db = Tina4::Database.new("sqlite://app.db")
```

---

## What's Included

| Category | Features |
|----------|----------|
| **Core HTTP** (7) | Router with path params (`{id:int}`, `{p:path}`), Server, Request/Response, Middleware pipeline, Static file serving, CORS |
| **Database** (6) | SQLite, PostgreSQL, MySQL, MSSQL, Firebird — unified adapter, connection pooling, query cache, transactions, race-safe ID generation, SQL dialect translation |
| **ORM** (7) | Active Record with typed fields, relationships (`has_one`/`has_many`/`belongs_to`), soft delete, QueryBuilder + MongoDB support, Auto-CRUD generator, migrations with rollback |
| **Auth & Security** (5) | JWT (HS256/RS256), password hashing (PBKDF2-SHA256), API key validation, rate limiting, CSRF form tokens |
| **Templating** (3) | Frond engine (Twig/Jinja2-compatible, pre-compiled 2.8× faster), SCSS auto-compilation, built-in CSS (~24 KB) |
| **API & Integration** (5) | HTTP client (zero-dep), GraphQL with ORM auto-schema + GraphiQL IDE, WSDL/SOAP with auto WSDL, WebSocket (RFC 6455) + Redis backplane, MCP server (24 dev tools) |
| **Background** (3) | Job queue (File/RabbitMQ/Kafka/MongoDB) with priority, delay, retry, dead letters — service runner — event system (on/emit/once/off) |
| **Data & Storage** (4) | Session (File/Redis/Valkey/MongoDB/DB), response cache (LRU, TTL), seeder + 50+ fake data generators, messenger (SMTP/IMAP) |
| **Developer Tools** (7) | Dev dashboard (11 tabs), dev toolbar, error overlay (Catppuccin Mocha), dev mailbox, hot reload + CSS hot-reload, code metrics (complexity, coupling, maintainability), AI context installer (7 tools) |
| **Utilities** (7) | DI container (transient + singleton), HtmlElement builder, inline testing (`@tests` decorator), i18n (6 languages), Swagger/OpenAPI auto-generation, CLI scaffolding (`generate model/route/migration/middleware`), structured logging |

**1,793 tests. Zero runtime dependencies. Full parity across Python, PHP, Ruby, and Node.js.**

---

## CLI Reference

```bash
tina4ruby serve [--port PORT]
tina4ruby migrate
tina4ruby seed
tina4ruby ai [--all]
tina4ruby generate model <name>
```

---

## Performance

Benchmarked with `wrk` — 5,000 requests, 50 concurrent, median of 3 runs:

| Framework | JSON req/s | Deps | Features |
|-----------|-----------|------|----------|
| **Tina4 Ruby** | **10,243** | 0 | 54 |
| Sinatra | 9,548 | 5+ | ~4 |

Tina4 Ruby outperforms Sinatra while delivering **54 features vs ~4** — with zero runtime dependencies.

**Across all 4 Tina4 implementations:**

| | Python | PHP | Ruby | Node.js |
|---|--------|-----|------|---------|
| **JSON req/s** | 6,508 | 29,293 | 10,243 | 84,771 |
| **Dependencies** | 0 | 0 | 0 | 0 |
| **Features** | 54 | 54 | 54 | 54 |

---

## Cross-Framework Parity

Tina4 ships identical features across four languages — same architecture, same conventions, same 54 features:

| | Python | PHP | Ruby | Node.js |
|---|--------|-----|------|---------|
| **Package** | `tina4-python` | `tina4stack/tina4php` | `tina4ruby` | `tina4-nodejs` |
| **Tests** | 2,066 | 1,427 | 1,793 | 1,950 |
| **Default port** | 7145 | 7146 | 7147 | 7148 |

**7,236 tests** across all 4 frameworks. See [tina4.com](https://tina4.com).

---

## Documentation

Full guides, API reference, and examples at **[tina4.com](https://tina4.com)**.

## License

MIT (c) 2007-2026 Tina4 Stack
https://opensource.org/licenses/MIT

---

## Our Sponsors

**Sponsored with 🩵 by Code Infinity**

[<img src="https://codeinfinity.co.za/wp-content/uploads/2025/09/c8e-logo-github.png" alt="Code Infinity" width="100">](https://codeinfinity.co.za/about-open-source-policy?utm_source=github&utm_medium=website&utm_campaign=opensource_campaign&utm_id=opensource)

*Supporting open source communities • Innovate • Code • Empower*
