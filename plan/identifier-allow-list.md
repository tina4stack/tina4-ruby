# Task: Identifiers that reach SQL come from the model (ADR-0069)

**Outcome:** AutoCrud list filter/sort keys, ORM `find(hash)` keys, DocStore
SQLite-fallback field paths and the Ruby-only `Tina4::Crud` sort/write paths are
resolved against a fixed allow-list before any SQL is built. Anything that does
not resolve is rejected (API/ORM/DocStore), dropped (Crud writes) or replaced by
the default sort (the rendered Crud page).

## Scope
- [x] A. AutoCrud list route: `filter[KEY]` (any bracket content) and each `sort`
      part resolve through the model's declared fields (attribute name OR its mapped
      DB column); unknown -> 400 `UNKNOWN_FIELD` before any SQL
- [x] B. ORM `find(hash)` / `find_by_filter`: every key resolves through the SAME
      resolver (`ORM.resolve_field_column`); unknown -> `ArgumentError`
      "Unknown filter field 'KEY' for model <Name>" before any SQL; mapped attribute
      names are emitted as their DB column
- [x] C. DocStore SQLite fallback: every dot segment of every field path that
      reaches json_extract / json_type / json_each (filters at any depth, operator
      fields, sort keys) must match `[A-Za-z0-9_-]+`, validated at the single
      path-building chokepoint (`DocStore.json_path`)
- [x] Unchanged: `where()`, `select()`, `load()`, QueryBuilder, the raw `order_by:`
      argument of find/all/where
- [x] Ruby-only (found during this pass, lead-approved): `Crud.to_crud` `?sort`
      resolves to a declared model field or a column of the SQL query's own result
      set, else falls back to the primary key
- [x] Ruby-only (found during this pass, lead-approved): `Crud` SQL-mode POST/PUT
      routes allow-list the body against the table's real columns; unknown keys
      dropped, `is_deleted` never writable, PUT strips the pk
- [x] G3 (maintainer addendum 3): `Database#insert` / `#update` / `#delete` and their
      batch forms refuse any data or filter-map key that is not a plain identifier
      (`^[A-Za-z_][A-Za-z0-9_$]*$`) with ArgumentError "Invalid column name 'KEY'"
      before any SQL; valid names emitted unchanged
- [x] G1: AutoCrud POST/PUT bodies resolve through `ORM.resolve_field` (declared
      attribute or its mapped column); anything else dropped; is_deleted guard and
      PK strip kept
- [x] G2: ORM save writes only declared fields - Ruby already did; locked in
- [x] AutoCrud id routes + generated GraphQL address exactly one bound row
      (`ORM.coerce_primary_key`: integer key accepts only an integer string, string
      natural key bound unchanged)
- [x] CI: PostGIS service + `postgis` optional engine in the gate
- [x] D. AutoCrud list: a list/map `sort` (`sort[]=`, `sort[a]=`) and a nested
      filter key (`filter[name][]=`, `filter[name][x]=`) -> 400
      `INVALID_QUERY_PARAMETER` before any SQL
- [x] E. AutoCrud reads through the model's own connection (`self.db = ...`) -
      Ruby already did; locked in with a two-SQLite-file spec
- [x] F. TINA4_REQUIRE_SERVICES gate: a skip/pending passes only with an
      excusable `[needs:X]` tag (optional engine while its coordinate env var is
      unset; always-provisioned service never; platform tag always); untagged fails.
      Optional-engine and platform skip sites tagged

