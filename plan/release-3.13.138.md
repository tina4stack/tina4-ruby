# RUBY 3.13.138 release

## Goal
Ship the merged fixes and measured-estimate skills on the coordinated 3.13.138 release.

## Scope
- [x] Fresh release branch from origin/v3; no existing feature branch reused.
- [x] Read AGENTS and release instructions; inventory all commits since 3.13.137.
- [x] Update runtime version, current agent metadata and release changelog.
- [ ] Final-head CI and independent coordinated lab verification.
- [ ] Root-coordinated release PR, merge, tag, publication and branch cleanup.

## Tests
Version consistency and packaging metadata checks passed locally. Both tina4ruby and transitional tina4 gems built successfully as 3.13.138; local generated Gemfile.lock agrees. Full services and release publication remain with the parent coordinator; no shared lab tests started here.

## Bugs
Pooled PostgreSQL regression reproduced: another thread observed an uncommitted row. Exclusive operation/transaction leases fix the leak, with fail-fast exhaustion and terminal cleanup. Real PostgreSQL regression cases cover isolation, owner checks, failed commit/rollback/begin and lease reuse. All included fixes are documented in CHANGELOG.md.

## Commits
Signed release-preparation commit recorded by git history.

## Status
Local preparation; do not push until the parent coordinates the final PR.
