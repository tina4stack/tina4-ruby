# Changelog

Tina4 keeps ONE version across all four frameworks (Python, PHP, Ruby, Node.js), so a version
number means the same thing everywhere.

**The authoritative release notes for every shipped version live in the documentation:**
https://tina4.com/ruby/36-releases

## 3.13.105

Bug release. Route inspection stops touching the app; Firebird's migration
ledger tolerates whatever case the driver hands back; PHP loses a colon-in-
filename that broke Windows checkouts.

### Route inspection scans, never boots

- `tina4 routes` now walks canonical route files and never executes the
  application entrypoint or starts the server. Feature 115 / ADR-0058.
- Fixes the case where `tina4 routes --override` would boot the app on the
  same port and kill whatever process was already holding it (tina4-python
  issue #104).

### Firebird migration ledger is case-agnostic

- `tina4_migration` reads and writes work regardless of the case the
  Firebird driver returns for the `migration_name` column.
- Uses the atomic sequence table pattern already in place for other engines.

## 3.13.103

### Metrics reports what it can prove

- Require signed Tina4 client 3.8.76 for the native metrics handoff.
- Expose `has_referencing_test` as a source-reference signal. It does not claim
  that a test ran or that coverage exists.
- Fail when the native client is stale instead of falling back to a second
  framework-owned analyser.

### Frond stays stable and gets smaller

- Split expression parsing and evaluation into focused internal steps.
- Preserve public APIs and the shared 84-case expression corpus across all four
  languages.

### One client starts every project

- Lead framework skills with `tina4 init` and `tina4 serve`.
- Keep scaffolding guidance visible and separate runtime dependencies from
  language extensions.

### Release integrity

- Align source, runtime, package, lockfile, and AI-facing guide versions.
- Reject a release tag that does not match the source package version before
  any registry publish begins.

+## 3.13.101

### Breaking: metrics has one owner

- Remove the framework `metrics` command and local quick census. Use the native `tina4 metrics` CLI.
- Keep dev-admin metrics as a thin `/metrics/full` and `/metrics/file` JSON handoff to that CLI.

### App-facing AI client

- Add zero-dependency `Tina4::Ai.chat`, `Tina4::Ai.complete`, and `Tina4::Ai.embed`.
- Support local/OpenAI-compatible, OpenAI, and Anthropic chat providers.
- Normalize chat responses, stream ordered deltas, and preserve embedding cardinality.
- Fail closed on missing hosted-provider keys, verify TLS, redact sensitive failures, and
  distinguish bounded connection and total-request timeouts.
- Retry only transient connection, HTTP 429, and HTTP 5xx failures, never a partial stream.

## 3.13.100

### Breaking: Frond instance extensions stay local

Calling `add_filter`, `add_global`, or `add_test` on a Frond instance now changes
that renderer only. Register on `Frond` itself when every later instance must
inherit the extension.

- Reject a second `{% extends %}` tag instead of replacing the first parent without warning.
- Resolve multi-level inheritance without recursing through the same child template.
- Preserve nested root blocks through a depth-aware final substitution pass.
- Bound template, fragment, and expression caches, with TTL sweeps for stale entries.
- Retry transient AI skill-download failures.
- Activate the tina4-js skill for `tina4js` and `Tina4 JS` spellings as well as `tina4-js`.
- Keep `Tina4::VERSION` and both AI-facing guide markers on one version.

## 3.13.99

### Breaking: `request.params` is route-params-only, and `path_params` is renamed `params`

Ruby had the worst version of the param-pollution bug: `params` used to merge the query
string, the parsed body, AND the route params, so `request.params["id"]` could silently
return a client-supplied value that shadowed the real route parameter. Client input now
lives only in `request.query` and `request.body`. **The route-param accessor itself is
renamed: `path_params` becomes `params`, with no alias.** A malformed JSON body used to parse
to `{}`; it now returns the raw string it failed to parse. An empty body used to parse to
`{}`; it now returns `nil`. `header()` lookup is case-fold only now (it no longer also
converts `_` to `-`).

**Migration.** Rename every `path_params` call site to `params`. Replace any `params[...]`
read of a client-supplied value with `query[...]` or `body[...]`.

### Breaking: security headers, CSRF, and the dev server default on

`Content-Security-Policy: default-src 'self'` and the other security headers now emit by
default (relax with `TINA4_CSP`; HSTS on HTTPS via `TINA4_HSTS`). The CSRF `403` body is
unified to `{error, code, message, status}`, where Ruby used to send
`{error: "CSRF_INVALID"}`. `TINA4_CSRF=true` now actually attaches the CSRF middleware, and a
blank `TINA4_SECRET` fails closed instead of minting a forgeable public-default token. The
dev server binds `127.0.0.1` by default (`TINA4_HOST=0.0.0.0` to expose it), refuses a
cross-origin `/__dev` mutation, and never serves `.env` through the file endpoints. Static
asset serving drops the `src/assets`/`assets` search directories and now honours
`TINA4_PUBLIC_DIR`. A reflected XSS in the `403` error page is closed
(`CGI.escapeHTML`-escaped now).

**Migration.** Move assets under the configured public directory. Set `TINA4_CSP` if you
depend on inline scripts or a third-party CDN.

### Breaking: Mongo, MSSQL, and file-upload footguns closed

An unparseable/unsupported MongoDB WHERE now raises instead of silently matching every
document (a DELETE/UPDATE with no WHERE is rejected); `truncate()` on Mongo now actually
empties the collection. The MSSQL adapter now raises on a genuinely unbindable parameter type
instead of silently stringifying it (was preventing an injection/corruption risk). A repeated
multipart file field now yields a list instead of silently dropping every upload but the
last; an over-limit upload now answers `413` mid-stream instead of after buffering the whole
body. Frond `{% include %}`/`{% extends %}`/`{% import %}` now raise on a path that escapes
the templates directory.

**Migration.** Add an explicit WHERE to any Mongo query relying on the old match-all
fallback, or call `truncate()`. Handle `request.files[x]` as a list when multiple files can
share a field name.

### Breaking: ORM write-path and AutoCrud parity fixes

`decimal_field` now emits a real `DECIMAL(p,s)` column instead of `REAL`, dropping precision
and scale. A foreign-key auto `related_name` is now smart-pluralized (`Category` ->
`categories`, not `categorys`). `validate()` on save now enforces length/type/format, where it
used to check only for `null` -- a model that previously saved an over-length or
wrong-format value now returns `false` from `save()` and writes nothing. `create_table()`
injects the configured `soft_delete_field` automatically. `load()`'s signature changes to
`load(filter, params, include)`, from `load(arg, params)` with no `include`, and it now
JSON-coerces json columns. AutoCrud returns `422` (was `500`) on an invalid create/update, and
never accepts `is_deleted` or a client-supplied primary key in the write body. `seed_table`'s
`seed:` keyword is dropped, `FakeData#boolean` returns a native `true`/`false` (was `0`/`1`),
and `seed_orm`'s idempotency skip is opt-in now via `idempotent:` (was unconditional -- it
silently returned `seeded: 0` when the table already held enough rows).

