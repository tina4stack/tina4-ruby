# Task: Port issue #123 `generate model` reserved-table fix to tina4-ruby

Outcome: `tina4ruby generate model Order` no longer renames the table SILENTLY.
It still auto-pluralises a reserved-word table (`order` -> `orders`, the SAFE
choice because Tina4 interpolates table names UNQUOTED) but SAYS SO out loud, and
`--table-name <name>` lets the developer force their own name (owning the quoting
if it is itself reserved). No ORM quoting change — identifier quoting is a global
storage invariant, not a local fix. Python master: `feature/release3.13.129`
(tina4-python, commit b5d8384). Branch: `feature/release3.13.129` off v3.

## Scope
- [x] Read Python master `_resolve_table` / `_to_table` / `_pluralize_table` /
      `SQL_RESERVED_TABLE_NAMES` / `_gen_model` + `test_gen_model_reserved_table.py`
- [x] Add `resolve_table(name, flags, announce:)` to `lib/tina4/cli.rb`
- [x] Route every table-deriving generator through it (model announces; crud/
      seeder/form/view stay quiet; build_model_resolution honours --table-name)
- [x] Advertise `--table-name <name>` in the `generate model` usage string
- [x] Add `spec/generate_model_reserved_table_spec.rb` (mirror the Python test)
- [x] Run new spec + existing generate/scaffolding/manifest specs green (no pending)

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| generate model reserved-table resolver (#123) | ✅ (master) | (separate) | ✅ | (separate) |

This task is the Ruby leg only (per the orchestrator). PHP/Node are separate ports.

## Tests (written to mirror tina4-python/tests/test_gen_model_reserved_table.py — real, no mocks)
- [x] resolver: non-reserved -> singular, silent
- [x] resolver: reserved -> plural + note WHEN announcing
- [x] resolver: reserved -> plural + SILENT when not announcing
- [x] resolver: `--table-name customer_orders` wins verbatim (no warning)
- [x] resolver: `--table-name select` (reserved) forced -> warning + obeyed
- [x] resolver: bare `--table-name` (true) ignored -> orders
- [x] e2e: `generate model Order` writes table_name "orders" + prints a note
- [x] e2e: `generate model Order --table-name my_orders` writes table_name "my_orders"

## Bugs
- (none found; faithful port)

## Verification (macOS, Ruby 4.0.2, bundled SQLite — no live engines needed)
- New spec: `TINA4_NO_BROWSER=true bundle exec rspec spec/generate_model_reserved_table_spec.rb`
  -> 11 examples, 0 failures, 0 pending.
- Mutation-proved both gates: flipping `generate_model` announce true->false reds the 2
  note tests; disabling the `--table-name` guard reds the 4 override tests. Restored -> green.
- Regression sweep (generate/scaffold/manifest/seeder-cli + envelope): 321 examples,
  0 failures, 7 pending — all 7 are PRE-EXISTING live-DB-engine gates in
  seeder_contract_spec (postgres@55432 / mssql@1433 / firebird), unrelated to this change.
- Real does-it-run: `exe/tina4ruby generate model Order` prints the note exactly once,
  writes `table_name "orders"`; `--table-name my_orders` writes `table_name "my_orders"`.

## Commits
- (hash  description — filled on commit)

## Status: Complete (Ruby leg)
