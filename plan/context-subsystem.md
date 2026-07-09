# Context Subsystem — Code/Doc Grounding (tina4-ruby)

## What It Does

`Tina4::Context` is a native, **zero-new-dependency** code/doc grounding index. It lets a
Tina4-Ruby app ground its own AI assistant on its own source, offline: it walks the project,
chunks code on def/class/module boundaries and docs as prose, and answers keyword/fuzzy queries
over a SQLite **FTS5** index (via the `sqlite3` gem already required by the framework — FTS5 +
`bm25()` are built into modern SQLite, so **no new gem**).

It is a parity port of tina4-python's `tina4_python/context` subsystem (itself the proven slice of
neemee's `SqliteFTS` + the stable source-over-tests / definition-first reorderings). It
**complements** the `api_*` reflection tools: `api_*` is exact structural lookup; `code_search`
(this) is fuzzy/semantic FTS over the project's own source + docs.

```ruby
ctx = Tina4::Context.new(".tina4/context.db")
ctx.index_root("src")
ctx.search("where is the auth token issued?", k: 5)
#  -> [{ path: "auth.rb", score: 2.31, snippet: "..." }, ...]
```

On-disk index defaults to `.tina4/context.db` (gitignored). Guards a SQLite build without FTS5:
if absent, the Context degrades to safe no-ops rather than crashing the app.

## Files

| File | Role |
|------|------|
| `lib/tina4/context.rb` | `Tina4::Context` class + process-wide shared singleton (`default_context`/`existing_context`) |
| `lib/tina4/context/chunker.rb` | `Tina4::Context::Chunker` — fold / light_stem / terms / chunk_code / chunk_text |
| `lib/tina4.rb` | requires `tina4/context` (before `tina4/mcp`) |
| `lib/tina4/mcp.rb` | registers the `code_search` dev-MCP tool as a sibling of `api_search` |
| `lib/tina4/dev_admin.rb` | `POST /__dev/api/reload` handler reindexes the changed file (guarded) |
| `spec/context_spec.rb` | 16 real, no-mock RSpec examples |

## API (parity with Python, snake_case)

- `Context.new(path = "./.tina4/context.db", fts5_check: nil)` — `fts5_check` overrides FTS5
  detection (tests exercise the degradation path).
- `#index_path(file, label: nil)` → Integer — UPSERT one file (delete-by-path + re-chunk + insert).
  `label` is the stored/citation path and must be stable for the delete to target the right rows.
- `#index_root(root)` → Integer — walk a tree, index every eligible file, store paths RELATIVE to
  `root`, record `root` for `reindex_file`. Skips vendor/build/runtime dirs and dotdirs.
- `#search(query, k: 5)` → `[{ path:, score:, snippet: }]` — ranked by `bm25()` then two stable
  reorders: source-over-tests (a test that merely mentions a symbol sinks below the source that
  defines it, unless the query is about tests) and definition-first (a chunk that DEFINES a queried
  symbol rises above chunks that only use it). Score is higher-is-better (bm25 sign flipped).
- `#reindex_file(changed_path)` → Integer — reindex one changed file into the LIVE index: outside
  root / under a skip-or-dot dir / ineligible → `-1`; deleted → drop rows and return `0`; otherwise
  UPSERT and return rows. No-op (`-1`) until `index_root` has run.
- `#reset`, `#count`, `#empty?`, `#close`, `Context.fts5_available?`.
- `Context.default_context(root:, db:)` / `Context.existing_context(db:)` — process-wide shared
  index keyed by resolved db path (`code_search` and the reload hook share ONE index).
  `Context.clear_shared_contexts!` is the test/teardown seam.

## Chunker (Ruby-native boundaries)

`chunk_code` splits on top-level `def` / `class` / `module` (accepted at any indent — Ruby nests),
plus the cross-language alternatives from the Python port (php/js/ts `function`, ts `export`,
Object Pascal unit/routine headers) so the SAME index can hold `.rb`, `.py`, `.php`, `.js`, `.ts`,
`.pas` … files. Each chunk is prefixed with a `# file: <path>` line so the path's tokens are
indexed ("where is the router?" matches `core/router.rb` by name). `chunk_text` packs docs on
sentence boundaries (never on a bare `.`, which would shred embedded code in prose). `fold`
lowercases, strips diacritics, joins comma-grouped numbers and splits camelCase so a query for
`field` reaches `IntegerField`.

## Dev-MCP integration point

`lib/tina4/mcp.rb` → `Tina4::McpDevTools.register(server)` registers `code_search` immediately
after `api_search` / `api_class` / `api_method`, matching the existing `server.register_tool(...)`
pattern exactly. It builds/reuses the process-wide `Context.default_context` at
`<project_root>/.tina4/context.db` over `src/` (falling back to the project root), returns a JSON
error (not a crash) if FTS5 is unavailable, and supports `rebuild: true`.

## Reindex-on-change integration point

`lib/tina4/dev_admin.rb` → the `POST /__dev/api/reload` branch of `handle_request` (the WebSocket
reload trigger the CLI file-watcher fires). After the existing `Router.rescan_routes!`, a guarded
block calls `Tina4::Context.existing_context&.reindex_file(@reload_file)` so a saved file is
immediately searchable via `code_search` without a rebuild. It only touches an already-built index
(`existing_context` never creates one) and never breaks the reload on error — parity with Python's
`_api_reload`.

## Notable bug found & fixed during the port (real test caught it)

`Pathname#relative_path_from(...).to_s` and `File.realpath` return **ASCII-8BIT** strings under
`Dir.chdir` (macOS filesystem-encoded paths). The `sqlite3` gem binds an ASCII-8BIT string as a
**BLOB**, and in SQLite a BLOB never `=`-matches a TEXT column value — so `DELETE FROM chunks WHERE
path = ?` in the UPSERT silently matched nothing and `reindex_file` duplicated rows instead of
replacing them. Fixed by `#as_text` (re-tag path bytes as UTF-8, scrub invalid) before binding, so
stored paths and delete predicates are TEXT. Covered by the `reindex_file` UPSERT specs (which run
under `Dir.chdir`).

## Tests

```
bundle exec rspec spec/context_spec.rb
```

16 examples, 0 failures. Behaviours covered: definition-over-test ranking; definition-over-caller
ranking; UPSERT (new found / old gone / no dup); FTS5 real detection + graceful degradation; result
shape + descending score order; docs-as-prose + vendor-dir skipping; empty/stopword query → empty;
`reindex_file` subdir-root relabel, skip outside/ineligible/skip-dir, drop-on-delete, no-op before
`index_root`; shared singleton; the dev-reload trigger reindexing end-to-end; the `code_search` dev
tool registered and finding a symbol over a real temp project.
