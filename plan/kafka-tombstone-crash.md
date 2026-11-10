# Task: Kafka tombstone (null-value) record crashes the consumer (tina4-python#303 twin)

Cross-framework twin of tina4-python#303. The rdkafka path decodes
`Tina4.parse_json(msg.payload)`; for a tombstone (null value) rdkafka hands back a
`nil` payload, so `JSON.parse(nil)` raises `TypeError`. The only rescue in `dequeue`
is `rescue Rdkafka::RdkafkaError`, which does NOT catch `TypeError`, so it escapes and
kills the consumer. The tombstone sits at the committed offset → poison pill, re-crashes
on every restart. Same unguarded decode in the `dead_letters` reader.

## Scope
- [x] Read both decode sites (`queue_backends/kafka_backend.rb` dequeue + dead_letters)
- [x] Confirm `Tina4.parse_json(nil)` → `JSON.parse(nil)` → TypeError (not rescued)
- [x] Guard `msg.payload.nil?` before decode in `dequeue`
- [x] Guard `msg.payload.nil?` before decode in the `dead_letters` reader
- [x] Real tombstone regression spec (live broker, no mock)

## Parity
| Port   | Path            | Tombstone handling (before) | Status |
|--------|-----------------|-----------------------------|--------|
| Python | confluent (lib) | `None.decode()` → crash     | ✅ fixed (tina4-python) |
| Ruby   | rdkafka (lib)   | `JSON.parse(nil)` → crash   | ❌ FIX HERE |
| PHP    | pure-protocol   | guards `valueLen <= 0`      | ✅ safe |
| Node   | pure-protocol   | guards `valLen >= 0`        | ✅ safe |

## Tests (written first, real — no mocks, live Kafka via TINA4_KAFKA_BROKERS)
- [x] a tombstone at the committed offset does NOT crash the consumer; it is skipped and
      a following real record is delivered (mutation-proof: fails without the guard)
- [x] a topic holding ONLY a tombstone returns nil (no job) without raising

NOTE: rdkafka needs a native librdkafka build not available on the Windows dev host
(`gem install rdkafka` fails to compile the extension here), so the live spec is verified
on the lab/CI — where the existing `kafka_integration_spec` runs — gated identically
(:kafka tag + reachable broker). It SKIPS cleanly (2 pending) off-broker, and the :kafka
keyword makes TINA4_REQUIRE_SERVICES fail hard on a missing broker in CI rather than pass.

## Verification
- `ruby -c` OK on both edited files.
- Crash mechanism proven in pure Ruby: `Tina4.parse_json(nil)` -> `JSON.parse(nil)` ->
  `TypeError: no implicit conversion of nil into String`, which `rescue Rdkafka::RdkafkaError`
  does NOT catch (so it escaped and killed the consumer); the guard prevents reaching it.
- `spec/kafka_offset_and_raw_spec.rb` (offline): **7 passed** — the edited backend still loads.
- `spec/kafka_tombstone_spec.rb` (offline): gates cleanly (2 pending, reason "rdkafka gem
  not installed"). Live run deferred to lab/CI.
- Parity: identical fix + behavior to the Python twin, which IS mutation-proven on a real
  broker (tina4-python/plan/kafka-tombstone-crash.md).

## Bugs
- [x] (#303 twin) rdkafka `dequeue` + `dead_letters` crash on a null-value record — TypeError

## Commits
- (fix/kafka-tombstone-crash) guard nil payload in dequeue + dead_letters + live spec

## Status: Complete (code + offline verify) — live Kafka run owed on the lab
