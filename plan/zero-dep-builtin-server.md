# Task: Zero-dependency step 5 - built-in HTTP server + form parser (drop rack, rackup, puma, webrick)

**Outcome:** `tina4ruby` declares none of rack / rackup / puma / webrick. A stdlib-socket
server (`Tina4::HttpServer`, booted by `Tina4::WebServer`) serves dev AND production under
ADR-0068's wire rules (the same env vars, limits and statuses as PHP's socket server); Puma
is used only when the APP installs it (ADR-0067). Multipart parsing is Tina4's own
(`Tina4::FormParser`), same output shape as before. The Rack-style `call(env)` interface is
unchanged, so any Rack server still runs Tina4.

Branch: `fix/zero-dep-builtin-server` off `origin/v3` (17b7b20, 3.13.137).
Concurrent worker owns base64/json/logger/sqlite3/net-smtp/net-imap/rexml
(`fix/zero-dep-stdlib-gems`); this task owns only the four server gems.

## Scope
- [x] Tina4::HttpServer on stdlib `socket` (thread per connection, capped at 1024)
  - [x] HTTP/1.1 keep-alive (1.1 default on, `Connection: close` honoured; 1.0 opt-in)
  - [x] Content-Length bodies + chunked request bodies (with extensions and trailers)
  - [x] `Expect: 100-continue`
  - [x] ADR-0068 limits: 431 over TINA4_MAX_REQUEST_HEADER (also while the head is still
        arriving), 413 on a declared Content-Length over TINA4_MAX_UPLOAD_SIZE BEFORE the
        body is read, running cap on chunked bodies
  - [x] slow-loris: TINA4_REQUEST_TIMEOUT (30, 0 disables) - 408 on a partial request, a
        total deadline on the head, silent close on an idle keep-alive connection
  - [x] 400 Malformed request head / Invalid Content-Length / Invalid Transfer-Encoding
  - [x] one rejection shape: JSON body, canonical security headers (no HSTS),
        Connection: close, 2s lingering close
  - [x] a response header with CR/LF/NUL or a non-token name is never written: 500
        {"error":"Invalid response header"} (ADR-0068 s2)
  - [x] multiple Set-Cookie (Array or "\n"-joined value -> one line each)
  - [x] streaming / SSE flushed per chunk, EOF-delimited, `Connection: close`
  - [x] rack.hijack for WebSocket upgrade (WEBrick had none -> WS was 426 in dev)
  - [x] HEAD never writes a body; 204/304 carry none
  - [x] REMOTE_ADDR = the raw socket peer, never empty (IPv4-mapped IPv6 unwrapped)
  - [x] graceful shutdown via Tina4::Shutdown (listeners closed first, idle keep-alive
        connections closed, drain bounded by TINA4_SHUTDOWN_TIMEOUT)
  - [x] PATH_INFO percent-decoded and dot-segment normalised as WEBrick did
- [x] Tina4::WebServer rewired onto the engine: AI/test port (+1000) in debug, dual-stack
      loopback siblings, port takeover, pidfile, banner/log lines ("tina4-server")
- [x] AI port refuses the /__dev_reload WebSocket upgrade now that upgrades work
- [x] Tina4::FormParser (Rack-compatible nesting `a[b]`, `a[]`, `a[][x]`, files incl. an
      empty file field, content types) replaces Rack::Request#POST
- [x] Response call sites refuse CR/LF/NUL (ADR-0068 s1): header, add_header, redirect,
      explicit content type, download filename, cookie name + attributes
- [x] constants.rb no longer consults Rack::Utils; 408/431/505 phrases
- [x] Puma opt-in: production uses Puma only when loadable; otherwise the built-in server
- [x] gemspec: rack, rackup, puma, webrick removed from runtime; with #49 merged the
      gemspec declares ZERO runtime gems; puma kept as a DEVELOPMENT dependency only, so
      the opt-in path is booted for real in specs
- [x] specs that booted Puma for rack.hijack moved to the built-in server
- [x] Rack::MockRequest / require "rack" removed from specs
- [x] docs: CLAUDE.md, skill references, Dockerfile comment, tina4-documentation
- [x] repo Dockerfile boots (local docker, boot-gate steps): /health 200 through -p,
      version 3.13.137, 100 MB on disk (was 104), bundle 12 gems (was 17)
- [x] tina4 CLI launch chain (`tina4 serve --production`) boots a scaffold on the
      built-in server

