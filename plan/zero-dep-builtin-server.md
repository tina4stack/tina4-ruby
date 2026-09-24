# Task: Zero-dependency step 5 - built-in HTTP server + form parser (drop rack, rackup, puma, webrick)

**Outcome:** `tina4ruby` declares none of rack / rackup / puma / webrick. A stdlib-socket
server (`Tina4::WebServer`) serves dev AND production, with the wire behaviour of PHP's
`Tina4/Server.php` and Python's built-in asyncio server; Puma is used only when the APP
bundles it (ADR-0067). Multipart / urlencoded parsing is Tina4's own, same output shape
as before. The Rack-style `call(env)` interface is unchanged, so any Rack server still works.

Branch: `fix/zero-dep-builtin-server` off `origin/v3` (17b7b20, 3.13.137).
Concurrent worker owns base64/json/logger/sqlite3/net-smtp/net-imap/rexml
(`fix/zero-dep-stdlib-gems`); this task owns only the four server gems.

## Scope
- [ ] Tina4::HttpServer engine on stdlib `socket` (thread per connection, capped)
  - [ ] HTTP/1.1 keep-alive (1.1 default on, `Connection: close` honoured; 1.0 opt-in)
  - [ ] Content-Length bodies + chunked request bodies (WEBrick/Puma accepted chunked)
  - [ ] `Expect: 100-continue`
  - [ ] PHP enforceRequestLimits parity: 431 over TINA4_MAX_REQUEST_HEADER (64KB),
        413 on declared Content-Length over TINA4_MAX_REQUEST_BODY / TINA4_MAX_UPLOAD_SIZE
        BEFORE the body is read, running byte cap while reading (chunked / under-declared)
  - [ ] slow-loris: TINA4_REQUEST_TIMEOUT (30s, 0 disables) - 408 on a partial request,
        silent close on an idle keep-alive connection
  - [ ] malformed framing -> 400 (CR/LF/NUL in header names or values, obs-fold, bad
        request line, CL+TE, conflicting Content-Length); unsupported TE -> 501
  - [ ] response headers: CR/LF/control chars never reach the wire (dropped + warned)
  - [ ] multiple Set-Cookie (Array or "\n"-joined value -> one line each)
  - [ ] streaming / SSE bodies flushed per chunk, EOF-delimited, `Connection: close`
  - [ ] rack.hijack for WebSocket upgrade (WEBrick had none -> WS was 426 in dev)
  - [ ] HEAD never writes a body; 204/304 carry none
  - [ ] REMOTE_ADDR = the raw socket peer, never empty
  - [ ] graceful shutdown via Tina4::Shutdown (listener closed first, drain bounded by
        TINA4_SHUTDOWN_TIMEOUT, idle keep-alive connections closed)
- [ ] Tina4::WebServer rewired onto the engine: AI/test port (+1000) in debug, dual-stack
      loopback siblings, port takeover, pidfile, banner/log lines
- [ ] AI port refuses the /__dev_reload WebSocket upgrade now that upgrades work
- [ ] Tina4::FormParser: multipart (Rack-compatible nested params `a[b]`, `a[]`, `a[][b]`,
      files incl. empty filename, content types) - replaces Rack::Request#POST
- [ ] constants.rb no longer consults Rack::Utils
- [ ] Puma opt-in: production uses Puma only when loadable; otherwise the built-in server
- [ ] gemspec: rack, rackup, puma, webrick removed (runtime AND development)
- [ ] specs that booted Puma for rack.hijack moved to the built-in server
- [ ] specs using Rack::MockRequest moved to plain envs
- [ ] docs: README, CLAUDE.md, gemspec comments, Dockerfile comment, tina4-documentation
- [ ] scaffolded Dockerfile / tina4 CLI deploy template still boots

## Parity (built-in server, on the wire)
| Behaviour | Python asyncio | PHP Server.php | Ruby (before, WEBrick) | Ruby (after) |
|-----------|----------------|----------------|------------------------|--------------|
| (filled from measured runs - see Commits / report) | | | | |

## Tests (written first, real sockets, real server processes, positive + negative)
- [ ] spec/builtin_server_wire_spec.rb - keep-alive, 431, 413 before body, running cap,
      408 slow-loris, 400 CR/LF, chunked, 100-continue, Set-Cookie multiples, HEAD,
      SSE streaming, WebSocket echo, REMOTE_ADDR, response-header CR/LF stripped
- [ ] spec/form_parser_spec.rb - nested / repeated / files / empty file / content types
- [ ] zero_dependency_gemspec_spec: baseline no longer lists rack/rackup/puma/webrick
- [ ] every new test mutation-proved (break it, watch it go red)

## Bugs
- [ ] WEBrick servlet buffered streaming bodies whole (SSE never streamed in dev)
- [ ] WEBrick build_rack_env passed a DECODED PATH_INFO; Puma passes it raw
- [ ] WebSocket upgrades impossible on the built-in server (no rack.hijack -> 426)
- [ ] scan_multipart_files split on "--boundary" without the leading CRLF, and its
      name= regex could match inside filename=

## Commits
- (hash  description)

## Status: In Progress