## Parity
| Item | Python | PHP | Ruby | Node |
|------|--------|-----|------|------|
| A. AutoCrud filter/sort allow-list | n/a (no filter/sort) | other worker | ✅ | other worker |
| B. ORM find key resolver | other worker | other worker | ✅ | other worker |
| C. DocStore path validation | other worker | other worker | ✅ | other worker |
| Crud.to_crud sort + SQL-mode writes | n/a (no to_crud) | n/a | ✅ | n/a |
| D. odd-typed query values -> 400 | n/a | other worker | ✅ | other worker |
| E. AutoCrud uses the model connection | other worker | other worker | ✅ (lock-in) | other worker |
| F. [needs:X] gate rule | other worker | other worker | ✅ | other worker |
| G1. AutoCrud write-body allow-list | other worker | other worker | ✅ | other worker |
| G2. ORM save writes declared fields only | other worker | other worker | ✅ (lock-in) | other worker |
| G3. db write helpers reject non-identifier keys | other worker | other worker | ✅ | other worker |

## Tests (written first, real - no mocks, positive + negative)
File: `spec/identifier_allow_list_contract_spec.rb`
- [x] unknown_filter_field_returns_400 (real SQLite, real dispatch via TestClient)
- [x] unknown_sort_field_returns_400
- [x] declared_filter_and_sort_still_work
- [x] orm_find_rejects_undeclared_filter_key (SQLite, PostgreSQL, MySQL, MSSQL, Firebird;
      an unreachable engine FAILS under TINA4_REQUIRE_SERVICES - proved with PG on port 1)
- [x] docstore_rejects_unsafe_field_path
- [x] docstore_accepts_safe_field_paths
- [x] docstore_safe_paths_match_on_real_mongo (real MongoDB, unique db, dropped after)
- [x] crud_to_crud_sort_accepts_only_known_columns
- [x] crud_sql_mode_writes_accept_only_table_columns
- [x] odd_typed_query_values_return_400
- [x] autocrud_list_uses_the_registered_connection (lock-in; red when ORM.db is
      forced to the global connection)
- [x] spec/require_services_gate_spec.rb: untagged fails (before(:all) and
      per-example, incl. the wordings the old phrase list missed), optional engine
      excused only while its coordinate is unset, always-provisioned service never
      excused, platform tag excused, gate off unchanged - real rspec subprocesses
- [x] autocrud_write_body_accepts_only_declared_fields (red: a mapped-column key was
      dropped)
- [x] orm_save_writes_only_declared_fields (lock-in; red when save carries
      undeclared keys)
- [x] db_write_helpers_reject_non_identifier_keys on SQLite, PostgreSQL, MySQL, MSSQL,
      Firebird (red: driver syntax errors instead of the ArgumentError)
- [x] autocrud_id_route_addresses_only_that_row (red: "3x" addressed row 3; a
      string natural key was looked up as 0)
- [x] graphql_id_argument_addresses_only_that_row (red: a non-matching id answered
      an internal error)
- [x] commas_are_insignificant_between_arguments_and_fields (spec/graphql_spec.rb;
      red: any comma-separated argument/field list was a parse error)
- [x] Red on unmodified code (every negative case), green after the fix
- [x] Mutation proof of each guard: AutoCrud filter, AutoCrud sort, ORM find,
      DocStore segment, Crud sort (model + SQL mode), Crud write column allow-list,
      Crud is_deleted block, Crud PUT pk strip, sort-not-a-string guard, nested
      filter guard, ORM model connection (E), and five gate-rule mutations - each
      went red, each restored
- [x] Full suite under TINA4_REQUIRE_SERVICES=1 locally (macOS, Ruby 4.0.7) before
      D/E/F: no new failures; the remaining failures/pending are identical on a clean
      origin/v3 checkout (see Bugs)
- [x] Full suite on the lab (Linux, Ruby 3.2.3, gate on, all engines + graph DBs +
      OIDC) at 3fd9e2c: 5773 examples, 9 failures, 0 pending, gate silent; the 9 are
      the pre-existing live-Ultipa examples (see Bugs)

## Bugs
- [x] AutoCrud list built filter conditions from any `\w+` key (declared or not) and
      silently ignored non-`\w` keys (653cfe8)