**Migration.** Update any accessor using the misspelled `categorys` name. Pass the RNG seed to
your own `FakeData` instance instead of `seed_table(seed: ...)`. Update any `load()` call
using the old positional shape.

### Breaking: response, database-adapter, and dev-tooling fixes

Responses gzip-compress when eligible; a cacheable 200 gets a strong ETag, and the
static-file ETag format is unified to `W/"<size>-<mtime>"` across all four frameworks. Error
pages can emit JSON now, not only HTML: `403`/`404`/`500` all negotiate `Accept`, and `404`
carries a `request_id`. An undecorated route emits only `200` in the OpenAPI spec;
`description` is omitted when unset instead of `description:""`. A route group's prefix join
is normalized to match PHP. `tina4ruby serve` now honours `TINA4_PORT`, where it used to read
only the bare `PORT` variable. `serverInfo.version` over MCP now reports the real framework
version instead of `1.0.0`. The inline `@tests` descriptor builders are renamed
`Tina4::Testing.assert_*` -> `expect_*`. `DatabaseAdapter::CONTRACT` was fictional (it named
methods no driver implemented, and omitted `execute_many`/`fetch_one`); `get_database_type`
existed on none of the seven drivers and is added to all of them. A legacy bracket-wrapped
log-level spelling that duplicated the variable name inside the brackets is rejected now; use
the plain level name (for example `TINA4_LOG_LEVEL=ALL`).

**Migration.** Rename any `assert_*` descriptor call to `expect_*`. Reconcile `TINA4_PORT` vs
bare `PORT` if your app set both. Expect every cache to revalidate once after upgrade, since
the static-file ETag format changed.

### Breaking: Messenger `inbox()` / `read()` item shapes (3.13.96 parity)

The IMAP read path is aligned to the settled cross-framework shape (Python is the
reference). Measured against live GreenMail.

**`inbox()` item is EXACTLY `{uid, subject, from, to, date, snippet, seen}`.**
- `from` and `to` are header STRINGS (`"Name <email>"`), not arrays of
  `{name, email}`.
- the `read` key is renamed `seen` (Boolean).
- `date` is ISO-8601.
- `flags` and `size` are dropped.
- a new `snippet` field carries decoded, transfer-decoded, tag-stripped plain
  text, truncated to 200 chars (no more raw base64 / no more absent field).

**`read()` item uses `body_text` / `body_html`** (renamed from `body` / `html`),
returns `from`/`to`/`cc` as STRINGS, an `attachments` array of
`{filename, content_type, size}`, and a `headers` Hash (Message-ID lives there).
The old `flags` / `read` / `raw` / `message_id` top-level keys are dropped
(`headers["Message-ID"]` replaces `message_id`).

**`inbox` and `read` are callable POSITIONALLY** — `inbox("INBOX", 10, 0)`,
`read(uid, "INBOX")` — as well as by keyword (both forms work).

**New methods:** `mark_unread`, `send_template` (renders a Frond template string
to HTML and sends), and `delete` (flags `\Deleted` + expunge; fails loud like the
other reads).

**`TINA4_MAIL_IMAP_USERNAME` / `_PASSWORD` are honoured**, falling back to
`TINA4_MAIL_USERNAME` / `_PASSWORD`. Ruby authenticated IMAP to the SMTP account,
so an app whose reading mailbox differed from its SMTP relay account read the
wrong mailbox. There are matching `imap_username:` / `imap_password:` constructor
args (explicit beats env, ADR-0041).

**Migration.** Code reading `item[:from].first[:email]` becomes
`item[:from]` (a string); `item[:read]` becomes `item[:seen]`; `msg[:body]` /
`msg[:html]` become `msg[:body_text]` / `msg[:body_html]`; `msg[:message_id]`
becomes `msg[:headers]["Message-ID"]`.

### Breaking: Swagger defaults, response codes, and operationId (3.13.96 parity)

Four measured cross-framework divergences in the OpenAPI generator, settled to
match the Python/PHP reference.

**`info.version` defaults to `1.0.0`, `info.description` to `""`.** Ruby defaulted
`info.version` to the FRAMEWORK version (`Tina4::VERSION`), so an undocumented app
claimed API `v3.13.x`. `info.version` is the APPLICATION's API version; it now
defaults to `1.0.0`. `info.description` defaults to empty instead of the canned
"Auto-generated API documentation". `TINA4_SWAGGER_VERSION` /
`TINA4_SWAGGER_DESCRIPTION` still override.

**An undecorated route emits only `200`; `401` appears only on a secured route.**
Ruby stamped `200/400/401/404/500` on EVERY operation, including a public GET,
advertising status codes nothing in the framework produces. Now an undecorated
route carries only `200`, and a route documented as secured also carries `401`.

**`operationId` preserves the path's underscores.** `/__health` and `/health`
both collapsed to `get_health` and then one got a `_2` suffix by registration
order. They now produce distinct `get___health` / `get_health` — an
operationId is a generated client's method name and must be stable and unique.

**AutoCrud emits `components.schemas`.** Generated write routes referenced a bare
`{"type":"object"}` request body. They now `$ref` a `components.schemas` entry
keyed by the model CLASS name, with a `required` array derived from column
nullability.

**Migration.** A generated client that hard-coded the app version from
`info.version`, or generated error handlers from the phantom `400/404/500`
responses, or a method name from the collapsed `get_health`, will regenerate to
the corrected shape. No runtime behaviour of a Tina4 server changes.

### Breaking: Messenger `uid` is a String, and `inbox()` pages newest first

Two cross-framework divergences, both MEASURED 2026-08-06 against live GreenMail
with all four frameworks asked the same question about the same mailbox.

    uid type    python str     php string   node string   ruby Integer
    page order  python P3,P2   php P3,P2    node P3,P2    ruby P2,P3

Ruby was the outlier on both.

**`uid` is now a String.** The documented contract says String in all four, so a
caller comparing `uid == "3"` got false in Ruby alone. `read()` / `mark_read()` /
`delete()` still accept a String or an Integer, so passing an id back in is
unchanged.