## Parity (built-in server, on the wire - measured 2026-09-24, macOS, same probe script)
| Probe | Python v3 asyncio | Ruby before (WEBrick) | Ruby after |
|-------|-------------------|-----------------------|------------|
| 404 / 405 + Allow | 404 / 405 GET, HEAD, OPTIONS | same | same |
| HEAD /ping | 200, CL 0 | 200, CL 13, no body | 200, CL 13, no body |
| keep-alive, 2 requests on 1 socket | 1/2 (closes) | 2/2 | 2/2 |
| declared CL 50MB over 1MB cap, no body | no answer (waits) | no answer (waits) | 413 at once, ADR wording |
| 100KB header | connection dropped | 200 | 431, ADR wording |
| stops mid-head (timeout 3) | open 12s+ (30s fixed) | open 12s+ | 408 at 3s |
| Set-Cookie x2 | 2 lines | 2 lines | 2 lines |
| SSE first event | 0.0s | 1.51s (buffered) | 0.0s |
| WebSocket echo | 101, echo | 426 | 101, echo |
| bare LF in head | 200 | 400 | 400 Malformed request head |
| Content-Length: abc | dropped | 400 (HTML) | 400 Invalid Content-Length |
| chunked body | 200, body lost | 200, 5 bytes | 200, 5 bytes |

Python's differences are the ADR-0068 defects its own worker is fixing; Ruby meets the ADR.

## Tests (written first, real sockets, real server processes, positive + negative)
- [x] spec/builtin_server_wire_spec.rb - 23 wire cases; 14 red on WEBrick
- [x] spec/http_hardening_contract_spec.rb - ADR-0068 runner, 19 cases under the fixture's
      names; 13 guard mutations all red
- [x] spec/form_parser_spec.rb - 21 cases; shapes characterised against Rack 3.2.7; 3 red
      on the Rack path (the fixes)
- [x] spec/server_selection_spec.rb - real app bundle without puma, --production serves
      from tina4-server; mutation (puma_available? forced true) red
- [x] spec/run_no_browser_spec.rb (6 cases, 5 red on the old code, lab) and
      spec/scaffolded_gemfile_spec.rb - red before their fixes
- [x] zero_dependency_gemspec_spec: new baseline + no web-server gem
- [x] every wire/contract guard mutation-proved

## Bugs
- [x] WEBrick servlet buffered streaming bodies whole (SSE never streamed in dev) - ed6da78
- [x] WebSocket upgrades impossible on the built-in server (no rack.hijack -> 426) - ed6da78
- [x] multipart scan split on "--boundary" without the leading CRLF; name= regex matched
      inside filename= - d8254ab
- [x] WEBrick read the whole body before Tina4's upload cap (ADR-0068 s3) - ed6da78/2284036
- [x] Tina4.run! opened a browser regardless of TINA4_NO_BROWSER, production or CI;
      now debug-only, never under NO_BROWSER / --no-browser / CI (ADR-0070 union of 8 CI
      variables incl. TF_BUILD; CI=false/0/no/off does not veto); spec_helper defaults
      TINA4_NO_BROWSER=true (first commit, red-first on the lab)
- [x] `tina4ruby init` scaffolded the nonexistent gem "tina4-ruby" - fixed on v3 by #49
      (cli_spec covers it); my duplicate commit dropped in the rebase
- [x] tina4 CLI Dockerfile.ruby / install_production_server `gem install puma` -
      tina4stack/tina4#34 (with the per-language `docker run` port hint)
- [ ] ADR-0068 / ADR-0070 fixtures not on docs main yet: register the Ruby runners
      (spec/http_hardening_contract_spec.rb; a browser_open runner) when they land

## Commits (rebased onto v3 bc90fc7, after #49)
- a074018  fix(run!): open a browser only in debug, never under NO_BROWSER or CI
- 488dddb  feat(request): Tina4's own multipart parser replaces Rack::Request#POST
- 71ef874  feat(server): built-in HTTP/1.1 server on stdlib socket replaces WEBrick
- f453fe0  test: boot the built-in server where specs booted Puma for rack.hijack
- a188ab7  feat(server): ADR-0068 - refuse CR/LF/NUL headers, one rejection shape
- 46f463c  build: drop rack, rackup, puma and webrick (Puma is opt-in, ADR-0067)
- 30e6db5  docs: describe the built-in server; retire WEBrick-era claims
- 0e4c4ea  plan: zero-dep built-in server - scope, parity, tests, commits
- 12820f1  fix(run!): ADR-0070 browser gate - TF_BUILD, and CI=false does not veto
- 6b1dcaa  docs: zero runtime gems - README, CLAUDE.md, BENCHMARK.md

## Status: Complete (pending review; PRs open, not merged)
