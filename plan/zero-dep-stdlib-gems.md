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
- [x] README / CLAUDE.md / gemspec comments / tina4-documentation updated; ADR-0067 written

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
- [x] json 3.0 (unpinned now) raises on duplicate keys: request bodies/GraphQL/JWT diverged from Python/PHP/Node last-key-wins -- found by CI run 35978265379, fixed with Tina4.parse_json
- [x] Net::SMTP auto-STARTTLS upgraded `encryption: "none"` when the server offered it (Python/PHP/Node stay plain)
- [ ] Found, NOT Ruby (reported to the coordinator, other repos): PHP WSDL parses a UTF-16 DOCTYPE body and expands its entity; Node WSDL passes null to a single-parameter operation, never decodes entities, answers "Missing SOAP Body" for malformed XML
- [x] `tina4ruby init` wrote gem "tina4-ruby" (not a published gem) into the Gemfile -- fixed with the sqlite3 scaffold change
- [x] bare `tina4ruby serve` raised NoMethodError (Tina4.truthy? before lib/tina4 loads) -- found by the step-2 boot proof
- [x] Ruby SMTP on port 465 attempted STARTTLS (Python/PHP use implicit TLS)
- [x] Ruby IMAP `starttls` opened implicit TLS instead of STARTTLS
- [x] WSDL: UTF-16 body with a DOCTYPE slipped past the `<!DOCTYPE` guard into REXML

## Commits
- be1c1ba  fix(cli): bare `tina4ruby serve` no longer crashes resolving the default host
- 92c5f2e  build(deps): drop json, base64 and logger -- Ruby ships or Tina4 replaces them
- ca960d5  build(deps): sqlite3 is an app dependency -- lazy require with an actionable error
- 29e1b07  build(deps): own SMTP, IMAP and XML code replaces net-smtp, net-imap and rexml
- 984f671  docs: runtime gems are the Rack server stack only; sqlite3 is the app's
- 32c77c7  fix(json): last duplicate key wins on json 3 too (Tina4.parse_json)
- tina4 CLI 317b7f7 (PR tina4#33)  fix(init/ruby): scaffold Gemfile declares sqlite3; update/upgrade add it
- tina4-documentation 3f931ad (PR #63)  ADR-0067 + Ruby pages
- test-env fixture MAIL_TLS in python#142, php#215, nodejs#66 (ADR-0038 byte-identical)

## Verification
- CI run 35980078117 at 32c77c7 (Ruby 3.2, json 3.0.2 resolved fresh): test 5827 examples, 0 failures, 71 pending (the same 71 env-gated pendings as green v3 run 35973469374: Firebird-only specs covered by the firebird job, graph DBs, lab-only OIDC, PostGIS, root-only tmpfs); firebird job green.
- Lab at 32c77c7 (json 2.21.2): 5825 examples, 1 failure, 36 pending; the failure was a Firebird "update conflicts with concurrent update" deadlock on the shared tina4_rb.fdb while 10 other rspec processes ran; migration_contract_spec alone passed at seeds 1, 2, 3.
- Local at 32c77c7 with json 3.0.2 forced: no failure outside the files that fail on this Mac at v3 (engine connections, memcached TTL clock skew, local Mongo down).
- Lab (Linux, Ruby 3.2.3, TINA4_REQUIRE_SERVICES=1, OIDC required, mail-infra.sh up): 5819 examples, 0 failures, 36 pending (all 36 are the env-gated graph-database examples, identical to the v3 baseline: 5753 / 0 / 36).
- Local (macOS, Ruby 4.0.7): 5816 examples, 66 failures, 124 pending; 65 failures are the same engine-connection files as the v3 baseline run on this Mac (local MySQL/MSSQL/PG), the 66th is session_ttl_units (memcached remaining-ttl off by 62s against a docker VM clock; passes on the lab).
- `gem install ./tina4ruby.gem --explain`: 15 gems before, 5 after (webrick, nio4r, puma, rack, rackup).
- Clean app bundle (only tina4ruby) boots, logs, parses XML and raises the sqlite3 message on Ruby 3.1, 3.2, 3.4 and 4.0.7.

## Status: Complete (PRs open, merge blocked on review; the built-in-server branch will conflict on gemspec/README/zero-dep spec)