**`inbox()` and `search()` now page newest first.** `uid_search` was already
reversed and the page sliced correctly, but `uid_fetch` returns rows in SERVER
(ascending) order however the uids were asked for, silently re-sorting the page.
So `inbox(limit: 1)` returned the OLDEST message in Ruby and the NEWEST in the
other three - the most common inbox call there is.

**Migration.** Code doing `uid == 3` or `uid.to_i` keeps working; code relying on
`uid.is_a?(Integer)` does not. Code that took `inbox(limit: n).first` as the
oldest message in that page now gets the newest, which is what the other three
frameworks always returned.


This file is deliberately NOT a copy of those notes. Duplicating them is exactly how a
changelog rots into claiming a version that was never cut, so this file records only
UNRELEASED work. When a version ships, its notes go to the release notes above.

### Breaking (the queue store moved to the canonical cross-framework layout)

**Breaking: the file-backed queue's default store moved from
`<cwd>/.queue/<topic>/<id>.json` to
`<TINA4_QUEUE_PATH|data/queue>/<topic>/<id>.queue-data`. The DIRECTORY and the
FILE EXTENSION both changed.** No job is lost - see the migration note below.

Ruby was the odd one out. Python, PHP and Node all store jobs at
`<TINA4_QUEUE_PATH|data/queue>/<topic>/*.queue-data`. Ruby wrote
`<cwd>/.queue/<topic>/<id>.json` and read `TINA4_QUEUE_PATH` **nowhere**, so the
variable `.env.example` has documented all along ("Queue storage path (file
backend)") did nothing whatsoever: an operator who pointed the store at a
mounted volume kept writing to the container's ephemeral filesystem and lost
every queued job on restart, with no error and no warning.

The store's layout - root, topic segment, job extension, dead-letter directory -
is now defined once on `Tina4::Queue` (`base_path`, `topic_dirname`,
`topic_path`, `job_files`, `job_file`, `JOB_EXTENSION`,
`DEAD_LETTER_DIRNAME`) and is the single answer both the backend and the
dev-admin queue panel ask. The topic is sanitised to one path segment there,
in the one place that resolves it, because the panel takes its topic straight
off a query string.

**MIGRATION NOTE.** Nothing is required of you, and no job is stranded.

- The first time the file backend resolves its own store, it **moves** every
  `*.json` under `<cwd>/.queue/` into the new store, renaming to
  `*.queue-data` and preserving the `<topic>/`, `<topic>/reserved/` and
  `dead_letter/` structure. It logs `Queue: moved N job(s) ...` at INFO.
- It is a MOVE, never a copy, so a job cannot be delivered twice; it never
  overwrites a file already at the destination, so concurrent processes cannot
  clobber each other; and emptied legacy directories are removed, so the check
  costs one `Dir.exist?` afterwards.
- **If you had `TINA4_QUEUE_PATH` set:** it previously did nothing in Ruby, so
  your jobs are in `<cwd>/.queue` too. They move into the path you configured,
  which now works as it does in the other three frameworks.
- **If you did not:** your jobs move to `<cwd>/data/queue`.
- **If you construct `LiteBackend.new(dir: ...)` yourself:** that store is yours
  and is never touched.
- Add `data/queue/` to your `.gitignore`. Newly scaffolded projects get it.
- The rescue triggers on the legacy directory EXISTING, not on the new store
  being absent, so a rolling upgrade in which an old instance keeps writing to
  `.queue` still has those jobs collected.

Pending jobs and reservations now interoperate with a store written by Python,
PHP or Node. Dead letters still do not: Ruby keeps them in a shared
`<base>/dead_letter/` tagged by topic, where Python and Node use a per-topic
`<base>/<topic>/failed/`. That divergence is unchanged here.

### Fixed (the dev-admin queue panel listed a different store from the one it counted)

The panel's job list and its stats read different sources, so the two disagreed.
`GET /__dev/api/queue/topics` scanned a hardcoded `<cwd>/data/queue` that no
Ruby app ever wrote to, so it could not name a real topic. `GET /__dev/api/queue`
never listed pending or reserved jobs at all - only `queue.failed()` and
`queue.dead_letters()` - while its stats counted all four buckets, and it ignored
the `?status=` filter the panel's own badges have always sent.

Four defects, all the same shape - the list describes a different set from the
counts:

1. **The directory.** Both handlers re-derived the path instead of asking where
   the store is.
2. **The set.** Pending and reserved jobs were counted and never listed. A
   failed-but-retryable job - which lives in the PENDING directory - was counted
   by `stats.pending` and listed as `"failed"`: one job, two contradictory
   answers.
3. **max_retries.** Dead letters were listed via `queue.dead_letters()`, which
   filters on the max_retries of the Queue the dev admin itself constructed (3).
   An app configured `max_retries: 1` dead-letters at ONE attempt, and every one
   of those jobs was counted by `stats.failed` and never shown. The list now
   uses `max_retries: 0` - the same "no attempt-count filter" spelling
   `tina4ruby queue retry` already used.
4. **Duplicate JSON keys.** `job.merge(status: "...")` added a SYMBOL key beside
   the record's existing STRING one, so every job went out as
   `{"status":"dead", ..., "status":"dead_letter"}` - two `status` names in one
   object.

Every job now appears exactly once, in the bucket its own stat counts it in, so
`sum(pending, completed, failed, reserved) == jobs.length` by construction on a
quiescent store, and every `?status=` filter returns exactly what its stat
counts.

### Fixed (the documented sort spelling raised on real MongoDB, ADR-0036)

`cursor.sort("total", -1)` - the spelling this file documents - raised
`ArgumentError: wrong number of arguments (given 2, expected 0..1)` on a real
MongoDB, because `Mongo::Collection::View#sort` takes ONE spec document. The
list-of-pairs form was worse: it reached the server as an ARRAY and came back

```
[14:TypeMismatch]: Expected field sort to be of type object
```

so of the three spellings the fallback accepted, only the hash form survived the
swap - and it was not the documented one.

`sort` now normalises all three to the driver's single spec document, so
`sort("total", -1)`, `sort({ "total" => -1 })` and `sort([["total", -1]])` are
equivalent on both providers. Ruby's fallback `Cursor` already accepted all
three; it is the DRIVER side that was narrow, and `MongoView` now bridges it.

  NOT affected: Ruby's chain was already lazy on both providers, because a
  `Mongo::Collection::View` is lazy and immutable. PHP's was not, and ADR-0036
  fixes that separately.

  MEASURED 2026-08-04 against a real MongoDB 7.0.39: 4 chain cases x 2 providers
  x 4 frameworks = 32 combinations, of which **10 failed** before this change and
  0 fail after. Pinned by the substitutability suite in all four frameworks,
  which asserts every spelling on BOTH providers, that `skip` composes, that an
  ASCENDING sort actually ascends (a direction ignored outright would pass a
  descending-only test), and that the chain is LAZY - a document inserted after
  the chain is built but before it is iterated must appear.

