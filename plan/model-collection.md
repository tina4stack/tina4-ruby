# Task: Port ModelCollection ORM feature to tina4-ruby (ADR-0064)

Outcome: ORM read queries (where/select/find-filter/all/with_trashed) return a
Tina4::ModelCollection (an Array subclass) carrying the query total for free from
DatabaseResult#count. get_total_records + to_paginate identical to the Python
reference. Zero extra queries. Non-breaking (Array subclass).

## Scope
- [x] Read ADR-0064 + Python collection.py + Python test + Ruby DatabaseResult
- [x] Confirm db.fetch runs a COUNT probe -> DatabaseResult#count is the true filter-total
- [x] Confirm no in-repo `.class == Array` / tuple consumers break on an Array subclass
- [x] New file lib/tina4/model_collection.rb (one class per file)
- [x] require it in lib/tina4.rb before orm
- [x] Wire where/all/select/find_by_filter/with_trashed -> ModelCollection
- [x] find(pk) stays single; select_one/find_by_id/load stay single
- [x] spec/orm_model_collection_spec.rb mirroring tests/test_orm_model_collection.py
- [x] Mutation-check: total source = size -> 6 red incl total-outside-pagination (got 20) -> restored
- [x] Full rspec suite run at HEAD; 28 failures all PRE-EXISTING (proven identical on stashed base)

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| ModelCollection | done (ref) | pending | THIS | pending |

## Tests (real SQLite, no mocks, positive + negative)
- [x] total is outside pagination (250, limit 20 offset 40 -> len 20, total 250)
- [x] it IS an Array (each/[i]/map/count/slice unchanged)
- [x] to_paginate 7-key envelope; page/per_page/total_pages correct; == db.fetch to_paginate
- [x] every returning method carries the total (where/select/find-filter/all/with_trashed)
- [x] find(pk) returns a single model, not a collection
- [x] empty page still reports total; zero matches -> 0
- [x] soft-delete excluded from live total, included in with_trashed

## Bugs
- (found) crud.rb#fetch_model_data uses `total = records.length` on a where() with
  default limit 100 -> caps the search total at 100. Pre-existing, separate from
  ADR-0064, needs a 4-framework fix + tests. FLAGGED, not fixed here.

## Verification (macOS, Ruby 4.0.0, real SQLite; no lab services)
- New spec: 12 examples, 0 failures (spec/orm_model_collection_spec.rb)
- ORM/pagination/CRUD neighborhood: 132 examples, 0 failures
- Full suite: 5695 examples, 28 failures, 450 pending, 1 error outside examples
  - ALL 28 failures + the port-conflict error are PRE-EXISTING: proven byte-identical
    on the clean base (my wiring stashed) across all 10 affected files. Causes:
    unreachable memcached/valkey/postgres/mysql (no local services) + a Puma
    EADDRINUSE port race in compression_etag (passes 6/0 in isolation on both).
  - None touch ORM read paths; my change contributes 0 failures.

## Commits
- (feature/release3.13.132) ModelCollection port + find limit-forward parity fix

## Status: Complete
