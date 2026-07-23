# Task: Fix Ruby parity defects D5, D6, D11, D12 (feature-recount audit)

Source: `/Users/andrevanzuydam/IdeaProjects/plan/v3/feature-recount.md` (defects table).
Branch: `v3` (tina4-ruby). Commit locally only — no push, no tag.

## Goal

Four confirmed Ruby-side defects surfaced by the 65-candidate feature audit:

| # | Defect | Kind |
|---|--------|------|
| D5 | `Tina4::Validator` unreachable after `require "tina4"` | parity gap (counted feature off the main surface) |
| D6 | `Tina4::TestClient` bypasses `RackApp` entirely | verification-layer lie |
| D11 | `tina4js.min.js` ships but is wired to nothing | dead asset |
| D12 | `CLAUDE.md` + `router.rb` doc drift | doc drift |

## Scope

- [x] Prove each defect against the WORKING TREE (forced `$LOAD_PATH`, print `VERSION` + `$LOADED_FEATURES`)
- [x] D5: put `Validator` on the main `require "tina4"` surface; drop the now-false generator note
- [x] D6: route `TestClient` through the real `Tina4::RackApp#call`
- [x] D6: audit existing specs that "passed" only because TestClient short-circuited
- [x] D11: wire `tina4js.min.js` into the scaffolded `base.twig` (matching Python/PHP)
- [x] D12: fix `QueryCache` location + the `.broken` sentinel surface claim
- [x] Lock-in specs (positive AND negative; negatives proven to fail pre-fix)
- [x] Full `bundle exec rspec` green at HEAD

## Parity

| Item | Python | PHP | Ruby | Node |
|------|--------|-----|------|------|
| Validator on main import surface | PRESENT | PRESENT | FIXED (was ABSENT) | PRESENT |
| TestClient routes through the real app pipeline | ABSENT (`Router.match` direct) | PARTIAL (`Router::dispatch`) | FIXED | ABSENT (direct match) |
| `tina4js.min.js` referenced by a shipped template | PRESENT (`example/src/templates/base.twig`) | PRESENT (`example/src/templates/base.twig`) | FIXED (scaffold `base.twig`) | ABSENT (static test only) |

D6 is a FOUR-framework gap, not Ruby-only — see "Open parity item" below.

## Tests (real, no mocks — real Rack pipeline, real TCP socket, real SQLite)

- [x] `spec/validator_surface_spec.rb` — Validator reachable after a bare `require "tina4"`, in a
      CLEAN child ruby process (negative: the old tree raises NameError there)
- [x] `spec/test_client_pipeline_spec.rb` — TestClient vs a REAL server on a REAL socket:
      `/swagger`, `/swagger/openapi.json`, a real static file, `/__health`, global middleware,
      HEAD, OPTIONS/405 Allow — status parity both ways
- [x] `spec/scaffold_tina4js_wiring_spec.rb` — real scaffold into a tmpdir, real boot, real socket
      GET of `/js/tina4js.min.js` + the generated `base.twig` referencing it
- [x] `spec/docs_truth_spec.rb` — asserts the CLAUDE.md / router.rb claims against the code

## Bugs

- [x] D5 fixed — `lib/tina4.rb` autoload entry
- [x] D6 fixed — `lib/tina4/test_client.rb` now dispatches through `RackApp#call`
- [x] D11 fixed — `lib/tina4/cli.rb` scaffolded `base.twig`
- [x] D12 fixed — `CLAUDE.md` (2 places) + `lib/tina4/router.rb:618`

## Open parity item (surfaced, NOT fixed here — out of scope)

`TestClient` bypasses the real request pipeline in Python (master), Node, and partially PHP too:

- Python `tina4_python/test_client/__init__.py:141` — `Router.match(...)` direct; an unmatched
  path returns a hand-built `{"error":"Not found"}` instead of the server's real 404.
- Node `packages/core/src/testClient.ts:165` — same hand-built `{"error":"Not found"}`.
- PHP `Tina4/TestClient.php:123` — `Router::dispatch(...)`, closer to the real path but not the
  full front-controller.

Ruby is now HONEST and therefore diverges from the master. Direction call for the owner: promote
the Ruby shape to Python/Node/PHP (recommended — the master's TestClient has the same
verification-layer lie), or revert Ruby to match. Do NOT close D6 as "parity" until that lands.

## Status: Complete (Ruby); cross-framework D6 parity OPEN