### Fixed (the uniform DocStore spellings now work on the real provider, ADR-0035)

- `collection.find_one(filter)` and `cursor.to_list` worked on the SQLite
  fallback and did not exist on `Mongo::Collection`, so code that used them
  raised `NoMethodError` the moment `TINA4_MONGO_URI` was set. They now work on
  BOTH providers.

  `get_collection` returns `Tina4::DocStore::MongoCollection` on the Mongo path -
  a `SimpleDelegator` that adds the two methods and forwards the entire driver
  surface untouched. `aggregate`, `bulk_write`, `indexes`, `watch`, sessions and
  transactions are all still reachable; measured 2026-08-04 against a real
  MongoDB 7.0.39, with 0 fallback-only collection methods and 0 fallback-only
  cursor methods.

  ADDITIVE, not a replacement. `find(filter).first` and `to_a` are the driver's
  spellings, they are unchanged, and both forms return the same answer.

  ADR-0025 corollary 1 said to DELETE a method the driver lacks. ADR-0035
  supersedes that corollary only: a method may exist on the fallback when it
  also exists on what `get_collection` RETURNS, and Tina4 may supply it on both
  sides. The core rule and corollaries 2, 3 and 4 stand.

  Pinned by `spec/docstore_substitutability_spec.rb`, which reads a document
  back through every spelling on BOTH providers and measures the fallback's
  public methods against the wrapped driver rather than a hand-kept list.

  **Breaking: on the Mongo path `get_collection` now returns a delegator, so a
  CLASS check answers differently.** Every method call, `==` against the raw
  collection, and the whole driver surface behave exactly as before, but

      Tina4::DocStore.get_collection("x").is_a?(Mongo::Collection)   # was true, now false
      Tina4::DocStore.get_collection("x").class                      # was Mongo::Collection

  **Migration:** stop type-checking the return, or reach the real object with
  `__getobj__`:

      collection.__getobj__.is_a?(Mongo::Collection)   # true

  Nothing in the framework type-checks it; this is stated because a user
  application might.

  KNOWN and NOT fixed here: the fallback `Cursor#sort(key, direction)` takes two
  arguments and `Mongo::Collection::View#sort` takes one. Use the hash spelling
  `sort({ "total" => -1 })`, which both providers accept.

### Breaking (DocStore: a missing MongoDB driver now raises)

`TINA4_MONGO_URI` set with the `mongo` gem NOT installed used to return the local SQLite collection. It now
raises `Tina4::DocStore::DocStoreDriverMissing`, naming the provider and what is missing (ADR-0033,
applying ADR-0024 rule 3).

Re-measured 2026-08-04 at `v3` HEAD in a REAL driverless environment - no mock, no
faked import - one env produced two shapes and four messages across the family:
Python, PHP and Ruby silently returned the local SQLite store, Node threw a bare
`ERR_MODULE_NOT_FOUND`. Silent degradation here means production writes landing in a
container-local file nobody reads, which vanishes on the next deploy, with no error at
any point.

**Migration - one of two lines:**

```
gem install mongo            # use the real provider
unset TINA4_MONGO_URI        # or use the local SQLite store, explicitly
```

Also changed: `serverless?` is now CONFIGURATION ONLY. It used to also return true when the gem was absent, which is
what routed the call into the local branch; without this an app branching on it would
take the local path and never reach the raise. The error message names the env var that
supplied the URI and never its VALUE, because a Mongo URI routinely carries
`user:password@` and an error string is the most-logged text a framework emits.

### Breaking (the query-cache key carried no database identity)

**Breaking: every existing persistent query-cache entry becomes a miss on upgrade.**

`Database#cache_key` was `sha256(sql + params)` with nothing naming the connection, so
on ANY shared cache backend two databases cross-served each other's rows. Two apps
pointed at one Redis, or one app with a primary and an analytics connection, silently
read each other's data. Identical SQL text across tenants is the COMMON case in a
multi-tenant deployment, not an edge case, so the collision was the normal outcome.
This is a data-isolation failure, not a caching inefficiency.

The key is now `sha256(engine://host:port/database \0 sql \0 params)`. Credentials are
deliberately excluded: a password in the key would cold-start the cache on every
rotation, and a shared backend's key namespace is readable by every tenant of that
backend. Nothing per-process is included either (no pid, no object_id, no salt) - that
would isolate the databases by accident and destroy the point of a shared cache, since
no instance would ever hit another instance's entry.

**Migration:** the key format changed, so entries written by an earlier version are
unreachable and simply miss. A cold cache is safe - it costs one repopulating read per
key. Cross-served rows are not safe, which is why this ships as a break rather than a
compatibility shim. Nothing needs to be run: no config change, no manual flush. If you
would rather not carry the dead entries until their TTL expires, call `db.cache_clear`
once after deploying.

### Fixed (queue operations acted on the local file store, not the configured backend)

Every operation must act on the CONFIGURED backend. These calls appeared to succeed
while operating on the wrong data, which is the worst failure class because nothing
surfaces it. `pop_by_id` was broken in ALL FOUR frameworks.

- `clear()` and `pop_by_id()` returned `0`/`nil` because `MongoBackend` had NEITHER
  method and `Queue` guarded on `respond_to?`. Clearing a mongo-backed queue was a
  no-op that looked exactly like an already-empty queue. Both are implemented on
  mongodb now, and the guards raise a named refusal instead of a silent 0/nil.

### Fixed (a queue method could be a fatal error instead of resolving)

Every public `Queue` method must RESOLVE on every backend the framework offers. A
method that does not exist cannot even reach a refusal, so the upgrade path is
severed rather than degraded.

- `queue.size` raised `NoMethodError` on the kafka backend, which simply had no
  `size` method. It now answers `0` - the value ADR-0022 decision 5 already records,
  and the one Python and PHP already gave. A log has no queue depth, and computing
  one means an admin round-trip per call.

### Fixed (queue priority was ignored on every backend but file)

- `push(..., priority)` is now honoured on the `mongodb` backend: priority is stored
  top-level and the dequeue sorts highest-first, ties oldest-first — the same policy
  the file backend already applied. An urgent job queued behind a backlog used to wait
  for all of it in production while prioritising correctly in development. Here the Mongo backend never WROTE the field its own `dequeue` read back
  (`doc["priority"] || 0`), so every job scored 0, and it sorted on `created_at`
  alone.