- [x] AutoCrud `sort` reached ORDER BY as unvalidated text (653cfe8)
- [x] ORM `find(hash)` emitted hash keys unvalidated and did not map an attribute name
      to its `field_mapping` column (653cfe8)
- [x] DocStore fallback quoted, rather than rejected, field-path segments outside
      `[A-Za-z0-9_-]` (653cfe8)
- [x] `field_mapping` comment said db_column => attribute; the code reads
      attribute => db_column (653cfe8)
- [x] `Crud.to_crud` put the raw `?sort` value into ORDER BY (f327531)
- [x] `Crud` SQL-mode POST/PUT passed body keys through as column names (366c7d3)
- [x] AutoCrud write bodies dropped a declared field named by its mapped column
      (d27d17f)
- [x] `Database#insert/#update/#delete` put any data/filter-map key into the SQL as a
      column name (9de56a0)
- [x] AutoCrud `id.to_i`: "3x" addressed row 3; a string natural key looked up 0
      (6b994c5)
- [x] Generated GraphQL update/delete raised LocalJumpError for a non-matching id
      (6b994c5)
- [x] GraphQL tokenizer emitted commas as punctuation that no parse loop skipped
      (350c8a7) - parity of Python/PHP/Node parsers not checked here
- [x] gis_contract_spec skipped on every CI run (PostGIS never provisioned)
      (15a84b8)
- [ ] Pre-existing on clean origin/v3, not caused by this change: session zero-gem
      subprocess specs (2) fail on `require "base64"` under Ruby 4.0; the PostgreSQL
      "connect timeout 0 = unbounded" spec fails against the local SSH tunnel; 47
      pending (10 MQTT TLS stale CA, 1 OIDC lab gate, 36 graph DBs not provisioned)
- [x] Gate gap: skip messages worded "no reachable ..." (nextid, pagination_clamp,
      docstore_substitutability) and "... unavailable" (cache_backends) matched none
      of the old phrase list, so they skipped green under TINA4_REQUIRE_SERVICES -
      replaced by the [needs:X] rule (87c440c, 28eda39)
- [x] AutoCrud ignored `?sort[]=` and reported `filter[name][]=` as an unknown field
      (9677fe0)
- [x] migration_dialect_firebird's `[needs:absent-lib=libfbclient]` would have excused
      a missing Firebird driver in a run that promises Firebird - retagged
      `[needs:firebird]` (998f42d)
- [ ] Pre-existing on the lab, not caused by this change: 9 live-Ultipa graph examples
      fail because the tina4-ultipa driver gem is not installed there (same 9 on
      origin/v3)

## Commits
- 653cfe8  AutoCrud, ORM find and DocStore accept only known field names
- f327531  Crud.to_crud sorts only by a known column
- 366c7d3  Crud SQL-mode write routes accept only the table's real columns
- 12edf53  ORM resolve_field_column maps through get_db_column (lead)
- 9677fe0  AutoCrud answers 400 for a list or nested sort and filter value
- 9875973  Lock in that AutoCrud reads through the model's own connection
- 87c440c  Require a [needs:...] tag for any skip under TINA4_REQUIRE_SERVICES
- 28eda39  Gate excuses a [needs:...] tag only by the shared four-framework rule
- 998f42d  Tag optional-engine and platform skips for the TINA4_REQUIRE_SERVICES gate
- 3fd9e2c  Gate reads only the canonical PostgreSQL coordinate TINA4_TEST_PG_URL
- e6c17d6  plan: addendum D/E/F
- d27d17f  AutoCrud write bodies accept declared fields by attribute or column
- ed9130e  Lock in that ORM save writes only declared fields
- 9de56a0  Database write helpers accept only plain identifier keys
- 15a84b8  Provision PostGIS in CI and gate the GIS spec as an optional engine
- 350c8a7  GraphQL parser treats commas as insignificant
- 6b994c5  AutoCrud id routes and generated GraphQL address exactly one bound row

## Status: Complete (local; lab run handled by the lead)
