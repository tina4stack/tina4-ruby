# Changelog

Tina4 keeps ONE version across all four frameworks (Python, PHP, Ruby, Node.js), so a version
number means the same thing everywhere.

**The authoritative release notes for every shipped version live in the documentation:**
https://tina4.com/ruby/36-releases

This file is deliberately NOT a copy of those notes. Duplicating them is exactly how a
changelog rots into claiming a version that was never cut, so this file records only
UNRELEASED work. When a version ships, its notes go to the release notes above.

### Fixed (the query-cache key carried no database identity)

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

### Breaking (DocStore find_one, ADR-0025)

- `Tina4::DocStore::SqliteCollection#find_one` is REMOVED. Use the driver's
  spelling, which works on both providers:

      collection.find_one(filter)   ->  collection.find(filter).first

  WHY: `find_one` does not exist on `Mongo::Collection`. It was a fallback-only
  accessor, and the framework's own documented Ruby example used it, so code
  written against the local SQLite store raised

      NoMethodError: undefined method 'find_one' for an instance of Mongo::Collection

  the moment `TINA4_MONGO_URI` was set. Loud rather than silent, but still a
  broken swap at the call site. Measured 2026-08-03 against a real MongoDB.

  ADR-0025 settles the general rule: the fallback imitates the driver, because
  the driver is the half that cannot be changed. Pinned by
  `spec/docstore_substitutability_spec.rb`, which reads a document back with
  `find(...).first` on BOTH providers and asserts `find_one` responds on
  NEITHER.

  NOT affected: `find_one_and_update` on the Mongo queue backend is a genuine
  `Mongo::Collection` method and is untouched.

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

### Breaking: per-route class middleware now runs its before_*/after_* hooks

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
