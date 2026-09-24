# Release security boundaries

## Scope
- [x] Prevent initial off-origin credential forwarding across API paths.
- [x] Trust forwarded host/proto only from a declared raw-peer proxy.
- [x] Guard dev-admin access and resolved filesystem/identifier boundaries.
- [x] Preserve current health version and existing credential-file hardening.
- [x] Ruby-only narrow URL log redaction.

## Tests
- [x] Real HTTP/filesystem regressions red before fixes, green after.
- [ ] Coordinated full CI/lab before merge.

## Parity
Python/Ruby owned here; PHP/Node coordinated by sibling worker. ADR0082 records the approved clarification. Preserve accepted MCP transport API_KEY fallback; general dev endpoints require dedicated MCP token for remote access. Token cannot bypass Host or Origin. Health version unchanged.

## Bugs
Source confirmed missing initial-target guards, forwarded-host trust and dev-admin read/path gaps. No feature expansion.

## Commits
Signed release security commit follows.

## Focused evidence
36 focused security tests pass. Adjacent run: 253 pass, one Mac stalled-listener precondition failure pending Linux CI. Real PostgreSQL and password Redis regressions fail on original code and pass fixes; ODBC awaits provisioned CI/lab.
