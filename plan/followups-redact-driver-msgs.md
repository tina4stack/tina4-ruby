# Task: follow-ups - redact connection URLs, name the missing gem (Ruby)

**Outcome:** no Ruby log line or exception message prints a connection password;
the S3 storage and Mongo cache "driver missing" paths name the gem and the exact
install command; SOAP (item 7) and ADR-0071 mail (item 8) measured read-only.

Branch: `fix/followups-redact-driver-msgs` (from origin/v3). Lab only for rspec.

## Scope
- [x] Item 1: measure the WebSocket backplane log lines on the lab password Redis
      (good URL clean, wrong password clean - redis-client drops the userinfo,
      malformed URL LEAKED through "wiring failed")
- [x] Item 1: fix the leak with `Tina4::DatabaseUrl.redact` (no new redactor)
- [x] Item 1: sweep - probed Database (pg/mysql/mssql/firebird/mongodb/odbc),
      queue (mongo/rabbitmq/kafka), cache (redis/valkey/memcached/mongodb),
      session (mongodb), docstore mongo, graph URL, MQTT, S3 with a credentialed
      malformed / refused URL on the lab. Only MQTT leaked (2 raises) - fixed.
- [x] Item 1: lib/tina4.rb:919 (OFF-LIMITS) measured as a pure function: leaks a
      password containing ':' (prefix) or '@' (tail) and an ODBC PWD= verbatim.
      One-line fix reported: `Tina4::DatabaseUrl.redact(db_url)`.
- [x] Item 2: S3Storage LoadError names the gem + `bundle add aws-sdk-s3`
- [x] Item 2: Mongo cache fallback warning appends the install hint ONLY when the gem is missing
- [x] Item 7: SOAP parity table on v3 and on PR #49's parser (read-only)
- [x] Item 8: PR #49 spec/mail_transport_spec.rb on the lab: 17/0/0; extra probes for
      port 465, ssl on a plaintext port, trimming, unknown value, wrong host

## Parity
| Item | Python | PHP | Ruby | Node |
|------|--------|-----|------|------|
| 1 backplane URL redacted | other worker | other worker | ✅ | coordinator |
| 2 install hints | other worker | other worker | ✅ | ✅ (#67) |

## Tests (written first, real - no mocks, positive + negative)
- [x] websocket_backplane_redaction_spec: real RedisBackplane round trip on the password
      Redis; real process output never contains the password (good / wrong / malformed)
- [x] mqtt_auth_tls_spec: parse_url errors never echo the password (2 examples)
- [x] driver_install_hint_spec: S3Storage zero-gem subprocess; select warning carries it
- [x] driver_install_hint_spec: Mongo cache zero-gem subprocess carries the hint
- [x] driver_install_hint_spec: negative control, gem present + port 1 -> no hint

## Bugs
- [x] websocket.rb "wiring failed" logged the raw TINA4_WS_BACKPLANE_URL (password
      included) on a malformed URL - fixed in websocket_backplane.rb
- [x] Redis backplane subscriber died silently on WRONGPASS (only a stderr trace) - now logged
- [x] mqtt.rb parse_url echoed the password in two ArgumentErrors
- [ ] lib/tina4.rb:919 hand-rolled redactor leaks (OFF-LIMITS, reported to coordinator)
- [ ] wsdl.rb on v3: UTF-16 BOM DOCTYPE body EXPANDS the entity; CDATA dropped from
      Echo (AB instead of AB<c>). Both fixed by PR #49's parser (OFF-LIMITS here).
- [ ] messenger.rb on PR #49: encryption not trimmed (" SSL " sends in CLEAR) and
      unknown values send in clear - ADR-0071 section 2, owed after #49 merges.

## Commits
- 6842f40  fix(security): redact the WebSocket backplane and MQTT URLs in error messages
- c2ee9b8  fix: name the missing gem and its install command for S3 storage and the Mongo cache
- 44633b2  fix(websocket): log when the Redis backplane subscriber dies
- e120fa1  plan: follow-ups (lab full suite at this HEAD: 5759 examples, 0 failures, 0 pending)
- 0df7b1f  docs(example): drop TINA4_MAIL_TLS_INSECURE from .env.example (ADR-0071)

## Status: Complete (Ruby side); tina4.rb:919, wsdl.rb and ADR-0071 section 2 reported, off-limits here