- **Breaking:** pushing with a priority to `rabbitmq` or `kafka` now RAISES, naming the
  backend and the operation, instead of silently discarding it. A RabbitMQ queue is
  FIFO: native priority needs the queue DECLARED with `x-max-priority`, and an existing
  queue cannot be redeclared with one (the broker answers PRECONDITION_FAILED), so
  switching it on would break every queue already in service. Kafka has no priority
  concept at all. Migration: use the `file` or `mongodb` backend for prioritised jobs.
  A push with priority 0 (the default) is unaffected.

### Fixed (a queue delay was silently dropped on every non-file backend)

- `push(..., delay)` is now honoured on the `mongodb` backend. It was silently DROPPED
  on every non-file backend in ALL FOUR frameworks, so a scheduled job fired immediately
  in production and on time in development. Here the Mongo backend never WROTE the `available_at` that `Queue#push` had already
  computed, AND its `dequeue` never FILTERED on it. Writing the field alone would
  have changed nothing.
- **Breaking:** pushing with a delay to `rabbitmq` or `kafka` now RAISES, naming the
  backend and the operation, instead of silently discarding the delay. Neither broker
  has a per-message delay: RabbitMQ's delayed-message-exchange is a non-core plugin and
  the TTL + dead-letter workaround head-of-line blocks, and Kafka reads a partition in
  offset order. Migration: use the `file` or `mongodb` backend for delayed jobs, or
  schedule the push itself. A push with no delay is unaffected.

### Fixed (an unknown queue backend name silently used the file store)

- An unrecognised `TINA4_QUEUE_BACKEND` now RAISES, naming the bad value and the
  valid set, instead of falling through to the local file store. The name is also
  normalised (trimmed + lowercased), so ` RabbitMQ ` resolves.

  WHY: MEASURED 2026-08-03. A typo in `TINA4_QUEUE_BACKEND` produced a RUNNING app
  writing every job to local disk while the operator believed they were in
  RabbitMQ - jobs nothing consumes, on a container filesystem that vanishes on
  the next deploy, with no error at any point.

      python   raised, named the valid set     <- already correct
      ruby     raised, named the valid set     <- already correct
      php      SILENT FALLBACK to file
      nodejs   SILENT FALLBACK to file

  This is the same rule the SESSION backend already adopted, for the same
  reason, so two of four were simply behind.

  Ruby-specific, found while proving the shared case: `.downcase.strip` bound
  only to the `ENV.fetch` branch, so an explicit `Queue.new(backend: "FILE")`
  raised while the identical spelling in `TINA4_QUEUE_BACKEND` resolved - and
  while python, php and nodejs all accepted it. Both sources are normalised now.
  Python is master on internal API design.

  Pinned by `spec/queue_backend_validation_spec.rb`, with a negative case asserting the guard still accepts
  every documented name - without it, "make everything raise" would pass.
  Mutation-proved in both directions (guard disabled, normalisation removed).

### Fixed (array queries diverged from MongoDB, ADR-0025 clause 4)

- A query against an ARRAY field now behaves the way MongoDB behaves. The rule is
  one sentence: a condition on an array-valued field matches when ANY ELEMENT
  matches it (or the whole array equals the operand), and a negation matches when
  NO element does. Implemented over SQLite's `json_each`.

  WHY: MEASURED 2026-08-03 against a real MongoDB with an 18-case matrix. EIGHT
  behaviours diverged IDENTICALLY in all four frameworks, which is the signature
  of a contract nobody had written down:

      tags = "x" against ["x","y"]      mongo 1, fallback 0   (containment)
      tags $in ["x"]                    mongo 1, fallback 0
      nums = 1 against [1,2,3]          mongo 1, fallback 0
      nums $lt 2 against [1,2,3]        mongo 1, fallback 0
      tags $regex "^x$"                 mongo 1, fallback 0
      tags $nin ["x"]                   mongo 0, fallback 1   <- FALSE POSITIVE
      tags $ne "x"                      mongo 0, fallback 1   <- FALSE POSITIVE
      nums $gt 9 against [1,2,3]        mongo 0, fallback 1   <- FALSE POSITIVE

  The three false positives are the worst of it: the fallback returned documents
  Mongo EXCLUDES. `nums $gt 9` matched [1,2,3] because json_extract of an array
  returns its JSON TEXT and SQLite sorts any text above any number - a wrong
  answer, not a missing feature.

  Also fixed in the same pass: an object field is no longer matched by one of its
  values, and IS matched by the whole object.

  Pinned by `spec/docstore_substitutability_spec.rb`, which runs a 20-case matrix against BOTH providers and
  asserts they return the SAME counts - not a hard-coded number, so the test
  cannot drift towards whatever the fallback happens to do. Mutation-proved by
  removing the array branch from equality.

### Fixed (DocStore leaked a Mongo client per call, ADR-0025)

- `get_collection` cached the connected client instead of building a new one on every
  call. Added `Tina4::DocStore.close_doc_store` to close every Mongo client and the SQLite store.

  WHY: MEASURED 2026-08-03 against a real MongoDB - 20 calls left 60 server
  connections open, growing LINEARLY and without bound. It was invisible in
  development, because the SQLite fallback opens no connections at all: a
  resource leak that existed ONLY after the swap to the real provider, and that
  exhausts the server rather than erroring.

  The cache is keyed per (uri, database) so a reconfigure gets its own client, and it is
  guarded against the check-then-act race in which two concurrent first-callers
  both build a client and one is orphaned - the same leak, just rarer.

  Pinned by `spec/docstore_substitutability_spec.rb`, which drives three identical rounds plus 100 further
  calls and asserts the growth PLATEAUS. That is the distinction that matters: a
  pool legitimately opens several connections and then flattens; a leak keeps
  climbing. Mutation-proved by restoring one-client-per-call.

  NOT affected: PHP. Its ext-mongodb driver pools at the libmongoc level, so
  many Client objects sharing a URI share one pool - measured 0 growth over 60
  calls. It gets the same named test anyway, because correct-for-a-reason-we-did-
  not-choose is exactly what regresses silently.

## Unreleased

### Breaking: the rate limiter keys on the socket peer, not X-Forwarded-For

`X-Forwarded-For` is written by whoever sends it. Reading it unconditionally let
any client pick its own rate-limit bucket, and - worse - pick SOMEONE ELSE'S,
exhausting a third party's quota. Measured with `TINA4_RATE_LIMIT=3`: a rotating
`X-Forwarded-For` scored 200,200,200,200,200,200 where a fixed one correctly
scored 200,200,200,429,429,429.

