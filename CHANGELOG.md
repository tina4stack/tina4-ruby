# Changelog

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
- ORM auto-schema generation (`schema.from_orm(User)`) — auto-creates CRUD queries/mutations
- GraphiQL UI served at GET /graphql
- Route integration via `gql.register_route("/graphql")`
- Full GraphQL type system (scalars, objects, lists, non-null, input objects)

## [0.2.0] - 2026-03-14

### Added
- Default auth protection for POST/PUT/PATCH/DELETE routes (matching tina4_python behavior)
- API_KEY bypass in bearer auth — if `ENV["API_KEY"]` matches the bearer token, access is granted
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
