# Changelog

Tina4 keeps ONE version across all four frameworks (Python, PHP, Ruby, Node.js), so a version
number means the same thing everywhere.

**The authoritative release notes for every shipped version live in the documentation:**
https://tina4.com/ruby/36-releases

This file is deliberately NOT a copy of those notes. Duplicating them is exactly how a
changelog rots into claiming a version that was never cut, so this file records only
UNRELEASED work. When a version ships, its notes go to the release notes above.

## Unreleased

### Changed

- **Breaking: the metrics payload is now the native engine's shape.** `full_analysis` no
  longer returns a `violations` key. The ranked `offenders` list replaces it and
  `--fail-on` reads that same list, so one concept has one name instead of two.
  Verified before removal: zero consumers outside the tests.

- **Breaking: `file_detail` returns the engine's per-file shape.** It no longer returns
  `total_lines`, `classes`, `imports` or `warnings`, and `functions` is now a COUNT rather
  than a list. Anything reading those keys must move to the engine's fields, or call
  `full_analysis` and read `most_complex_functions` for per-function detail.

- **Breaking: the empty-class warning is gone and is not coming back.** The old
  hand-rolled analyzer flagged `class Foo {}` with no members. An empty class is usually
  CORRECT rather than a defect: marker classes, base exception types, DTO placeholders.
  Tina4 itself ships `MetricsEngineError` as exactly that, so the check flagged the
  framework's own correct code. A check that fires on correct code is noise, and noise is
  why the offenders list went unread for months. The engine's vocabulary stays the four
  things that are actionable: complexity, large file, low maintainability, untested.

- **Breaking: the column-metadata primary-key flag is `primary_key`.** Ruby and Python use `primary_key`; PHP and Node use `primaryKey`. Each follows its own
  language's paradigm because this is framework API surface, not data. A dead `:primary`
  fallback that nothing ever set was deleted.

- **Breaking: metrics REQUIRE the `tina4` CLI on PATH, with no fallback.** All four
  frameworks deleted their own hand-rolled analyzer, so `full_analysis`, `offenders` and
  `file_detail` now shell out to `tina4 metrics --json` (ADR-0002: one engine, so a number
  measured in one language is comparable with the same number measured in another). A
  missing or stale CLI raises and names the install command instead of quietly returning
  worse numbers; the dev-admin endpoints answer 503, or 404 for an unknown file path.
  Previously a failure fell back to the local analyzer, which is exactly how four
  frameworks came to disagree about the same file. The file census behind the dashboard
  (`quick_metrics`) stays in-process and needs no CLI: it is a glob-and-count, and the
  engine is 8x to 37x slower on that path.

- **Breaking: every ORM read path that takes a `limit:` now defaults to 100 rows, and
  three of them were returning EVERY ROW.** `where`, `all` and `select` defaulted to
  `limit: nil`, and `Database#fetch` skips `apply_limit` entirely when the limit is nil,
  so all three read the whole table. `with_trashed` and a `scope`-generated method
  defaulted to 20. All five now default to 100.

  Migration: this one can change results in both directions. A caller relying (knowingly
  or not) on an unbounded read must now ask for it: `Model.all(limit: 10_000)`. A caller
  relying on the old 20 gets 100. Code that already passes a limit is unaffected.

  `QueryBuilder#get` and `fetch_all` are deliberately UNCHANGED and stay uncapped.
  Neither takes a `limit:`, so a cap there can only ever be silent, and that silent
  `LIMIT 100` was the data-loss-on-read footgun removed in 3.13.39 (ruby#4). The rule: a
  path that advertises `limit:` caps at 100, a path without one never caps.

- **Fixed** a `scope`-generated method accepted `limit:` and `offset:` and then discarded
  both. It called `where(filter_sql, params)` without passing either, so
  `User.active(limit: 5)` returned the whole table: 150 rows came back from a 5-row
  request against a 150-row table. Both arguments now reach `where`.

- Internal: the SQL dialect-translation file is renamed
  `lib/tina4/sql_translation.rb` -> `lib/tina4/sql_translator.rb`, so the filename matches the
  `Tina4::SQLTranslator` class it defines (and the sibling frameworks). The class name, its
  methods and its behaviour are unchanged, and `require "tina4"` is unaffected - this is a
  filename alignment, not an API change. Only code that bypassed the gem's own entry point with
  a direct `require "tina4/sql_translation"` needs to update the path.

### Fixed

- **`tina4 deploy docker` produced images that could not start.** Of the eight
  Dockerfile generators in the stack (four templates in the `tina4` CLI plus one
  in each framework's own CLI), exactly one was correct. Python named
  `python -m tina4_python.cli`, a package with no `__main__.py`, so the container
  died on startup; PHP ran `php index.php <addr>`, but `App::run(?host, port)`
  never reads argv so the address was dropped and production never engaged;
  Node named a path that exists only inside the tina4-nodejs monorepo and
  depended on tsx, which `npm ci --omit=dev` strips. Every generator now names a
  published entry point and requests production. Verified by scaffolding,
  generating, building and running a container for all four languages.
- **`serve` no longer kills PID 1.** The port-reclaim step read `lsof -ti`
  without validating it. Where lsof prints a different shape, a non-numeric field
  coerced to 0 or 1 -- and signalling PID 0 hits every process in the caller's
  own process group. In a container the server IS PID 1, so it killed itself
  (Node logged "Killed existing process on port 7148 (PID: 1 ...)" then exited
  143; PHP logged the same attempt and survived by luck). Reclaiming is now
  skipped inside a container, only all-digit PIDs are accepted, and PID 0, PID 1
  and the current process are never signalled.
- **The Ruby image builds.** The builder stage was `ruby:3.3-slim`, which has no
  compiler, so `bundle install` failed with `Gem::Ext::BuildError` on the first
  native extension (date, json, nio4r, sqlite3 are all in the default set). The
  builder is now the full `ruby:3.3` image and the slim runtime installs
  `libsqlite3-0`. Bundler's `deployment true` is gone: it demands a lockfile
  matching the image's bundler exactly, so a lockfile from a newer bundler on a
  developer machine hard-failed the build.

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
