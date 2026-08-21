# Task: Port the graph data layer (Feature 139) to Ruby

Outcome: Ruby gains a URL-selected graph data layer shaped exactly like the
relational `Database` layer — `Tina4::GraphDatabase.create(url)` / `.from_env`,
a `GraphUrl` parser, neutral `GraphNode`/`GraphEdge`/`GraphResult` shapes, a
`GraphAdapter` interface with raising stubs, a lazy-loaded Ultipa driver
(`tina4-ultipa`), and the `TINA4_GRAPH_CONNECT_TIMEOUT` resolver. Proven against
the live Ultipa on the lab, all 11 contract cases green, no mocks.

Reference (the spec): tina4-python/tina4_python/graph/ + tests/test_graph.py.
Contract answer key: tina4-documentation/plan/v3/fixtures/graph_contract.json.

## Scope
- [x] Read the Python reference + its 11-case contract + the fixture
- [x] Read the Ultipa Ruby driver (tina4-ultipa) API + the Ruby DB layer idiom
- [x] `GraphUrl` (scheme->engine, default ports, TLS, creds, from_env)
- [x] Neutral shapes GraphNode / GraphEdge / GraphResult
- [x] `GraphAdapter` interface (raising stubs) + GraphError/GraphConnectTimeout
- [x] `GraphDatabase.create` / `.from_env` (lazy driver, actionable install error)
- [x] `TINA4_GRAPH_CONNECT_TIMEOUT` resolver (default 10; <=0 unbounded)
- [x] `UltipaGraphDriver` adapter wrapping tina4-ultipa (GQL core + raw pass-through)
- [x] Wire into lib/tina4.rb (require core shapes; lazy driver)
- [x] spec/graph_spec.rb — the 11 contract cases (real, no mocks, gated on TINA4_TEST_ULTIPA_URL)
- [x] Prove on the lab: rspec spec/graph_spec.rb green against live Ultipa
- [x] Commit LF-only, push feature/graph-databases

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| graph layer (Ultipa) | ✅ | ❌ | ✅ | ❌ |
| bolt (Neo4j/Memgraph) | ✅ | ❌ | ✅ | ❌ |
| arango | ✅ | ❌ | ✅ | ❌ |

## Bolt + Arango adapters (added on feature/graph-databases)

Two engine adapters mirroring the Python reference
(tina4-python/tina4_python/graph/adapters/bolt.py + arango.py):

- `lib/tina4/drivers/bolt_graph_driver.rb` — engine `bolt`, serving BOTH Neo4j
  and Memgraph. Portable core in Cypher (`[*1..N]` variable-length, `SET n += $props`
  merge, `id(n)` integer ids) over a self-contained Bolt 4.4 / PackStream v2 client
  built on stdlib `socket`. **Driver choice (proven on the lab, no mocks):** the
  maintained community gems each fail one engine — `neo4j-ruby-driver` (4.4.6)
  connects to Neo4j but NOT Memgraph (its handshake offers 4.4 only inside a
  4.2–4.4 range entry Memgraph declines, so negotiation drops to Bolt v3 where its
  strict server-version parser rejects Memgraph's agent string), and pulls in
  ActiveSupport + needs a connection_pool 2.x pin; the pure-Ruby `neo4j_bolt` gem
  hardcodes `scheme => 'none'` (no auth) and a process-global connection, so it
  cannot authenticate to Neo4j. Both lab engines negotiate a *plain* Bolt 4.4
  handshake, so a compact real client that offers plain 4.4 works against BOTH and
  adds zero third-party gems (a wire protocol is the sanctioned library exception,
  but no working library exists — so the best implementation is the real client we
  control).
- `lib/tina4/drivers/arango_graph_driver.rb` — engine `arango`. Portable core in
  AQL over stdlib `Net::HTTP` at the `/_api/cursor` REST endpoint (a REAL driver,
  not a mock). Ensures the `tina4_nodes` (document, type 2) + `tina4_edges` (edge,
  type 3) collections exist; nodes carry `_labels`, edges carry `_from/_to/_type`;
  ids are `_id` handles; delete removes touching edges first.

Both registered in `GraphDatabase::ENGINE_ADAPTERS` (graph.rb): `bolt` for
neo4j+memgraph schemes, `arango` for arango/arangodb. `spec/graph_spec.rb`
extended to the PROVIDER MATRIX — the 9 live cases parametrised over every engine
whose `TINA4_TEST_<ENGINE>_URL` is set (Cypher raw+clean for ultipa/neo4j/memgraph,
AQL for arango).

**Lab proof (no mocks), rspec spec/graph_spec.rb:**
`39 examples, 0 failures, 0 pending` with all four engines live —
`ultipa://…@192.168.88.99:60071/default`, `bolt://neo4j:***@192.168.88.99:7687/neo4j`,
`bolt://192.168.88.99:7688` (Memgraph), `arango://root:***@192.168.88.99:8529/_system`.
Unique label `T4GraphContractTest`, cleaned before/after; zero leftover verified.

## Tests (real, no mocks — 11 contract cases, names mirror test_graph.py)
- [x] graph-connect-by-url (scheme selects adapter; unknown rejected)
- [x] graph-driver-optional (core loads driver-free; missing driver -> install error)
- [x] graph-connect-timeout (unreachable host raises GraphConnectTimeout, names host/port)
- [x] graph-add-node (live)
- [x] graph-add-edge (live)
- [x] graph-get-node roundtrip + miss->nil (live)
- [x] graph-update-delete-node (merge + remove) (live)
- [x] graph-neighbors (dir+type; unmatched->empty) (live)
- [x] graph-traverse-depth (live)
- [x] graph-raw-query (bound params) (live)
- [x] graph-write-fails-loud (execute bad GQL raises; get_error set) (live)

## Bugs
- (none in the Ruby layer) The lab's `~/ultipa-ruby` checkout was STALE (its codec
  did not decode the `PROPERTY_TYPE_MAP` that `properties(n)` returns, so props came
  back as raw bytes). The current driver at D:/projects/php/tina4/ultipa-ruby decodes
  maps correctly; the proof run used the current driver (vendored to the lab). No
  change to the tina4-ruby adapter was needed — this is a driver-version note, not a
  framework bug.

## Commits
- (see git log — graph lib + spec + plan on feature/graph-databases)

## Lab proof (no mocks)
- Live Ultipa `ultipa://admin:***@192.168.88.99:60071/default`, graph `default`, EDGE_ID on.
- `rspec spec/graph_spec.rb` → 12 examples, 0 failures, 0 pending. Unique label
  `T4GraphContractTest`, cleaned before/after; zero leftover nodes verified.

## Status: Complete
