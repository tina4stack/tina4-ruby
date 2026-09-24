# Task: the three missing ADR-0060 timeout/close cases in Ruby

**Outcome:** spec/api_stream_contract_spec.rb carries `stream-connect-timeout-honoured`,
`stream-total-timeout-honoured` and `stream-early-close-releases-socket` against real
local sockets, `Tina4::API` streaming obeys the fixture rule, and
`scripts/audit-contract-fixtures.py` reports 0 BROKEN for api_stream_contract.json.

Fixture rule (tina4-documentation/plan/v3/fixtures/api_stream_contract.json,
api-stream-timeouts-and-close): TINA4_API_CONNECT_TIMEOUT bounds connection
establishment, TINA4_API_TIMEOUT bounds TOTAL streaming duration, closing the
iterator before EOF closes the transport promptly.

## Scope
- [x] Read Python / PHP / Node cases and the fixture rule
- [x] Red-first: the three cases, real local socket servers, no mocks (connect + total red on v3, lab)
- [x] Fix Tina4::API streaming where a case exposes a gap
- [x] Mutation-prove each case (4 mutations, all caught)
- [x] Full suite on the lab (TINA4_REQUIRE_SERVICES=1, OIDC env): 5833 examples, 0 failures, 0 pending
- [x] audit-contract-fixtures.py: 3 BROKEN -> 0 BROKEN (318 proven, 28 owed, 0 broken)
- [ ] PR to v3

## Parity
| Case | Python | PHP | Node | Ruby |
|------|--------|-----|------|------|
| stream-connect-timeout-honoured    | ✅ | ✅ | ✅ | ✅ |
| stream-total-timeout-honoured      | ✅ | ✅ | ✅ | ✅ |
| stream-early-close-releases-socket | ✅ | ✅ | ✅ | ✅ |

## Tests (written first, real, no mocks)
- [x] connect: a loopback listener with a full accept queue stalls the SYN; per-call and TINA4_API_CONNECT_TIMEOUT
- [x] total: a server that drips a chunk every 50 ms forever; per-call and TINA4_API_TIMEOUT
- [x] early close: break out after the first chunk; the SERVER sees EOF promptly (block form and Enumerator#first)

Red on unfixed v3 (lab): connect (TINA4_API_CONNECT_TIMEOUT ignored, still streaming at 5 s),
total (per-call timeout: 0.3 still streaming at 5 s). Early close was already correct and is
proved by mutation.

Mutations (lab, Ruby 3.2.3):
| Mutation | Result |
|----------|--------|
| no total deadline in the body loop | stream-total-timeout-honoured red |
| TINA4_API_TIMEOUT ignored | stream-total-timeout-honoured red |
| TINA4_API_CONNECT_TIMEOUT ignored | stream-connect-timeout-honoured red |
| Net::HTTP started without the block form (never finished) | stream-early-close-releases-socket red |

## Bugs
- [x] `timeout:` was only Net::HTTP read_timeout (an idle timeout per read), so a dripping server streamed forever
- [x] TINA4_API_TIMEOUT / TINA4_API_CONNECT_TIMEOUT were never read by Ruby streaming
- [x] connect default was the client timeout (30s), not 10s like Python/PHP/Node

## Commits

## Status: In Progress
