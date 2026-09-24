# Task: tina4-python#143 / #144 parity - header Content-Type, settings read when used (Ruby)

**Outcome:** a Content-Type set with `header()` is the response's one Content-Type
(any name case; an explicit content-type argument still wins), and a setting in
`.env` applies. Governed by `tina4-documentation/plan/v3/decisions/ADR-0072.md`;
the cross-framework plan is `tina4-python/plan/issue-143-144-dotenv-settings-content-type.md`.

## Scope
- [x] Reproduce #144 and #143 for real on origin/v3 (Ruby)
- [x] Scan for settings read at load time
- [x] header()/add_header(): Content-Type (any case) is the one "content-type" key; call(data) keeps it (Puma and WEBrick)
- [x] TINA4_MAX_UPLOAD_SIZE constant no longer reads ENV at require time; a bad value warns once and uses the default
- [x] .env upload cap and health path already honoured: locked in
- [x] Regression suite `spec/dotenv_settings_and_content_type_spec.rb`, red first, mutation-proved
- [x] Full suite on the lab (Linux, Ruby 3.2.3, sudo -E, TINA4_REQUIRE_SERVICES=1, tina4-ultipa provisioned lab-side): 5848 examples, 0 failures, 0 pending at d7b66c0

## Tests (real server booted from a project whose .env carries the settings, no mocks)
- [x] header content type replaces the detected type
- [x] a lowercase content type header is the same header
- [x] header content type survives a string body
- [x] an explicit content type argument wins over the header
- [x] without a header the detected type is used (negative)
- [x] max upload size from dotenv is enforced
- [x] a body under the dotenv limit is accepted (negative)
- [x] health path from dotenv is served
- [x] max upload size follows the environment
- [x] a bad max upload size falls back to the default

## Commits
- d7b66c0  fix: header Content-Type is the one Content-Type; bad upload limit falls back

## Status: Complete (PR open, not merged)
