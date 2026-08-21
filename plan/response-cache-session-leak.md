# ResponseCache session-leak fix (port of Python #117)

## Scope

`Tina4::ResponseCache#may_store?` in `lib/tina4/response_cache.rb`. The GET
response cache keys entries on method + URL only. `may_store?` guarded ONLY a
Vary `*` and the request `Authorization` header, so a request carrying a session
Cookie (Tina4 sessions ARE a cookie) with no Authorization fell through to
`return true` — a signed-in user's response was stored and REPLAYED (X-Cache:
HIT, handler skipped) to the next caller of that URL. Python fixed this in #117;
Ruby had not.

## Parity

Faithful port of `tina4_python/cache/__init__.py` `_may_store` /
`_cache_control_tokens` / `_shared_cache_allowed`. `may_store?` now:

1. false if the response Vary contains `*` (unchanged).
2. NEW: parse the response `Cache-Control` into directive NAME tokens
   (comma-split, `=value` stripped, so `no-cache="Set-Cookie"` counts as
   `no-cache` and a name never matches as a fragment). false if the set
   intersects `{no-store, private, no-cache}`.
3. `shared_cache_allowed?` if the request has an `Authorization` header.
4. NEW: `shared_cache_allowed?` if the request has a `Cookie` header.
5. NEW: `shared_cache_allowed?` if the response has a `Set-Cookie` header.
6. else true.

New private helpers `cache_control_tokens(carrier)` and
`shared_cache_allowed?(response)` (token-based, reuses `SHARED_CACHE_DIRECTIVES`
= public / s-maxage / must-revalidate). The Authorization-path behaviour and all
existing cache specs are unchanged.

## Tests

Added to `spec/response_cache_rfc9111_spec.rb`, driving the REAL
`Tina4::Request` / `Tina4::Response` through the REAL middleware hooks
(`before_cache` / `after_cache`) — no mocks/doubles. Gates:

- a response that sets Set-Cookie is not replayed to another session (core
  security regression: second visitor MISSes, handler reruns).
- a cookie-bearing request without a shared-cache directive is not cached.
- responses marked private / no-store / no-cache are not cached.

Controls (prove the cache is not merely disabled):

- a cookie-bearing request marked public still hits the cache.
- cookieless public traffic still hits the cache.

Mutation-proven: the three security gates FAIL against the pre-fix `may_store?`
and pass with the fix; the two controls are green both ways.

## Bugs

The leak itself: cookie-identified and Set-Cookie responses stored under a
method+URL key and replayed cross-session; and `no-store` / `private` /
`no-cache` were never honoured, so a handler had no way to keep a response out of
this shared cache.

## Commits

Branch `fix/response-cache-session-leak` off `v3`. One commit; no version bump.
PR to base `v3`.
