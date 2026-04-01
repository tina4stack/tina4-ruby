# Tina4 Ruby — Feature Parity Checklist

Version: 3.10.37 | Last updated: 2026-03-31 | Reference: tina4-python

This checklist tracks feature parity against the Python reference implementation.

## Core HTTP Engine

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| Router (GET/POST/PUT/PATCH/DELETE/ANY) | [x] | [x] | `router.rb` — 354 lines |
| Path params ({id:int}, {price:float}, {path:path}) | [x] | [x] | |
| Wildcard routes (*) | [x] | [x] | |
| Route grouping | [x] | [x] | |
| RackApp (request dispatch) | [x] | [x] | `rack_app.rb` — 695 lines |
| Server (Puma/WEBrick) | [x] | [x] | `webserver.rb` |
| Request object | [x] | [x] | With IndifferentHash |
| Response object | [x] | [x] | `response.rb` |
| Static file serving | [x] | [x] | Built into RackApp |
| CORS middleware | [x] | [x] | `cors.rb` |
| Health endpoint | [x] | [x] | `health.rb` |
| Constants | [x] | [x] | `constants.rb` |

## Auth & Security

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| JWT auth (zero-dep) | [x] | [x] | `auth.rb` |
| Password hashing | [x] | [x] | |
| @secured / @noauth | [x] | [x] | Via route options |
| Form token (CSRF) | [x] | [x] | |
| CSRF middleware | [x] | [x] | In `middleware.rb` |
| Rate limiter | [x] | [x] | `rate_limiter.rb` |
| Validator | [x] | [x] | `validator.rb` |

## Database

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| URL-based multi-driver connection | [x] | [x] | `database.rb` — 499 lines |
| Connection pooling | [x] | [x] | |
| SQLite3 driver | [x] | [x] | `sqlite3_adapter.rb` + `sqlite_driver.rb` |
| PostgreSQL driver | [x] | [x] | `postgres_driver.rb` |
| MySQL driver | [x] | [x] | `mysql_driver.rb` |
| MSSQL driver | [x] | [x] | `mssql_driver.rb` |
| Firebird driver | [x] | [x] | `firebird_driver.rb` |
| ODBC driver | [ ] | [ ] | Not implemented — Python has it |
| DatabaseResult | [x] | [x] | `database_result.rb` |
| SQL translation | [x] | [x] | `sql_translation.rb` |
| Query caching | [x] | [ ] | Less mature than Python |
| get_next_id | [x] | [x] | |
| Transactions | [x] | [x] | |

## ORM

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| Active Record (save/load/delete/select) | [x] | [x] | `orm.rb` — 633 lines |
| Field types | [x] | [x] | `field_types.rb` |
| Relationships | [x] | [x] | |
| Soft delete | [x] | [x] | |
| create_table() | [x] | [x] | |
| QueryBuilder | [x] | [x] | `query_builder.rb` |
| AutoCRUD | [x] | [x] | `auto_crud.rb` |
| CRUD (low-level) | [x] | [x] | `crud.rb` — 692 lines |

## Template Engine (Frond)

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| Twig-compatible syntax | [x] | [x] | `frond.rb` — 1919 lines |
| Block inheritance | [x] | [x] | |
| parent()/super() in blocks | [x] | [x] | |
| Include/import/macro | [x] | [x] | |
| Filters | [x] | [x] | |
| Custom filters/globals/tests | [x] | [x] | |
| SafeString | [x] | [x] | |
| Fragment caching | [x] | [x] | |
| Raw blocks | [x] | [x] | |
| Sandbox mode | [x] | [x] | |
| form_token / formTokenValue | [x] | [x] | |
| Arithmetic in {% set %} | [x] | [x] | |
| Filter-aware conditions | [x] | [x] | |
| Dev mode cache bypass | [x] | [x] | |

## API & Protocols

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| API client (zero-dep) | [x] | [x] | `api.rb` |
| Swagger/OpenAPI generator | [x] | [x] | `swagger.rb` |
| GraphQL engine | [x] | [x] | `graphql.rb` — 837 lines |
| WSDL/SOAP server | [x] | [x] | `wsdl.rb` — 563 lines |
| MCP server | [x] | [x] | `mcp.rb` — 696 lines |

## Real-time & Messaging

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| WebSocket server | [x] | [x] | `websocket.rb` |
| WebSocket backplane | [x] | [x] | `websocket_backplane.rb` |
| Messenger (SMTP/IMAP) | [x] | [x] | `messenger.rb` — 562 lines |

## Queue

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| Database-backed job queue | [x] | [x] | `queue.rb` |
| Kafka backend | [x] | [x] | |
| RabbitMQ backend | [x] | [x] | |
| MongoDB backend | [x] | [x] | |
| Lite (file) backend | [x] | [x] | Extra — not in Python |

## Sessions

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| File session handler | [x] | [x] | |
| Database session handler | [x] | [x] | |
| Redis session handler | [x] | [x] | |
| Valkey session handler | [x] | [x] | |
| MongoDB session handler | [x] | [x] | |

## Infrastructure

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| Migrations | [x] | [x] | `migration.rb` |
| Seeder / FakeData | [x] | [x] | `seeder.rb` — 524 lines |
| i18n / Localization | [x] | [x] | `localization.rb` |
| SCSS compiler | [x] | [x] | `scss_compiler.rb` |
| Events | [x] | [x] | `events.rb` |
| DotEnv loader | [x] | [x] | `env.rb` |
| Structured logging | [x] | [x] | `log.rb` |
| Error overlay | [x] | [x] | `error_overlay.rb` |
| DI Container | [x] | [x] | `container.rb` |
| Response cache | [x] | [x] | `response_cache.rb` — 551 lines |
| Service runner | [x] | [x] | `service_runner.rb` |
| Graceful shutdown | [x] | [x] | `shutdown.rb` — extra, not in Python |

## Dev Tools

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| DevAdmin dashboard | [x] | [x] | `dev_admin.rb` — 1362 lines |
| DevMailbox | [x] | [x] | `dev_mailbox.rb` |
| DevReload | [x] | [ ] | `dev_reload.rb` — 68 lines, basic |
| Gallery (interactive examples) | [x] | [x] | |
| Metrics (code analysis) | [ ] | [ ] | Not yet ported from Python |
| Version check | [x] | [ ] | Needs proxy endpoint like Python |

## Testing & CLI

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| TestClient | [x] | [x] | `test_client.rb` |
| Inline testing | [x] | [x] | `testing.rb` |
| CLI (init, serve, migrate, generate) | [x] | [x] | `cli.rb` — 714 lines |
| AI context detection | [x] | [x] | `ai.rb` |

## Static Assets

| Feature | Present | Up to scratch | Notes |
|---------|---------|---------------|-------|
| Minified CSS (tina4.min.css) | [ ] | [ ] | Missing — Python/PHP/Node have it |
| Minified JS (tina4.min.js, frond.min.js) | [ ] | [ ] | Missing — Python/PHP/Node have it |
| HtmlElement builder | [x] | [x] | `html_element.rb` |

## Gaps vs Python Reference

| Gap | Priority | Notes |
|-----|----------|-------|
| Minified CSS/JS bundles | High | Missing entirely — other 3 frameworks have them |
| ODBC driver | Low | Python has it |
| Metrics (code analysis) | High | Not yet ported from Python |
| DevReload | Low | Very basic (68 lines vs Python's 214) |

## Summary

- **Total features**: 75
- **Present**: 72/75
- **Up to scratch**: 69/75
- **Gaps**: 3 missing features (minified assets, ODBC, metrics), 3 not up to scratch
