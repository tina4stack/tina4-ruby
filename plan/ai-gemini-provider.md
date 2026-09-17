# Task: Add `gemini` provider to the Ruby Ai client (parity with Python master a22ca6a)

Outcome: `gemini` is a THIN ALIAS over the OpenAI wire family in `lib/tina4/ai_client.rb`
— same body builder, normaliser, tool translation, SSE parser. Only the provider allow-list,
key requirement, defaults, endpoint-suffix resolution, and Bearer header change.

## Scope
- [x] Read Python master (`tina4-python/tina4_python/ai/client.py`: `_config`/`_endpoint`/`_headers`/`_PROVIDERS`)
- [x] Read Python gemini tests (`tests/test_ai_client_contract.py::test_ai_gemini_*`)
- [x] Read Ruby target (`lib/tina4/ai_client.rb`) + spec (`spec/ai_client_contract_spec.rb`)
- [x] Allow-list: add `gemini`; error message includes gemini
- [x] `gemini` REQUIRES an API key (like openai/anthropic)
- [x] Defaults: base `https://generativelanguage.googleapis.com/v1beta/openai`, model `gemini-2.5-flash`
- [x] Endpoint: append `/chat/completions` or `/embeddings` onto `/v1beta/openai` base
- [x] Auth header: gemini uses OpenAI `Authorization: Bearer` (not anthropic `x-api-key`)
- [x] Embeddings work for gemini (only anthropic errors)
- [x] Ruby spec: 5 gemini cases mirroring the Python `test_ai_gemini_*` (real local server)

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| gemini provider | ✅ (a22ca6a) | (other task) | ✅ | (other task) |

Note: this task is Ruby-only. PHP/Node parity tracked separately.

## Tests (real local HTTP server — no mocks, positive + negative)
- [x] default endpoint resolves to `.../v1beta/openai/chat/completions` and `.../v1beta/openai/embeddings`
- [x] chat sends OpenAI body + `Authorization: Bearer <key>`, NOT the anthropic header
- [x] embeddings supported for gemini (returns vectors)
- [x] gemini with no key -> AiConfigError (negative)
- [x] streaming yields OpenAI-style text deltas ending in a done event

## Bugs
- (none)

## Commits
- lib/tina4/ai_client.rb + spec/ai_client_contract_spec.rb — gemini thin alias over the
  OpenAI wire family (allow-list, key-required, defaults, /v1beta/openai endpoint suffix,
  Bearer header) + 5 real-server gemini specs. `bundle exec rspec spec/ai_client_contract_spec.rb`
  = 39 examples, 0 failures. Bearer gate mutation-proven (red without gemini).

## Status: Complete
