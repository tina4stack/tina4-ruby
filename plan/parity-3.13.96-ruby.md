# Task: 3.13.96 parity — Ruby half (Swagger, Messenger, Migrations M1)

Authority: /Users/andrevanzuydam/IdeaProjects/tina4-documentation/plan/v3/parity-3.13.96-decisions.md
Branch: feature/release3.13.96. Ruby ONLY.

## Scope

### Swagger (lib/tina4/swagger.rb) — DONE, committed 2114f0b, mutation-proven
- [x] S2 — AutoCrud passes swagger_meta[:model] on list/get/post/put; components.schemas keyed by CLASS name, required from nullability, requestBody $ref.
- [x] S3 — info.version defaults "1.0.0"; info.description defaults "". Env overrides kept.
- [x] S5 — dropped default_responses; undecorated -> only 200; 401 only on secured.
- [x] S6 — operationId preserves underscores (get___health vs get_health).

### Messenger (lib/tina4/messenger.rb) — DONE, committed f90d10a, mutation-proven on lab
- [x] G1 — inbox/read positional AND keyword.
- [x] G3 — snippet decoded/transfer-decoded/tag-stripped/<=200 (BODY.PEEK[]).
- [x] G4 — inbox item EXACTLY {uid, subject, from:STR, to:STR, date:ISO-8601, snippet, seen:bool}.
- [x] G5 — read body_text/body_html, from/to/cc STRINGS, attachments {filename,content_type,size}, headers Hash.
- [x] G7 — mark_unread, delete (fail-loud), send_template.
- [x] G8 — TINA4_MAIL_IMAP_USERNAME/_PASSWORD w/ SMTP fallback + ctor args.
- [x] G10 — capture-gate matrix + delete fail-loud pinned.

### Migrations — M1 MEASURED (real SQLite), no divergence -> no Ruby change
- [x] M1 — measured. Findings:
  - tracking table `tina4_migration`, columns MATCH the canonical set (verified via db.columns):
    id INTEGER PK(auto), migration_name VARCHAR(500) NOT NULL UNIQUE, description VARCHAR(500),
    batch INTEGER NOT NULL DEFAULT 1, executed_at VARCHAR(50) NOT NULL, passed INTEGER NOT NULL DEFAULT 1.
  - migrate() -> Array of {name, status:"success"} in apply order; on a failed file the entry is
    {name, status:"failed", error} and the run STOPS (later files not attempted).
  - status() -> {completed:[migration_name], pending:[basename]} (two keys).
  - rollback(steps=1) rolls back the last BATCH (all files sharing the highest batch), newest-id first;
    returns Array of {name, status:"rolled_back"} (or {..,status:"failed",error}); deletes the tracking rows.
    "steps" counts BATCHES, not files (one migrate() = one batch).
  - failed-file-stops-run: YES; failed file rolled back, no tracking row written (not passed=0), earlier
    successes persist, later files skipped.
  - up/down pairing: sql = NNN_name.sql + NNN_name.down.sql; code = NNN_name.rb MigrationBase#up/#down.

## Tests (real, no mocks — GreenMail on lab; SQLite local/lab)
- [ ] swagger: version 1.0.0, description "", undecorated GET -> only 200, secured POST -> 200+401, /__health vs /health distinct ids, AutoCrud -> components.schemas + $ref
- [ ] messenger: positional inbox/read, snippet decoded, inbox key set exact, from/to strings, seen key, read body_text/body_html/attachments/headers, mark_unread/send_template/delete, IMAP creds distinct account, capture gate

## Bugs (spec pinned old shape — correct + say why)
- [ ] messenger_spec.rb "delivers over real SMTP" asserts env[:to]/[:from] as arrays of {email} — pins pre-G4 shape; correct to strings.
- [ ] messenger_spec.rb read specs assert full[:body]/[:html] — pins pre-G5 names; correct to body_text/body_html.
- [ ] swagger_spec.rb "includes default responses" asserts 400/401/404/500 on a public GET — pins S5 bug; correct.
- [ ] swagger_spec.rb version/description defaults — pin pre-S3; correct.

## Commits
- 2114f0b  Swagger S2/S3/S5/S6 + specs (mutation-proven)
- f90d10a  Messenger G1/G3/G4/G5/G7/G8/G10 + specs (mutation-proven on lab)

## Lab verification (final HEAD f90d10a)
- Full `bundle exec rspec` on the lab (Ubuntu, live services, GreenMail up,
  BUNDLE_WITH=firebird, TINA4_REQUIRE_SERVICES=1, seed 4242):
  **5041 examples, 0 failures** (clean exit). GreenMail specs RAN (no skips —
  require-services would have failed a skip; the messenger-only run showed 140
  examples with real SMTP sends). Changed-file subset `$? == 0`.
- Mutation proofs (each broke, then restored): S2 POST-model, S3 version, S5 401,
  S6 underscore-collapse (local); G1 keyword-only, G4 array-from/to, G3 200->5,
  G8 imap_open-SMTP-creds (lab).

## Off-list findings (reported, NOT changed — need discussion)
- `Tina4.post(path)` installs a default auth_handler (auth: :default ->
  Auth.default_secure_auth); `.no_auth` clears only auth_required, so
  `Tina4.post("/x").no_auth` stays effectively secured. The genuinely-public
  idiom is `Tina4::Router.post("/x").no_auth` (no default handler), which is what
  AutoCrud + the framework's own specs use. A behaviour fix to discuss.
- Python `_fetch_header` snippet truncates to 150 chars; the settled shape (G3)
  is 200. Ruby implements 200 correctly; Python needs to move 150 -> 200.
- Python read() carries an extra `attachments_data` (with content bytes) key and
  no top-level `message_id`. Ruby matches `attachments` (metadata) + headers.

## Status: DONE — 5041 examples / 0 failures on the lab at HEAD f90d10a
