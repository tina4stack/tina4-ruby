# Task: CLAUDE.md doc-drift gate (Ruby) + tina4-js rtc.md propagation

Outcome: a mutation-proof gate that reads the framework API snippets out of this
repo's CLAUDE.md and asserts every referenced Tina4 symbol EXISTS against the real
tina4-ruby code by Ruby reflection (no hand-kept list); plus the shared tina4-js
rtc.md fix propagated to all three skill copies. Ports the IDEA of
tina4-python/scripts/audit_doc_drift.py to Ruby, following rspec conventions.

Branch: fix/doc-drift-gate off origin/v3 (v3 release line). Solo/local.

## Scope
- [x] Read the Python reference (audit_doc_drift.py + its test + doc-drift.yml)
- [x] Propagate fixed tina4-js rtc.md over .claude/.agents/.cursor copies (md5-identical)
- [x] Build the CLAUDE.md doc-drift gate: scripts/audit_doc_drift.rb (Ruby reflection)
- [x] Mutation-proof spec: spec/doc_drift_gate_spec.rb (RED on injected drift, GREEN on real)
- [x] Fix any genuine CLAUDE.md drift the gate finds
- [x] Wire CI: .github/workflows/doc-drift.yml on pull_request: [v3] (fast, no services)
- [x] Run gate + spec locally, confirm GREEN
- [x] Commit (signed-off + co-authored), push, open PR into v3

## Parity
Gate is a Ruby-repo doc-truth tool (mirrors the Python one). rtc.md skill sync is
cross-repo (python canonical -> ruby copies). No framework runtime code changes.

## Tests (real, no mocks; mutation-proven)
- [x] real CLAUDE.md is clean (GREEN)
- [x] a bogus Tina4::NoSuchClass reference is flagged (RED)
- [x] a bogus method on a real class (Tina4::Auth.no_such_method) is flagged (RED)
- [x] a real API reference is accepted (Tina4::Auth.get_token)
- [x] rtc.md: no `import { ... mount` remains; all three copies md5-identical to canonical

## Bugs
- [x] CLAUDE.md documented `Tina4::SQLTranslator.limit_to_rows` / `.limit_to_top` /
      `.placeholder_style` — all deleted from the code (SQLTRANS-DEC-02; drivers own
      pagination/placeholders). Removed from the doc fence.
- [x] CLAUDE.md put `query_key` on `Tina4::SQLTranslator`; it lives on
      `Tina4::QueryCache.query_key` (lib/tina4/cache.rb:156). Corrected.

## Commits
- (doc-drift gate + rtc.md sync + CLAUDE.md drift fix — one commit on fix/doc-drift-gate)

## Status: Complete
