# Task: Integrate release 3.13.139 (tina4-ruby)

Outcome: ONE green, conflict-resolved integration branch `feature/release3.13.139` off
origin/v3 (base 0e81444), 8 fix branches merged in order, full rspec green on the lab
(0 failed, 0 pending). Do NOT merge to v3, do NOT bump version, do NOT tag.

## Scope
- [x] Fetch origin, confirm live PR list, confirm all 8 branches present
- [x] Create feature/release3.13.139 from origin/v3
- [x] (a) merge fix/supply-chain-ruby-release-env (#69, 97d7fa5)  clean
- [x] (b) merge fix/ssrf-guard (#72, 34aabf1)  clean
- [x] (c) merge fix/session-first-use-race (#66, c0c04c6)  clean
- [x] (d) merge fix/dev-surface-hardening (#65, 778fb8b)  conflicts resolved
- [x] (e) merge fix/followups-redact-driver-msgs (#67, f96704b)  conflicts resolved
- [x] (f) merge fix/queue-orm-bugs (#71, 3bb916f)  clean
- [x] (g) merge fix/medium-security (#68, fbac1dc)  conflicts resolved
- [x] (h) merge fix/auth-hardening (0f8eb18)  conflicts resolved
- [ ] Full rspec on lab under mutex, zero failures/pending
- [ ] Push feature/release3.13.139

## Conflicts / reds fixed
Key finding: v3 3.13.138 (PR #70, ADR-0082 + credential-permission work) already
superseded several of the older fix branches, which were based on merge-base #57.

- (d) dev-surface-hardening (ADR-0078): v3 ships ADR-0082 (stricter superset) for
  dev_admin.rb / dispatch_pipeline.rb / rack_app.rb (tokens never bypass Host; same-
  origin still requires the Origin check). Kept v3's ADR-0082. The one gap v3 lacked
  - /health disclosing the version outside debug - kept from the branch in health.rb,
  and its two regression tests appended to the (v3-superset) dev_surface_contract_spec.
- (e) followups (ADR-0071): messenger.rb kept v3's normalize_encryption (identical
  error to the branch's encryption_value; branch's new spec tests behaviour and passes).
  database_connected_log_redaction_spec kept v3 (superset). websocket_backplane_redaction
  _spec kept v3's proven fixture wiring + the branch's one new "subscriber stopped ...
  WRONGPASS" assertion (backed by the branch's new rescue in websocket_backplane.rb).
  SPDX headers the branch dropped were retained across all touched files.
- (g) medium-security: v3 already ships F5 (cross-origin credential strip, proven by
  its superset api_cross_origin_token_spec matrix over get/post/upload/download/stream
  x off_origin) and F6 (X-Forwarded-Host trust in request.rb). Kept v3's api.rb + F5/F6
  superset specs (avoids a duplicated strip + a request.uri nil path); ssrf-guard's
  api.rb retained; request.rb kept the branch's explanatory comment. The NEW #68 work -
  GraphQL CSRF + fan-out limits + their specs - merged in full.
- (h) auth-hardening: auth.rb generate_keys kept v3's SecretFile.update (0600). The
  branch's new Auth methods auto-merged. env.rb kept v3 (SPDX + require digest). spec_
  helper.rb kept BOTH suite hooks: the branch's around(:each) TINA4_SPEC_SECRET
  (ADR-0079) AND ssrf-guard's before(:each) TINA4_ALLOW_PRIVATE_REQUESTS (ADR-0084).

## Commits
- cea5a0d  merge (d) dev-surface-hardening
- 09d5f6c  merge (e) followups-redact-driver-msgs
- (f) queue-orm-bugs, (g) medium-security bbdb185, (h) auth-hardening 5bd3f10

## Status: In Progress (awaiting lab full-suite verification, then push)


## Post-run fix (5673b53)
First lab run (d507b22): 6575 examples, 255 failures, 138 pending. Root cause: the
whole-file `--ours` used to resolve the auth.rb and env.rb CONFLICTS reverted both
files entirely to v3, silently dropping the branch's auto-merged non-conflicting
changes:
- auth.rb lost keys_root= / identity_payload? / require_boot_secret! /
  rsa_keys_present? / insecure_secret_message + class InsecureSecretError, but
  lib/tina4.rb (merged from the branch) calls them in initialize! -> NoMethodError
  cascaded through every in-process boot (183 NoMethodError, 2 NameError).
- env.rb lost ADR-0079 s3 (DEFAULT_ENV still forced TINA4_DEBUG=true; create_default_env
  still minted a guessable MD5 API key).
Both redone as proper 3-way merges (git merge-file) keeping the branch's additions +
v3's SecretFile.update + v3's SPDX headers. Local in-process subset after the fix: the
ADR-0079 debug tests pass; remaining local failures are only mysql/mssql driver-absent
(environmental, provisioned on the lab). Re-running full suite on the lab at 5673b53.