`X-Forwarded-For` and `X-Real-IP` are now read ONLY when the raw socket peer is
listed in the new `TINA4_TRUSTED_PROXIES`. Within the chain the RIGHTMOST hop
that is not itself a trusted proxy wins, matching Rack and Express (a client can
prepend its own hop, so the leftmost entry is attacker-controlled even behind a
real proxy).

**Migration.** If your app runs behind a proxy, load balancer or ingress, set
`TINA4_TRUSTED_PROXIES` to that proxy's address or range. It accepts a
comma-separated mix of exact addresses and CIDR ranges, IPv4 and IPv6:

```
TINA4_TRUSTED_PROXIES=10.0.0.0/8
TINA4_TRUSTED_PROXIES=192.168.1.5, ::1, fd00::/8
```

It is EMPTY by default, which means trust nothing. If you leave it unset behind a
proxy, every client is bucketed under the proxy's address and you will
over-limit. That is deliberate: over-limiting is a degraded service, while the
previous behaviour was an open door. Direct-to-internet apps need no change.

See ADR-0019.
### Auth: the `jwt` gem is gone, RS256 is opt-in stdlib OpenSSL

`tina4ruby` no longer depends on the `jwt` gem. Runtime dependencies drop from 12 to 11.
Every JWT is now signed and verified with stdlib OpenSSL: `OpenSSL::HMAC` for the standard
HS256/HS384/HS512 family, and `OpenSSL::PKey::RSA#sign`/`#verify` for the opt-in RS256. The
gem was only ever wrapping the base64url `header.payload.signature` envelope that
`lib/tina4/auth.rb` already builds for its HMAC path, so it bought nothing and cost a
dependency. Tokens are unchanged on the wire: an RS256 token minted by the new code verifies
under PHP `openssl_verify` and Node `crypto.createVerify`, and a tampered payload is rejected
by both.

HMAC (HS256/HS384/HS512) is the standard algorithm family across all four frameworks and is
zero-dependency in each. RS256 stays available in Ruby, opt-in via key presence
(`.keys/private.pem` + `.keys/public.pem` with a blank `TINA4_SECRET`), and needs no library.
If a Ruby build somehow lacks `OpenSSL::PKey::RSA`, the RS256 path raises
`NotImplementedError` naming what is missing and the remedy, instead of failing silently.

Note that HMAC is symmetric: every service that VERIFIES a token holds the secret that SIGNS
it, so any verifier can also mint tokens. That is fine for one app or a trusted fleet, and
wrong when handing tokens to a third party you do not control. Use RS256 there, so a verifier
can hold only the public key.

Algorithm pinning is unchanged and now explicitly covered: under an HMAC configuration a
token whose header claims `RS256` is rejected, and `alg: "none"` is rejected, even when the
accompanying signature is a genuinely valid HMAC. See `spec/auth_rs256_optin_spec.rb`.

**Breaking:** `Tina4::Auth.valid_token_detail` (alias `validate_token`) previously reported
the `jwt` gem's own wording on the RS256 path - `{ valid: false, error: "Token expired" }`
for an expired token, and the gem's raw decode message for anything else. Both paths now
report the single HMAC-path wording, `{ valid: false, error: "Invalid or expired token" }`.
*Migration:* do not branch on the `error` STRING. Test `result[:valid]`, which is unchanged,
and read `result[:payload]` on success. Applications that matched `error == "Token expired"`
to distinguish expiry from a bad signature must instead inspect the `exp` claim themselves
via `Tina4::Auth.get_payload(token)`. This aligns the RS256 detail shape with the HMAC one,
so the response no longer depends on which algorithm signed.

### Security: the auth + session contract (ADR-0021)

**Breaking:** the API-key auth result is now `{ "_auth" => "api_key" }` instead of
`{ "api_key" => true }`, in `Tina4::Auth.authenticate_request`, the `env["tina4.auth"]`
set by `Tina4::Auth.bearer_auth`, and the `env["tina4.auth_payload"]` set by the
write-route gate. *Migration:* replace `payload["api_key"]` with
`payload["_auth"] == "api_key"`. PHP and Node already used `_auth`; Python moved to it
in the same change, so the same successful auth no longer reads three different ways
across the four frameworks.

Also in this change:

- **Breaking: strict session mode.** A session id is now adopted only when it is BOTH a well-formed opaque id
  (`Tina4::Session.valid_session_id?`, `/\A[A-Za-z0-9_-]{1,128}\z/` — the constraint is
  the alphabet, there is deliberately no entropy floor) AND an id the backend already
  holds a session under. Anything else is DISCARDED and a fresh `SecureRandom.hex(32)`
  minted. This is OWASP strict mode / PHP's `session.use_strict_mode=1`, and it closes
  session fixation: Ruby previously adopted any cookie id, so an attacker could plant
  one, wait for the victim to log in under it, and already hold the authenticated
  session id. A backend OUTAGE is deliberately not treated as "unknown" — it logs and
  still adopts, so one Redis blip cannot rotate every id at once.

  Strict mode on its own logs NOBODY out: an id the backend already holds is still
  adopted, on every backend. (An earlier draft of this bullet claimed a one-time
  logout for everyone. That was wrong. The one-time logout is caused by the filename
  change in the next bullet, and it reaches the FILE backend only.)
- **Breaking: session filenames are a SHA-256 of the id.** `FileHandler#session_path`
  did `gsub(/[^a-zA-Z0-9_-]/, "")` — traversal-safe but LOSSY, so `a/b` and `ab` both
  became `sess_ab.json` and one user's session data surfaced under another user's id.
  It is now `sess_<sha256(id)>.json`, parity with Python's `FileSessionHandler._file`.

  **This invalidates live sessions on the FILE backend ONLY.** An existing
  `sess_<id>.json` is not found under the new name, so those users are handed a fresh
  session and sign in again once. Do not tell operators on the other backends that
  everyone is logged out - it is not true for them. Verified backend by backend
  against this release:

  | session backend | live sessions after upgrade | why |
  | --- | --- | --- |
  | file | LOST, sign in again once | filename moved from `sess_<stripped-id>.json` to `sess_<sha256(id)>.json` |
  | redis | survive | key is still `tina4:session:<id>`, the raw id |
  | valkey | survive | key is still `tina4:session:<id>`, the raw id |
  | mongodb | survive | `_id` is still the raw id |
  | database | survive | `tina4_session.session_id` is still the raw id |
  | memcached | not applicable | new session backend in this release, no prior sessions to lose |

  The memcached handler hashes a key only when the composed key would exceed
  memcached's 250-byte limit or carry a control character, so a normal id is stored
  under the raw value there too.

  *Migration:* nothing to run. On the file backend, expect one round of sign-ins on
  the deploy, so avoid shipping it in the middle of a checkout flow or alongside a
  change that assumes a warm session. Delete stale `sessions/sess_*.json` at your
  leisure; they are unreadable, not dangerous.
