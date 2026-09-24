# Task: the startup banner names the host and port the server really binds

**Outcome:** `Tina4.run!(dir, port: 47343, host: "127.0.0.1")` prints exactly ONE
`Server:` banner line, and it names `http://127.0.0.1:47343`, on the Puma path
and on the built-in (WEBrick) path, for an explicit `port:` argument and for
`TINA4_PORT`.

Bug (observed on the lab, Ubuntu, Ruby 3.2.3, Puma 6.6.1, 2026-09-24): Puma
bound 127.0.0.1:47343 (`ss -ltnp`) while the banner said
`Server:    http://localhost:7147 (puma)`. Cause: `Tina4.initialize!` calls
`print_banner` with its defaults (0.0.0.0:7147) BEFORE `run!` resolves the bind
host and port. The built-in path printed that wrong banner and then a second,
correct one from `WebServer#start`.

## Scope
- [x] Red-first spec: spec/banner_real_bind_spec.rb, a real `ruby app.rb` child (5/5 red on unfixed v3, lab)
- [x] Fix: the banner is printed by the server start (Puma and built-in), never by `initialize!`
- [x] Mutation-prove the spec (4 mutations, all caught, see below)
- [x] Full suite on the lab (TINA4_REQUIRE_SERVICES=1, OIDC env): 5835 examples, 0 failures, 0 pending
- [ ] Check PHP / Python / Node banners on the lab against `ss -ltnp`
- [ ] PR to v3 (coordinate with PR #50, which rewrites nearby lines of run! and print_banner)

## Parity
| Framework | Banner names the real bind |
|-----------|----------------------------|
| Python    | (check on lab)             |
| PHP       | (check on lab)             |
| Ruby      | ✅ fixed                    |
| Node      | (check on lab)             |

## Tests (written first, real, no mocks)
- [x] banner_names_the_explicit_port_and_host (Puma and built-in)
- [x] banner_names_tina4_port_and_tina4_host (Puma and built-in)
- [x] explicit_port_argument_beats_tina4_port (ADR-0041)

Mutations (lab, Ruby 3.2.3, Puma 6.6.1):
| Mutation | Result |
|----------|--------|
| print_banner back in initialize! | 5/5 red |
| no banner in start_puma_server | 3 red (Puma cases) |
| run! writes port:/host: into bare PORT/HOST | 1 red (explicit_port_argument_beats_tina4_port) |
| WebServer banner auto-detects its name | 1 red (built-in explicit case: labelled "(puma)") |

## Bugs
- [x] banner printed before the bind is resolved (initialize! -> print_banner defaults)
- [x] built-in server printed a second banner, and labelled itself "(puma)" when the gem was installed
- [x] run!(port:) lost to TINA4_PORT (ADR-0041) and logged a false "PORT is deprecated" warning

## Commits

## Status: In Progress
