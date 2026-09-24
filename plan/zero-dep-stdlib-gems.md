# Task: Zero-dependency Ruby, steps 2-4 (stdlib gems, sqlite3 to the scaffold, own SMTP/IMAP/XML)

**Outcome:** `gem install tina4ruby --explain` drops from 15 gems to the Rack web
stack only (rack, rackup, puma, nio4r, webrick; those are removed separately on
`fix/zero-dep-builtin-server`). json, base64, logger, sqlite3, net-smtp, net-imap,
rexml, net-protocol, timeout and date are no longer runtime dependencies. SQLite
keeps working out of the box because `tina4 init ruby` writes `gem "sqlite3"`
into the app Gemfile (ADR-0067).

Branch: `fix/zero-dep-stdlib-gems` off `v3`. The server stack (rack, rackup, puma,
webrick, lib/tina4.rb boot, webserver.rb, request.rb) belongs to the other branch
and is not touched here.

## Scope
- [x] Step 2a: `json` declaration dropped (default gem 3.1..4.0)
- [x] Step 2b: every `Base64.*` call replaced by `Tina4::Base64` on `pack("m")`, `base64` gem dropped
- [x] Step 2c: `logger` declaration dropped (nothing requires it); boot + log proven on Ruby 4.0 under Bundler
- [x] Step 2d: `require "cgi"` (removed library on Ruby 4.0, warns every boot) -> `cgi/escape` in files this branch owns
- [x] Step 3a: sqlite3 required lazily everywhere with one actionable error
- [x] Step 3b: sqlite3 moved from runtime to development dependency
- [x] Step 3c: tina4 CLI `init ruby` / upgrade paths write `gem "sqlite3"` (separate PR, tina4 repo)
- [x] Step 3d: proof: fresh `tina4 init ruby` + serve works; project without sqlite3 gets the actionable error
- [x] Step 4a: own SMTP client (plain, STARTTLS, implicit TLS on 465, AUTH PLAIN/LOGIN)
- [x] Step 4b: own IMAP client (LOGIN, SELECT, UID SEARCH/FETCH/STORE, EXPUNGE, LIST, STARTTLS)
- [x] Step 4c: own XML parser for WSDL (no DTD/entity support at all; non-UTF-8 bodies rejected)
- [x] Step 4d: net-smtp, net-imap, rexml dropped from gemspec + Gemfile
- [ ] README / CLAUDE.md / gemspec comments / tina4-documentation updated; ADR-0067 written

## Parity
| Component | Python | PHP | Node | Ruby before | Ruby after |
|-----------|--------|-----|------|-------------|------------|
| SMTP implicit TLS on 465 | ✅ SMTP_SSL | ✅ ssl:// | ✅ tls.connect | ❌ STARTTLS attempted on 465 | ✅ (also `encryption: "ssl"`) |
| SMTP STARTTLS when tls/starttls | ✅ | ✅ (tls opportunistic) | ⚠️ opportunistic | ✅ required | ✅ required |
| SMTP `none` stays plain | ✅ | ✅ | ✅ | ❌ Net::SMTP auto-STARTTLS | ✅ |
| SMTP/IMAP certificate verification | ❌ unverified | ❌ verify_peer false | ✅ (opt-out env) | ✅ | ✅ |
| IMAP `starttls` really STARTTLS | ✅ | ✅ /tls | ❌ plain | ❌ implicit TLS | ✅ |
| WSDL UTF-16 DOCTYPE body | ✅ Malformed XML | ❌ entity expanded | ⚠️ Missing SOAP Body | ❌ entity expanded | ✅ Malformed XML |
| WSDL entities + CDATA decoded | ✅ | ✅ | ❌ single-param op gets null | ⚠️ CDATA dropped, unknown entity kept | ✅ |
| SQLite driver | stdlib | ext (suggest) | node:sqlite | runtime gem | app Gemfile, lazy + actionable error |

## Tests (written first, real, no mocks, positive + negative)
- [x] `Tina4::Base64` byte-for-byte equal to the gem for strict/urlsafe/MIME encode and decode, strict decode raises
- [x] zero_dependency_gemspec_spec: baseline shrinks to the web stack (red before gemspec edit)
- [x] sqlite3 missing -> actionable LoadError (real subprocess with sqlite3 hidden from the load path)
- [x] SMTP: plain, STARTTLS, implicit TLS, AUTH PLAIN, AUTH LOGIN, bad password, STARTTLS not offered (real servers)
- [x] IMAP: every existing GreenMail example on the new client; STARTTLS and implicit TLS against real servers
- [x] WSDL: UTF-16 DOCTYPE body rejected; entities/CDATA decoded; malformed rejected

## Bugs
- [x] Net::SMTP auto-STARTTLS upgraded `encryption: "none"` when the server offered it (Python/PHP/Node stay plain)
- [ ] Found, NOT Ruby (reported to the coordinator, other repos): PHP WSDL parses a UTF-16 DOCTYPE body and expands its entity; Node WSDL passes null to a single-parameter operation, never decodes entities, answers "Missing SOAP Body" for malformed XML
- [x] `tina4ruby init` wrote gem "tina4-ruby" (not a published gem) into the Gemfile -- fixed with the sqlite3 scaffold change
- [x] bare `tina4ruby serve` raised NoMethodError (Tina4.truthy? before lib/tina4 loads) -- found by the step-2 boot proof
- [x] Ruby SMTP on port 465 attempted STARTTLS (Python/PHP use implicit TLS)
- [x] Ruby IMAP `starttls` opened implicit TLS instead of STARTTLS
- [x] WSDL: UTF-16 body with a DOCTYPE slipped past the `<!DOCTYPE` guard into REXML

## Commits
- 1d7df9d  fix(cli): bare `tina4ruby serve` no longer crashes resolving the default host
- 62de235  build(deps): drop json, base64 and logger -- Ruby ships or Tina4 replaces them
- c8263dc  build(deps): sqlite3 is an app dependency -- lazy require with an actionable error
- tina4 CLI 317b7f7  fix(init/ruby): scaffold Gemfile declares sqlite3; update/upgrade add it

## Status: In Progress