- **A malformed `exp`/`nbf` no longer reads as "no constraint".** RFC 7519 s2 defines
  them as NumericDate; the check was `payload["exp"] && ...`, so `exp: null` or
  `exp: false` skipped it entirely and the token never expired. A present-but-non-numeric
  claim now rejects the token. A token with no `exp`/`nbf` key at all stays
  unconstrained (non-breaking).
- **`authenticate_request` / `bearer_auth` check the JWT BEFORE the API key**, matching
  Python, PHP and Node.
- **The write-route gate compares the API key timing-safely.** `RackApp.enforce_route_auth`
  used a plain `token == api_key`, which returns as soon as two bytes differ and leaks
  the key prefix through response timing; it now routes through
  `Tina4::Auth.validate_api_key` (`OpenSSL.fixed_length_secure_compare`).

Locked in by `spec/auth_session_contract_spec.rb`, whose example names are identical in
all four frameworks.

### Breaking: `Session#get` returns a STORED false instead of the default

`Tina4::Session#get` was `@data[key.to_s] || default`, and `||` hands back the
caller's default for ANY falsy stored value. A legitimately stored `false` read back
as `true` whenever the caller passed `true` as the default - so
`session.get("marketing_opt_in", true)` reported opted-IN for a user who had
explicitly opted OUT. It is now `value.nil? ? default : value`, which keys off
PRESENCE, matching Python's `dict.get(key, default)`.

The `nil?` form is deliberate rather than `@data.key?(k) ? @data[k] : default`: both
fix the `false` case, but the `key?` form would also make a stored `nil` win over the
default, which is a second behaviour change nobody asked for.

**Migration.** Read the call sites where you pass a TRUTHY default and can store a
`false` under that key - typically feature flags, consent and opt-out flags. Those
now return the stored `false` where they used to return your default. A key that was
never stored still returns the default, unchanged. Python, PHP and Node were already
correct here; only Ruby moves.

Locked by the cross-framework example `session get returns a stored false instead of
the default`, whose name is identical in all four repos.

### Breaking: the response cache obeys RFC 9111 (Authorization and Vary)

The response cache keyed entries on method plus URL, with NO request header in
the key. It is a shared, server-side store, so on a secured GET route the first
caller's body was served to every later caller of the same URL. Measured
end-to-end on a real secured route: a valid token for `bob` returned alice's
private body with `X-Cache: HIT`. In Node, where route middleware runs before
the auth gate, an ANONYMOUS request returned 200 with alice's body.

Two RFC 9111 rules now apply, as they do in Varnish, nginx and Rails:

- Section 3 / 3.5: a response to a request carrying `Authorization` is NOT
  stored unless the response carries `Cache-Control: public`, `s-maxage` or
  `must-revalidate`.
- Section 4.1: `Vary` is honoured. The nominated request headers are recorded
  with the entry and must match on lookup; an absent field matches only an
  absent field. `Vary: *` is never stored.

**Migration.** Authenticated GETs are no longer cached by default. If a
response body is genuinely identical for every caller, opt back in per
response:

```ruby
response.headers["Cache-Control"] = "public"
```

Only add it where the body carries nothing user-specific. Public GET caching is
unchanged. See ADR-0020 and `plan/v3/features/043-caching.md`.

### Breaking: an unknown TINA4_CACHE_BACKEND raises instead of falling back to memory

An unrecognised name silently became an in-process memory cache, so a typo
(`TINA4_CACHE_BACKEND=redsi`) produced a running app that shared nothing while the
operator believed it was Redis. It now raises, naming the bad value and the valid
set - the contract `TINA4_SESSION_BACKEND` already uses.

**Migration.** Fix the spelling. Valid: `memory`, `file`, `redis`, `valkey`,
`memcached`, `mongodb`, `database` (plus the aliases `memcache`, `mongo`, `db`).

### Security: a before hook that refuses without returning the pair no longer runs the handler

A `before_*` middleware hook that set a 4xx status and returned `nil` did NOT
short-circuit - the response carried the 403 but the route handler ran anyway.
The `status_code >= 400` check was nested INSIDE the "did the hook return a
2-element Array" branch, so refusal was only honoured for hooks that also
returned `[request, response]`. Any auth/guard middleware written as

```ruby
def self.before_auth(request, response)
  response.json({ error: "denied" }, 403) unless authorised?(request)
end
```

executed its protected handler. Reproduced with a real `Tina4::Request` /
`Tina4::Response`: the pair-returning form returned `false` (correct), the
nil-returning form returned `true`. The check is now unconditional after EVERY
hook call, matching Python, PHP and Node (Rails short-circuits on the response
STATE, not on what the filter returned).

Regression test: `a before hook that sets 4xx and returns nothing skips the
handler` in `spec/middleware_pipeline_characterisation_spec.rb`.

### Fixed: per-route class middleware now runs its before_*/after_* hooks

`Route#run_middleware` called `mw.call(request, response)` on every attached
middleware. A class declaring `def self.before_auth` does not respond to
`.call`, so per-route class middleware raised `NoMethodError` and the
dispatcher turned every such request into a clean 500. **In Ruby this is
broken-to-working, not inert-to-active**: the documented per-route
`before_*`/`after_*` mechanism did not silently do nothing, it 500'd. (In PHP
and Node the equivalent fix makes previously-INERT middleware start running -
that difference matters when reading those changelogs.)

Per-route class middleware now goes through `Tina4::Middleware.run_before` /
`run_after` - the SAME orchestrator, hook discovery and return-value table as
global middleware, not a second parallel runner. 2-arg callable ("filter")
middleware and 3-arg function middleware are unchanged.

**Migration:** if you attached a class with `before_*`/`after_*` hooks to a
route, those hooks now RUN. Routes that were returning 500 will start serving,
and a hook that refuses will now actually refuse. Audit any such middleware
before upgrading - it has never executed in production.

**Also breaking:** a halting per-route middleware used to answer with a
hardcoded `[403, text/html, "403 Forbidden"]`, discarding whatever the
middleware had set. The response the middleware SET is now sent - a 401 with
`WWW-Authenticate`, a 302 to `/login`, or a JSON error body all survive. A
middleware that halts having set nothing still gets a 403 (now
`{"error":"Forbidden","status":403}`, the same shape as the middleware 500).

### Middleware hook return values are one documented table

