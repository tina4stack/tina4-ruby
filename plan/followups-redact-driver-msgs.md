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
- [x] Round 2 (after #49 merged): merge origin/v3 into the branch
- [x] (b) ADR-0071 section 2 in messenger.rb: trim + lower-case, unknown/empty SMTP and
      IMAP values raise ArgumentError at construction
- [x] (WSDL) shared body rule in wsdl.rb/xml_parser.rb: any BOM, NUL, invalid UTF-8,
      non-UTF-8 declared encoding -> "Malformed XML" before any parse (both entry points)
- [x] (c) websocket_hardening_spec: FakeBackplane/Exploding/Capturing replaced by real
      RedisBackplanes on TINA4_TEST_REDIS_URL
- [x] (d) Kafka push to a dead broker: reproduced for real - it RAISES
      Rdkafka::AbstractHandle::WaitTimeoutError after 60 s, it never returns success.
      The round-1 "OK" was the lab's TINA4_KAFKA_BROKERS=localhost:9092 overriding the
      probe's TINA4_QUEUE_URL (it published to the live lab Kafka). No fix needed.
- [x] (a) lib/tina4.rb "Database connected" line -> Tina4::DatabaseUrl.redact(db_url)
      (after tina4-ruby#50 merged); red-first on the real lab PostgreSQL + ODBC
- [x] Round 3 (1): websocket_hardening_spec on real servers + real sockets (no
      FakeWsConnection, no allow/receive stubs); found and fixed WebSocket#start
      (empty env, handshake never completed), binary payloads sent as text frames,
      and a blocking write that let one non-reading client stall every broadcast
- [x] Round 3 (2): WSDL::Service answers malformed XML / empty body with the Client
      "Malformed XML" fault (was "Internal server error")
- [x] Round 3 (4): rebased onto origin/v3 (#50) with DCO sign-off on every commit
- [ ] (e) OWED: NATS backplane URL redaction + a real test. There is no NATS server and
      no nats-pure gem on the lab, so NATSBackplane (connect errors, URL in messages)
      is unmeasured

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
- [x] wsdl.rb on v3: UTF-16 BOM DOCTYPE body EXPANDED the entity; CDATA dropped from
      Echo (AB instead of AB<c>). Both fixed by #49's parser (merged).
- [x] wsdl after #49: a UTF-8 BOM was skipped and an ISO-8859-1-declared body served;
      WSDL::Service answered refusals as "Internal server error" - fixed (030b458)
- [x] messenger.rb: encryption not trimmed (" SSL " sent in CLEAR) and unknown values
      sent in clear - fixed (4cd8309)
- [x] websocket_hardening_spec used in-memory backplane stand-ins - replaced (f2de2ff)

## Commits
- 6842f40  fix(security): redact the WebSocket backplane and MQTT URLs in error messages
- c2ee9b8  fix: name the missing gem and its install command for S3 storage and the Mongo cache
- 44633b2  fix(websocket): log when the Redis backplane subscriber dies
- e120fa1  plan: follow-ups (lab full suite at this HEAD: 5759 examples, 0 failures, 0 pending)
- 0df7b1f  docs(example): drop TINA4_MAIL_TLS_INSECURE from .env.example (ADR-0071)
- f7b21e0  plan: complete round 1 (lab full suite 5759 / 0 failures / 0 pending)
- 3f5582f  Merge origin/v3 (tina4-ruby#49, #51)
- 4cd8309  fix(messenger): refuse an unknown mail encryption value (ADR-0071 section 2)
- 030b458  fix(wsdl): apply the shared SOAP body encoding rule before any parse
- f2de2ff  test(websocket): run the backplane relay specs on a real Redis, no stand-ins
- (rebased onto origin/v3 with --signoff; round 3 below)
- af3fad0  fix(wsdl): WSDL::Service answers malformed XML with the Client fault
- 593b86e  fix(security): redact the boot "Database connected" line with DatabaseUrl.redact
- 7cc6061  fix(websocket): real-socket hardening suite; standalone start, binary frames, non-blocking writes

## Status: Complete for this round; (e) NATS backplane owed (no NATS on the lab).
Commit hashes above predate the rebase onto origin/v3 (#50); `git log origin/v3..HEAD`
on the branch is the current list.
