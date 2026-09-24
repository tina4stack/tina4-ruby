# Task: ORM field column read-back (field_mapping round-trips on every read path)

**Outcome:** parity with tina4-python's fix. Ruby has no per-field `column:` option;
`field_mapping` ({ "attribute" => "column" }) is the one resolver (`get_db_column`,
reversed by `attribute_for` / `from_hash`). Every read path now routes through it.

Depends on `fix/identifier-allow-list` (ADR-0069): this branch is rebased onto it, and
`attribute_for` is built on its `resolve_field`, so `find(hash)` uses that branch's resolver.

## Scope
- [x] Reproduce on origin/v3, real SQLite, PostgreSQL, MySQL, MSSQL, Firebird: 21 of 80 red
- [x] find_by_id addresses the PK COLUMN
- [x] pk_filter keys are PK COLUMNS (update / delete / restore / composite probe)
- [x] Relationships: lazy has_one / has_many / belongs_to, eager has_* / belongs_to (SQL column + attribute)
- [x] Seeder FK pool reads the parent's key COLUMN
- [x] PostgreSQL driver: last_id for a key not named "id" (lastval, guarded against a stale value)
- [x] Full suite on the lab: 5873 examples, 0 failures, 36 pending (all [needs:graph])

## Parity
| Path | Python | PHP | Ruby | Node |
|------|--------|-----|------|------|
| per-field column option | `Field(column=)` | none | none | none |
| read-back through the resolver | fixed | lock-in | fixed | fixed |

## Tests (written first, real, no mocks, positive + negative)
- [x] spec/orm_field_column_readback_spec.rb: 17 cases x 5 engines + 1 PostgreSQL case = 86 green
- [x] Mutation-proved: 15 fix sites each turn the spec red when reverted

## Bugs
- [x] find(pk) with a mapped primary key queried the attribute name
- [x] save (update) / delete / restore addressed the row by the attribute name
- [x] relationship SQL (lazy + eager) used attribute names as columns; eager grouping used the column spelling as a method
- [x] seeder FK pool selected the attribute name
- [x] PostgreSQL: auto-increment key not named "id" stayed nil after save

## Commits
- 7f09e67  ORM reads a field_mapping column back on every read path (on fix/identifier-allow-list, #52)

## Status: Complete
