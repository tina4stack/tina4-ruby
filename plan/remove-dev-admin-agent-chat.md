# Task: Remove the AGENT chat panel from the tina4-ruby dev-admin

Branch: `feature/release3.13.132` (build on ModelCollection+dedup+loopback commits).
Ruby-only removal (deliberate divergence from the Python reference, which keeps the agent).

## Scope
- [ ] Remove agent-proxy ROUTE branches in `lib/tina4/dev_admin.rb`:
      dynamic `/__dev/api/threads/*`, `POST /chat`, GET+POST `/threads`,
      `GET /thoughts`, 5x `/supervise/*`, `POST /execute`.
- [ ] Remove agent-proxy HANDLERS: `supervisor_base`, `thoughts_payload`,
      `proxy_supervisor`, `threads_sub_proxy`, `chat_proxy`, `execute_proxy`.
- [ ] KEEP: `/grounding/*`, `/mcp/tools`, `/mcp/call`, editor `/file*`, `/metrics/*`,
      DB `/tables`,`/query`, gallery, docs, graphql — untouched.
- [ ] Landing screen = code-editor. (SPA bundle already defaults `Pd="editor"`.)

## JS situation
`lib/tina4/public/js/tina4-dev-admin.min.js` is a 962KB shared bundle, NO source in
this repo, no sourceMappingURL. The chat is an AI sub-panel INSIDE the "Code With Me"
editor tab (not a nav entry). Per task: server-side removal only; do NOT hand-edit the
minified blob. `feedback.rb` keeps its own identical `supervisor_base` fallback.

## Tests (real, no mocks — through real RackApp / real handle_request)
- [ ] parity spec: replace `supervisor proxies` + `thoughts` with "agent gone"
      (handle_request returns nil for each removed route).
- [ ] dev_admin_spec: `POST /chat` now disowned (nil), not 503.
- [ ] conformance spec: real RackApp — removed routes 404; kept routes
      (grounding/status, mcp/tools, tables, metrics) still 200; `/__dev` landing 200.

## Bugs
- (none)

## Verification (macOS, Ruby 4.0.2, real RackApp/handle_request — no mocks)
- `bundle exec rspec` on the 6 dev_admin specs + metrics_handoff + feedback:
  174 examples, 0 failures, 0 pending.
- Mutation-proved the new gates: re-adding the /chat route turned exactly the
  3 chat gates RED (got [200,...] instead of nil/404), reverted → green.
- Kept surfaces confirmed live: /grounding/status, /mcp/tools, /file*, /__dev
  SPA shell (200); removed surfaces 404 on the wire.

## Commits
- (this change) remove dev-admin agent chat: routes + 6 proxy handlers, specs assert gone

## Status: Complete
