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
- [x] Check PHP / Python / Node banners on the lab against `ss -ltnp` (PHP wrong host -> tina4-php fix/banner-real-bind)
- [x] PR to v3: tina4stack/tina4-ruby#54 (coordinated with #50: merges with one trivial conflict, spec green on #50's path)

## Parity
Lab, 2026-09-24: each booted on a free port, once with explicit args (127.0.0.1), once with
TINA4_PORT + TINA4_HOST=192.168.88.99 (LAN), banner compared with `ss -ltnp`.

| Framework | explicit args | TINA4_PORT / TINA4_HOST |
|-----------|---------------|-------------------------|
| Python    | ✅             | ✅                       |
| PHP       | ⚠️ port ok, host shown as localhost | ❌ bound 192.168.88.99, banner said localhost |
| Ruby v3   | ❌ localhost:7147 | ❌ localhost:7147     |
| Ruby #54  | ✅             | ✅                       |
| Node      | ✅             | ✅                       |

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
- 9d04ea6  fix(banner): print the host and port the server really binds (tina4-ruby#54)

## Status: Complete (PR #54 open, CI green; not merged)
