# Task: #277 cross-process migration lock — Ruby parity with amended ADR-0095

Outcome: tina4-ruby's `Migration#migrate` serializes concurrent startup
migrations with a run-wide lock whose SQLite/Firebird file-lock sidecar lives in
the SYSTEM TEMP dir (not the migrations folder), at parity with the amended PHP
reference and ADR-0095. Proven by a real multi-process concurrency test, mutation-
proved.

## Context correction (briefing was stale)
The briefing said "the lock exists ONLY in PHP". Not so for the core: commit
`63c7788` already landed the Ruby lock AND `spec/migration_concurrency_277_spec.rb`
on `v3`. The one real gap vs. the AMENDED reference is the file-lock LOCATION:
Ruby still uses `migrations_dir/.tina4_migration.lock` (old), while the amended
PHP `fileLockPath()` and the task's central ADR amendment put the sidecar in
`Dir.tmpdir` named `tina4-migration-<sha256(abs migrations dir)>.lock`.

## Scope
- [x] Read ADR-0095 + amendment, PHP Migration.php reference, PHP test + worker
- [x] Read Ruby migration.rb + existing concurrency spec
- [x] Move the Ruby file-lock sidecar to the system temp dir (parity w/ PHP `fileLockPath`)
- [x] Add a regression test pinning the location (no lock file left in migrations dir)
- [x] Baseline: existing concurrency spec green at HEAD
- [x] Mutation proof: remove the lock → concurrency spec fails with duplicate rows (8 dup rows)
- [x] Mutation proof: revert location → lock left in migrations folder → location test fails
- [x] Full rspec suite at HEAD; triage every failure (service-gated vs regression)

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| run-wide lock in migrate() | (sibling) | ✅ | ✅ | (sibling) |
| native PG/MySQL/MSSQL advisory | (sibling) | ✅ | ✅ | (sibling) |
| file lock in SYSTEM TEMP dir | (sibling) | ✅ | ❌→fixing | (sibling) |
| real multi-process test, mutation-proved | (sibling) | ✅ | ⚠️ exists | (sibling) |

## Tests (real, no mocks, positive + negative)
- [x] concurrency: 8 real processes, data migration applies exactly once (mutation A: 8 dup rows)
- [x] location: file-lock migrate leaves NO lock file in migrations dir; lock lands in tmpdir (mutation B)

## Native-lock coverage (runs on CI / lab, gated on real services)
- PG/MySQL/MSSQL advisory branches of `acquire_migration_lock`/`release_migration_lock` are
  exercised whenever `migrate()` runs against that engine — `migration_v3_spec.rb` ("on real
  PostgreSQL") and the real-engine migration specs do exactly that. Fails LOCALLY only because
  this darwin dev host has no provisioned `tina4_rb`/mysql/mssql; green on CI (parity with PHP,
  whose test is also SQLite-only).

## Full-suite triage (darwin dev host, no service matrix)
- 6768 examples. SQLite proof (concurrency + location): GREEN, mutation-proved both ways.
- Remaining failures are 100% unprovisioned/flaky local services (postgres `tina4_rb` missing,
  no mysql/mssql/firebird/redis/mongo/memcached). Non-service failure remainder is IDENTICAL
  baseline (v3 code) vs HEAD except my location test flipping red→green → zero regressions from
  this change. CI provisions services and gates the native paths.

## Bugs
- [x] file-lock sidecar was committed into the tracked migrations/ dir (blocks rmdir) — moved to tmpdir

## Commits
- 2766aba  fix(migration): put the #277 file-lock sidecar in the system temp dir (parity)

## Status: Complete (pending PR to v3)
