# Rich Scaffolding Plan — Ruby (scaffolding-first, secure-by-default)

Ported from tina4-python `feat/scaffolding-first` (commit c0b2085). CRUD-shaped
generators emit WORKING code; logic-shaped generators emit WIRING + an AI-FILL
placeholder (`raise NotImplementedError`) where the custom logic goes, so an
unfilled scaffold fails LOUD. Writes are secure by default; `--public` opens them.

## Commands

| Command | Output | Shape |
|---------|--------|-------|
| `generate model Product --fields "name:string,price:float"` | `src/orm/product.rb` + migration | working |
| `generate route products --model Product [--public]` | `src/routes/products.rb` (ORM CRUD) | working + EXTEND |
| `generate route items` (no `--model`) | `src/routes/items.rb` (5 handlers) | AI-FILL stubs |
| `generate crud Product --fields "..." [--public]` | model + migration + routes + form + view + **gate spec** | working |
| `generate migration add_category` | `migrations/TS_add_category.sql` + `.down.sql` | working |
| `generate middleware AuthCheck` | `src/middleware/auth_check.rb` | working |
| `generate test products` | `spec/products_spec.rb` | working |
| `generate service Cleanup --every 5m \| --cron "…"` | `src/services/cleanup.rb` | AI-FILL |
| `generate queue order-emails` | `src/services/order_emails_consumer.rb` | AI-FILL |
| `generate validator CreateUser` | `src/validators/create_user.rb` | AI-FILL |
| `generate seeder Product` | `seeds/product_seeder.rb` | AI-FILL |
| `generate websocket chat` | `src/routes/ws_chat.rb` | AI-FILL |
| `generate listener user.created` | `src/listeners/user_created.rb` | AI-FILL |

## Secure-by-default routes

Writes (POST/PUT/DELETE) are Bearer-token-gated by default. Generated routes
register through `Tina4::Router.get/post/put/delete` (no bearer `auth_handler`
attached), so:

- Reads (GET) → `route.auth_required == false` (public), no opt-out emitted.
- Writes → `route.auth_required == true` (set by `Route#initialize`,
  `lib/tina4/router.rb:24`); a tokenless write 401s via
  `Tina4::RackApp.enforce_route_auth` (`lib/tina4/rack_app.rb:1129`).
- `--public` chains `.no_auth` on the 3 WRITE handlers only — genuinely opens
  the write on BOTH the live server and the TestClient (mirrors AutoCrud's
  `post_route.no_auth if is_public`, `lib/tina4/auto_crud.rb:169`).

> `Tina4::Router.post` (not the top-level `Tina4.post`) is deliberate: `Tina4.post`
> attaches the `bearer_auth` handler which `.no_auth` cannot clear, so `--public`
> would still 403 on the live server. The Router form matches AutoCrud and is
> consistent live+test.

## AI-FILL convention (logic stubs)

A ≤6-line fill-spec, then a loud raise:

```
# ─── AI-FILL: <fn> ───
# Intent:  <what this must do>
# Given:   <inputs + shape>
# Use:     <named REAL tina4-ruby symbols — the idiomatic path>
# Return:  <exact return value + status>
# Ground:  tina4_context("<intent>", "ruby") · skill tina4-developer-ruby
raise NotImplementedError, "<feature>: <what>"   # remove when done
```

Working CRUD code gets the lighter `# ─── EXTEND: … ───` marker (no raise).

## 6 generators — grounded symbols (file:line in live source)

| Generator | Wiring symbol | Source |
|-----------|---------------|--------|
| service   | `Tina4.service` → `Tina4::ServiceRunner.register` (`interval:` / `timing:`) | `lib/tina4.rb:431`, `lib/tina4/service_runner.rb:41` |
| queue     | `Tina4::Queue#push` / `#consume`; `Job#payload` / `#complete` / `#fail` | `lib/tina4/queue.rb:48,149`; `lib/tina4/job.rb:7,73,87` |
| validator | `Tina4::Validator` (`#required`/`#email`/`#is_valid?`) — `require "tina4/validator"` | `lib/tina4/validator.rb:22` |
| seeder    | `Tina4::FakeData`, `Tina4.seed_orm` (seeds/ loaded by `Tina4.seed_dir`) | `lib/tina4/seeder.rb:15,447,890` |
| websocket | `Tina4.websocket` `(connection, event, data)` | `lib/tina4.rb:396`, `lib/tina4/router.rb:331` |
| listener  | `Tina4::Events.on` / `.emit` | `lib/tina4/events.rb:26,69` |

## Divergences from tina4-python (flagged honestly)

- **`ServiceRunner` is a class-level singleton** (`ServiceRunner.register/.discover/
  .start/.list`), not Python's instance runner. Cron key is **`timing:`**, not
  `cron:`. Registration is via the `Tina4.service` DSL at file load.
- **`Job#payload`**, not Python's `job.data`.
- **`Tina4::Validator` is NOT on the default `require "tina4"` surface** (unlike
  Queue/Events/ServiceRunner/FakeData) — the generated validator adds
  `require "tina4/validator"`.
- **Seeds are executed top-to-bottom** by `tina4ruby seed` (no Python-style
  `run(db)`); the seed call is guarded on `Tina4.database` so merely LOADING the
  file (e.g. in a spec) does not run the unfilled placeholder.
- **`src/services`, `src/validators`, `src/listeners` are NOT on the boot
  auto-discover path** (`lib/tina4.rb:566` scans routes/api/orm only). Services
  run via `ServiceRunner.discover + start`; validators/listeners are required
  explicitly. The generated comments say so.

## Tests — real, no mocks (`spec/cli_generate_spec.rb`)

- Every generator output passes `ruby -c` AND `load`s cleanly.
- Route/crud boot-gate via the real `Tina4::TestClient`: anon read 200, anon
  write 401, token write 201; `--public` opens writes (anon write 201); no
  opt-out on writes by default; no-model stub raises when the handler is CALLED
  while the gate still 401s.
- The emitted CRUD spec runs GREEN in a real `rspec` subprocess.
- Each logic stub raises `NotImplementedError` when CALLED, carries the `AI-FILL`
  banner, and its wiring is registered on the real `Router` / `ServiceRunner` /
  event bus. Producer really pushes to the file-backed queue; `seed_orm` really
  seeds the generated model on a real SQLite DB.
- Auth generator stays public (regression guard).

## Files modified
- `lib/tina4/cli.rb` — helpers (`ai_fill`, `extend_marker`, `parse_every`),
  secure-by-default `generate_route` + `--public`, `generate_crud`/`generate_test`
  gate spec, 6 new generators, dispatcher + help.
- `spec/cli_generate_spec.rb` — scaffolding-first acceptance matrix.
- `plan/SCAFFOLDING.md` — this file.
