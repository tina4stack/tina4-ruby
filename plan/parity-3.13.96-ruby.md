# Task: 3.13.96 parity — Ruby half (Swagger, Messenger, Migrations M1)

Authority: /Users/andrevanzuydam/IdeaProjects/tina4-documentation/plan/v3/parity-3.13.96-decisions.md
Branch: feature/release3.13.96. Ruby ONLY.

## Scope

### Swagger (lib/tina4/swagger.rb)
- [ ] S2 — AutoCrud path populates components.schemas keyed by model CLASS name (properties + required from nullability), $ref from requestBody. Fix in lib/tina4/auto_crud.rb (pass swagger_meta[:model] on list/get/post/put — parity with Python crud).
- [ ] S3 — info.version defaults to "1.0.0" (was Tina4::VERSION); info.description defaults to "" (was "Auto-generated API documentation"). TINA4_SWAGGER_VERSION still overrides. servers left as "/".
- [ ] S5 — drop default_responses. Undecorated route -> only "200"; add "401" only on a secured route.
- [ ] S6 — preserve leading underscores from the path in operationId so /__health and /health are distinct (match Python: strip outer slashes, internal / -> _, drop braces, splat -> wildcard, no underscore-collapse).

### Messenger (lib/tina4/messenger.rb)
- [ ] G1 — inbox and read callable POSITIONALLY (inbox("INBOX",10,0), read(uid,"INBOX")); keyword form still works.
- [ ] G3 — snippet field: decoded, transfer-decoded, tag-stripped plain text, truncated to 200 chars.
- [ ] G4 — inbox() item shape EXACTLY {uid:str, subject, from:STR, to:STR, date:ISO-8601, snippet, seen:bool}. Rename read->seen, from/to STRINGS, drop flags/size, date ISO-8601.
- [ ] G5 — read() item: body_text/body_html (was body/html), attachments, headers. from/to/cc STRINGS (parity Python master).
- [ ] G7 — add mark_unread + send_template (idiomatic), add delete (concept name `delete`, parity Python).
- [ ] G8 — read TINA4_MAIL_IMAP_USERNAME/_PASSWORD, fall back to TINA4_MAIL_USERNAME/_PASSWORD.
- [ ] G10 — pin: read methods raise on closed port (exists); capture gate matrix (new specs).

### Migrations
- [ ] M1 — measure Ruby against real SQLite: tracking-table schema, migrate() shape, rollback() semantics, status() shape, failed-file-stops-run, up/down pairing sql+code. Report. Change only if a divergence requires it.

## Tests (real, no mocks — GreenMail on lab; SQLite local/lab)
- [ ] swagger: version 1.0.0, description "", undecorated GET -> only 200, secured POST -> 200+401, /__health vs /health distinct ids, AutoCrud -> components.schemas + $ref
- [ ] messenger: positional inbox/read, snippet decoded, inbox key set exact, from/to strings, seen key, read body_text/body_html/attachments/headers, mark_unread/send_template/delete, IMAP creds distinct account, capture gate

## Bugs (spec pinned old shape — correct + say why)
- [ ] messenger_spec.rb "delivers over real SMTP" asserts env[:to]/[:from] as arrays of {email} — pins pre-G4 shape; correct to strings.
- [ ] messenger_spec.rb read specs assert full[:body]/[:html] — pins pre-G5 names; correct to body_text/body_html.
- [ ] swagger_spec.rb "includes default responses" asserts 400/401/404/500 on a public GET — pins S5 bug; correct.
- [ ] swagger_spec.rb version/description defaults — pin pre-S3; correct.

## Commits
- (hash  description)

## Status: In Progress
