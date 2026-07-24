# Changelog

Tina4 keeps ONE version across all four frameworks (Python, PHP, Ruby, Node.js), so a version
number means the same thing everywhere.

**The authoritative release notes for every shipped version live in the documentation:**
https://tina4.com/ruby/36-releases

This file is deliberately NOT a copy of those notes. Duplicating them is exactly how a
changelog rots into claiming a version that was never cut, so this file records only
UNRELEASED work. When a version ships, its notes go to the release notes above.

## Unreleased

### Added

- **MQTT 3.1.1 client** (`Tina4::Mqtt` / `Tina4::MqttMessage`), zero-dependency (stdlib `socket` +
  lazily-required `openssl`), verified against a real broker with no mocks. publish/subscribe/consume,
  QoS 0/1, retained, Last Will, per-client TLS, QoS 2 refused loudly. Ruby ships all 97 shared
  features plus its native ERB engine, for **98 built-in features**.

### Changed

- Internal: the SQL dialect-translation file is renamed
  `lib/tina4/sql_translation.rb` -> `lib/tina4/sql_translator.rb`, so the filename matches the
  `Tina4::SQLTranslator` class it defines (and the sibling frameworks). The class name, its
  methods and its behaviour are unchanged, and `require "tina4"` is unaffected - this is a
  filename alignment, not an API change. Only code that bypassed the gem's own entry point with
  a direct `require "tina4/sql_translation"` needs to update the path.

### Fixed

- **Security: the bundled Swagger UI static assets now honour the swagger gate.** `/swagger`,
  `/swagger/`, `/swagger/index.html` and `/swagger/oauth2-redirect.html` were served from the
  framework's own public directory BEFORE route matching (with directory-index resolution turning
  `/swagger` into `swagger/index.html`), so a production server with `TINA4_SWAGGER_ENABLED=false`
  still served the whole UI while `/swagger/openapi.json` correctly 404'd. Static serving now checks
  the gate before it resolves an index. Bite-verified lock-in test. (python#97)
- **The startup banner advertises only a surface that answers.** The `Swagger:` and `Dashboard:`
  rows printed unconditionally, so a production log claimed a dev surface was exposed and a
  developer following the link hit a 404. Each row is now built by one pure helper of
  (port, swagger_enabled, dev_admin_enabled), unit tested rather than inferred from stdout.
  (python#99)
- **MQTT TLS tests verify the CA before trusting it.** A stale CA file in the shared temp directory
  made six TLS tests FAIL instead of skip, in all four frameworks, pointing at correct TLS code.
  The suites now confirm the CA actually validates the broker certificate before treating the TLS
  environment as present. (python#98)
- **The gemspec declares `logger` and `base64`.** Ruby 4 dropped both from the default gems.
  `tina4ruby` requires `logger` and nothing in its transitive closure provided it, so a fresh
  install on Ruby 4 could fail at require time. `base64` is satisfied through `jwt` today and is
  declared directly so a change there cannot break us.


## Earlier history (pre-3.x)

Kept for reference only. The versions below are from the 0.x line, long before the unified
3.x versioning; everything from 3.x onward is in the release notes linked above.

## [0.4.0] - 2026-03-18

### Added
- Multi-stage Dockerfile (ruby:3.3-alpine, build + runtime stages, optimized layer caching)
- .dockerignore for clean Docker builds
- `tina4ruby init` now generates Dockerfile and .dockerignore alongside project scaffolding

## [0.3.0] - 2026-03-14

### Added
- Zero-dependency GraphQL implementation (matching tina4php-graphql)
- Recursive descent GraphQL parser (queries, mutations, fragments, variables, aliases)
- Depth-first AST executor with resolver pattern
- GraphQL schema with programmatic type registration
- ORM auto-schema generation (`schema.from_orm(User)`) - auto-creates CRUD queries/mutations
- GraphiQL UI served at GET /graphql
- Route integration via `gql.register_route("/graphql")`
- Full GraphQL type system (scalars, objects, lists, non-null, input objects)

## [0.2.0] - 2026-03-14

### Added
- Default auth protection for POST/PUT/PATCH/DELETE routes (matching tina4_python behavior)
- API_KEY bypass in bearer auth - if `ENV["API_KEY"]` matches the bearer token, access is granted
- `auth: false` option to make write routes public (equivalent to tina4_python's `@noauth()`)
- `default_secure_auth` cached auth handler for performance
- `resolve_auth` helper for flexible auth resolution
- Puma as default production server (WEBrick fallback)
- `add_header` method on Response object

### Improved
- Performance: lazy-initialized Request fields (headers, body, params, cookies, files)
- Performance: pre-frozen CORS headers and OPTIONS response (zero allocation)
- Performance: method-indexed route lookup (O(1) method filtering)
- Performance: pre-computed static file roots at boot
- Performance: fast-path for API routes skipping static file checks
- Performance: cookie-less response fast path (no header duplication)
- Router: normalized path computed once per request instead of per-route
- Router: `match_path` returns params directly without redundant method check
- Response: frozen content-type constants
- Request: lazy `json_body` parsing
- RackApp: skip `auto_detect` when handler returns response object directly

### Changed
- GET routes remain public by default
- POST/PUT/PATCH/DELETE routes are now secured by default (use `auth: false` to make public)
- `any` routes default to public (`auth: false`)
- `secure_*` variants now use `default_secure_auth` (cached lambda)

## [0.1.0] - 2026-03-14

### Added
- Core framework with Rack-based request pipeline
- DSL routing (get, post, put, patch, delete, any)
- Path parameters with type casting ({id:int}, {id:float}, {id:path})
- Route groups with shared auth handlers
- Request/Response objects with auto-type detection
- Puma production server (WEBrick fallback)
- SQLite, PostgreSQL, MySQL, MSSQL, Firebird database drivers
- Database abstraction with parameterized queries
- ORM with field types DSL and CRUD operations
- SQL migration runner
- JWT RS256 authentication + bcrypt password hashing
- File-based sessions with JWT tokens
- Before/after middleware hooks
- OpenAPI 3.0 Swagger auto-generation
- Twig-compatible template engine (ERB fallback)
- CRUD scaffolding
- REST API client helper
- WebSocket support
- Message queue abstraction (file, RabbitMQ, Kafka backends)
- SCSS auto-compilation
- Dev reload with file watching
- i18n localization
- Inline testing framework
- CLI commands (init, start, migrate, test)
- .env auto-creation and loading
- Colored debug logging with rotation