Applied to EVERY `before_*`/`after_*` hook at EVERY scope (global and
per-route):

| return value | meaning |
| --- | --- |
| a `Tina4::Response` | SHORT-CIRCUIT; that object IS the response, at ANY status |
| `[request, response]` | rebind both, continue |
| `false` | SHORT-CIRCUIT; send the response as set, 403 only if still default/empty |
| `nil` | continue |

The `Tina4::Response` row is the PRIMARY rule and is new: it is the only one
that can express a 302 redirect from middleware. The `status >= 400`
short-circuit is retained as a documented LEGACY COMPATIBILITY PATH so
middleware written before it keeps working.

Note for Ruby specifically: Ruby has implicit returns, so a hook whose last
expression is a chainable response call (`response.add_header(...)` returns
`self`) now short-circuits. End such hooks with `[request, response]` or `nil`.
Block-based handlers registered with `Tina4::Middleware.before(pattern) { }`
are deliberately NOT covered by the table - a block's value is its last
expression, so reading a returned Response as a refusal there would fire
constantly. They keep their "`false` halts" contract.

### String-form route middleware (Python/PHP/Node parity)

`middleware: ["ResponseCache"]` and `middleware: ["ResponseCache:300"]` now
resolve, via `Tina4::Router.resolve_string_middleware`. Ruby was the only one
of the four frameworks without the mechanism - a String reached
`mw.call(request, response)` and raised `NoMethodError`. One instance is
memoised per spec so the cache can actually hit across requests (PHP does the
same; Python gets it by resolving at registration). An unknown name raises
`ArgumentError` naming the known set - never a silent skip, which for an auth
middleware would mean serving the route unprotected. The registry holds
`ResponseCache` only, matching PHP and Node; unifying it with Python's larger
name list is scheduled separately.
### CORS denies by default, and never pairs the wildcard with credentials

**Breaking:** `TINA4_CORS_ORIGINS` defaulted to `*`, which allowed every origin
on a fresh install. It now defaults to UNSET, which denies every cross-origin
request: no `Access-Control-Allow-Origin` is sent, and the browser's own CORS
check blocks the request. Django, Rails and ASP.NET all require an explicit
policy before emitting any CORS header, and now so does Tina4.

**Migration:** name the origins your frontend runs on.

```
TINA4_CORS_ORIGINS=https://app.example.com
```

Comma-separate several. `TINA4_CORS_ORIGINS=*` restores the old allow-any
behaviour for anyone who wants it: only the DEFAULT changed, not the capability.
Non-browser clients (curl, server-to-server) never consult CORS and are
unaffected. The status code of a denied preflight is unchanged at 204.

Also in this change:

- `Access-Control-Allow-Origin: *` is never sent alongside
  `Access-Control-Allow-Credentials: true`. The Fetch Standard's CORS check
  treats `*` as a literal once the request carries credentials, so every browser
  rejects the pair. When both are configured the wildcard wins, credentials are
  dropped, and a warning names the fix.
- `Vary: Origin` is now sent whenever the allowed origin is computed from the
  request's `Origin` header, including when the origin is REJECTED. Without it a
  shared cache can store one origin's response and serve it to another
  (RFC 9110 s12.5.5). It is not sent for a constant `*`, which does not vary.
- Every rejected cross-origin request logs an actionable warning naming the
  origin, the environment variable, and the fix. Silence was the common thread
  in every defect this audit found.

See ADR-0018.

### Fixed: CORS headers now reach the actual response, not only the preflight

`Tina4::CorsMiddleware.apply_headers` was never called from the dispatch path.
Only the preflight was answered. A browser sent its preflight, got a 204 saying
yes, sent the real request, and received no `Access-Control-Allow-Origin`, so it
blocked the response. Cross-origin browser access did not work in ANY
configuration. `apply_cors` now runs as an `ALWAYS_STAGE`, so the headers also
survive a short-circuited 401 and the early-returning swagger and static paths.

Ruby was also the only framework of the four that emitted
`Access-Control-Allow-Origin: *` together with
`Access-Control-Allow-Credentials: true`. It no longer does.

`Tina4::CorsClassMiddleware` is now a thin adapter over `Tina4::CorsMiddleware`
instead of a second copy of the rules. The copy had already drifted three ways:
no wildcard guard, a `Referer` fallback (a `Referer` is a URL, not an origin),
and an allow-list miss that returned the FIRST allowed origin, stamping another
site's origin onto a rejected caller's response. The `Referer` fallback is gone.

### CORS preflight responses now carry `Allow`

A CORS preflight (`OPTIONS` with an `Origin`) returned 204 with the
`Access-Control-*` headers but no `Allow`, while a bare `OPTIONS` to the same
path returned `Allow`. A preflight IS an OPTIONS response, so it now carries
`Allow` too, derived from the router's real method set (RFC 9110 s9.3.7).

This is conformance, not a deviation - see ADR-0013. The frameworks' own
OPTIONS handlers already emit `Allow` (Django's `View.options()`, Express's
router). The add-on CORS libraries omit it only because they short-circuit
ahead of the framework and skip its OPTIONS handler. Tina4 owns both paths in
one dispatcher.

`Allow` and `Access-Control-Allow-Methods` are NOT interchangeable: `Allow` is
what the RESOURCE supports, `Access-Control-Allow-Methods` is what the CORS
POLICY permits cross-origin (`TINA4_CORS_METHODS`, a static list as in every
mainstream library). A policy naming DELETE on a GET-only route is still a 405.

Non-breaking: one added response header on a 204; no existing header changes.


### Breaking: global middleware now runs before the auth gate

Dispatch order is now identical in all four frameworks:

```
pre-match globals -> match -> post-match globals -> auth gate -> route middleware -> handler
```

Ruby (and Python) previously ran the auth gate FIRST, so a global middleware
never saw a rejected request. That made a global rate limiter unable to throttle
a brute-force login, and dropped every 401 from an access log. Node and PHP
already ran the globals first; every mainstream framework does the same (Django
ships `CsrfViewMiddleware` ahead of `AuthenticationMiddleware` and enforces auth
in a view decorator after all `MIDDLEWARE`; Laravel runs the `web` group before
the `auth` route middleware; ASP.NET puts `UseAuthorization` last before the
endpoint). See ADR-0012.

**Migration:** a global middleware (registered via `Tina4::Middleware.use` /
`Router.use`) now runs on requests that are about to be rejected, including
401s. If yours assumes an authenticated request, check for it - `request.user`
is only populated after the gate. A middleware that must NOT see rejected
requests should be attached to the route instead of registered globally; route
middleware still runs after the gate.


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
