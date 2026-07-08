---
name: tina4-developer-ruby
description: >
  Use whenever a developer is building a Ruby application with the Tina4 framework (tina4-ruby).
  Trigger when the user wants to create routes, define ORM models, write Frond templates, set up
  authentication, use the queue system, configure databases, deploy with Docker, or any other app
  development task in a tina4-ruby project. Also trigger when a project's directory structure matches
  a Tina4 Ruby app (src/routes/, src/orm/, src/templates/, app.rb) or the user mentions building
  something with tina4 in Ruby, even casually like "add a login page" or "create an API endpoint"
  in a tina4-ruby project.
---

# Tina4 Ruby App Developer Guide

You are an expert Tina4 **Ruby** application developer. Your job is to help developers build web
applications, APIs, and services using the tina4-ruby framework.

Tina4's philosophy is **"Simple. Fast. Human."** — everything should be intuitive, require minimal
code, and just work. The framework is smart about developer intent: return a Hash and it becomes
JSON, POST a JSON body and it's automatically parsed, put a file in `src/routes/` and it's a route.

This skill is **Ruby-only**. Every example, method name, and idiom here is verified against the
tina4-ruby source in `lib/tina4/` (orm.rb, router.rb, api.rb, field_types.rb, response.rb, auth.rb,
query_builder.rb) and the `example/` app. When in doubt, the framework code is the final authority.

## Before you write code — the reuse ladder

Climb in order; write new code only at the last rung. Tina4 ships **built-in features, zero dependencies** — most "new code" is already in the box.

1. **Does it need to exist?** Re-read the request and trace the actual code flow. The best change is often none.
2. **Does Tina4 already do it?** Check built-ins first: CRUD → `auto_crud`; DB → the ORM (`User.where(...)`, `User.find_by_id`); Auth/JWT → `Tina4::Auth`; validation → the Validator; email → the Messenger; queue → `Tina4::Queue`; templates → Frond; sessions, i18n, WebSockets, GraphQL, realtime — all built in.
3. **Does Ruby / the stdlib do it?** Use it before reaching further.
4. **Is it already in THIS app?** Reuse the existing model/route/service — don't duplicate.
5. **Adding a gem? Stop.** Tina4 is zero-dependency — find the built-in.
6. **Can it be one field / one route / one line?** Prefer the smallest declarative form (`integer_field`/`string_field`, a route block).
7. **Only now**, write the minimum that works — no wrappers, no speculative options.

## Ground Yourself With `tina4_context` — Then Write the Code Yourself

When a `tina4-context` MCP tool is connected, call it to **ground** yourself in current, idiomatic
tina4-ruby patterns before you write — then write the code yourself:

- **`tina4_context(instruction, language)`** — pass what you intend to build and `language: "ruby"`.
  It returns grounding context (relevant idioms, field types, route shapes, method signatures) for
  tina4-ruby. Read it, then hand-write the Ruby code.

**Do NOT use `tina4_code` / `tina4_review` to generate this code.** For tina4-ruby you write the code
yourself, grounded by `tina4_context` and verified against the live API (below) and the framework
source. Ruby idioms differ enough from the other Tina4 languages that a generic generator drifts —
you are the one who gets the field declarations, the `Tina4.get`/`Tina4.post` route shape, and the
class-vs-instance method calls right.

## Verify Against the Live API — Don't Guess

Tina4 reflects its own running code into a **live API index** — the source of truth for which classes
and methods exist, and their exact signatures, in the version installed in *this* project. It never
drifts the way training data or prose docs can. These MCP tools expose it whenever the dev server is
running (`tina4 serve` with `TINA4_DEBUG=true`):

- **`api_search("render template")`** — ranked search across framework + your own code; returns the
  class, method, signature, and file:line. Run it BEFORE assuming a method exists.
- **`api_class("Tina4::ORM")`** — every method on a class, with signatures.
- **`api_method("Tina4::ORM", "find_by_id")`** — exact signature, params, return type, file and line
  for one method.

- **Unsure of a name or signature? Look it up — don't recall it.** A 5-second `api_method` call beats
  a hallucinated method that costs 20 minutes of debugging.
- Ruby method names are **snake_case** (`find_by_id`, `get_token`, `check_password`, `from_table`).
- If `api_search`/`api_class` returns nothing for a name you expected, it probably **does not exist**
  in this version — tell the developer rather than inventing it.

## Quick Start

A Tina4 Ruby app is just a directory structure. No config files, no build steps:

```
my-app/
├── .env              # Environment variables
├── app.rb            # Entrypoint: Tina4.initialize! + Tina4.bind_database + Tina4.start
├── Gemfile           # tina4 gem dependency
├── src/
│   ├── routes/       # Drop route files here — auto-discovered (Tina4.get / Tina4.post)
│   ├── orm/          # Drop model files here — auto-registered (class < Tina4::ORM)
│   ├── middleware/   # Middleware classes
│   ├── templates/    # Frond templates (Twig-like)
│   └── public/       # Static files (served directly)
├── migrations/       # SQL migration files
├── seeds/            # Data seeders
└── spec/             # RSpec tests
```

Auto-discovery scans `src/routes`, `src/api`, and `src/orm` (plus their bare-word variants) for
`**/*.rb` files. **Models live in `src/orm/`**, not `src/models/`.

Start a project and run the dev server:
```bash
tina4rb init      # Scaffold a new Ruby project (alias: tina4 init)
tina4 serve       # Run the dev server — ALWAYS use this
```

**IMPORTANT:** Always run the app with `tina4 serve` (or `tina4ruby start`), not `ruby app.rb`
directly for development. The `tina4` binary is a Rust-based CLI that handles SCSS compilation, file
watching, browser auto-open, and hot reload. Running `ruby app.rb` skips all of this.

The CLI passes `--managed` to the framework server. To bypass the client guard (e.g. Docker, CI),
set `TINA4_OVERRIDE_CLIENT=true` in `.env`.

You get SCSS compilation, hot reload, a debug overlay, and Swagger docs at `/swagger` automatically.
The Ruby dev server listens on port **7147** by default (override with `TINA4_PORT` / `PORT`).

## Lazy means less code, not a flimsier path

The reuse ladder above keeps code minimal — that is never license to skip the essentials.

**Never lazy about:** input validation, security (use `Tina4::Auth`, never hand-rolled), error
handling in routes, and accessibility (labels + placeholders on every input).

**Leave one runnable check** behind non-trivial logic — the smallest thing (one RSpec `expect` or a
tiny spec) that fails if the logic breaks. **Mark deliberate shortcuts** with a `# tina4:` comment
naming the ceiling and the upgrade path:
`# tina4: returns the first match; add pagination when the list grows`.

## Two Ways to Build

Tina4 supports two distinct architectural approaches. Ask the developer which one they want before
writing code — it changes how you structure the app.

### 1. Monolithic (Server-Rendered)

The backend renders full HTML pages using the Frond template engine (Twig-compatible). No frontend
build step, no JS framework, no API layer needed.

```
Browser ←→ Tina4 Routes ←→ Frond Templates ←→ Database
```

- Routes return `response.render("page.twig", data)`
- Templates handle all UI logic (loops, conditionals, includes, macros)
- Live blocks (`{% live %}`) add real-time updates without a JS framework
- frond.js provides lightweight DOM helpers, forms, modals, notifications
- Great for: admin panels, CMS, dashboards, content sites, internal tools

This is the simpler path. If the developer doesn't need a reactive SPA, default to this.

**Server-rendered best practices:**
- **Use frond.js** for AJAX calls, form submissions, and responsive page updates. It eliminates
  complex JavaScript and keeps pages interactive without a full client-side framework.
- **Use Tina4CSS** — a bundled Bootstrap drop-in replacement. It's included, it works, no CDN or npm
  needed. Use it instead of Bootstrap or Tailwind.
- **No inline styles** — Use CSS classes (Tina4CSS or custom stylesheets in `src/public/css/`). If
  you catch yourself writing `style="..."`, create a class instead.
- **Keep routes thin** — Route handlers receive the request, call a helper, return a response.
  Extract business logic into plain Ruby classes under `src/app/`.
- **Use CRUD generation** — For admin interfaces, set `self.auto_crud = true` on the ORM model
  instead of hand-building list/create/edit/delete pages.

### 2. API + Reactive Frontend (Decoupled)

The backend serves as a pure JSON API layer. A separate reactive frontend consumes it.

```
Browser ←→ Reactive Frontend ←→ Tina4 API Routes ←→ Database
```

- Routes return Hashes/Arrays (auto-converted to JSON) or call `response.json(...)`
- Swagger auto-generated at `/swagger` — the frontend team's contract
- **tina4-js** is the preferred frontend — sub-3KB, signals-based, Web Components, no build step
- But React, Preact, Vue, Svelte, or any other frontend framework works too

### 3. Microservices + Queues (Large Scale)

For bigger systems, break the project into multiple Tina4 Ruby services — each its own app with its
own responsibility. The glue between them is the queue.

```
my-platform/
├── api-gateway/          # Tina4 Ruby service — public API
├── order-service/        # Tina4 Ruby service — order CRUD
├── email-worker/         # Tina4 Ruby service — consumes queue, sends emails
└── docker-compose.yml    # Orchestrates all services
```

**Everything is a queue.** Services produce messages and consume them rather than calling each other
directly:

```ruby
# order-service: after saving an order
Tina4::Queue.new(topic: "order-created").push({ "order_id" => order.id })

# email-worker: picks it up and sends confirmation
Tina4::Queue.new(topic: "order-created").consume do |job|
  send_confirmation_email(job.payload["order_id"])
  job.complete
end
```

**When to use this:** multiple teams, independently scaling services, long-running background tasks,
systems where reliability matters. **When NOT to:** small projects and solo MVPs — ship in one app
first, split later when you hit a real wall.

### Pick One — Don't Mix

**Do not build the same UI in both Frond templates AND a reactive frontend.** That creates duplicate
maintenance and conflicting state. Once the developer picks an approach, stick to it:

- **Chose monolithic?** → All UI lives in Frond templates. frond.js is fine for lightweight DOM help.
- **Chose API + reactive?** → Frond templates are NOT used for app UI. The backend only serves JSON.

The only acceptable overlap is using Frond for non-app pages (error pages, email templates, Swagger
docs) while the main app uses a reactive frontend.

**Before writing any UI code, ask:** "Are we doing server-rendered or client-rendered?" Then commit.

## The Golden Rules

1. **Convention over configuration** — Don't create config files. File location IS configuration. A
   route file in `src/routes/` is auto-discovered. A model in `src/orm/` is auto-registered.

2. **Less code wins, but names stay verbose** — Write the minimum code, but spell every variable and
   method name out in full (`customer_invoice_total`, `calculate_outstanding_balance`), never cryptic
   abbreviations. Verbose names, lean code.

3. **The framework is smart** — It handles type conversion automatically:
   - Return a Hash/Array → JSON response
   - Return a String → HTML/text response
   - Return an Integer → status code only
   - Receive a JSON POST body → automatically parsed into `request.body` (a Hash with String keys)
   - No manual `JSON.generate` / `to_json` needed — `response.json(model)` serialises ORM objects,
     Arrays of models, and `DatabaseResult` for you.
   - Status codes: `Tina4::HTTP_OK` 200, `HTTP_CREATED` 201, `HTTP_NO_CONTENT` 204,
     `HTTP_BAD_REQUEST` 400, `HTTP_UNAUTHORIZED` 401, `HTTP_FORBIDDEN` 403, `HTTP_NOT_FOUND` 404,
     `HTTP_SERVER_ERROR` 500 (note: the 500 constant is `HTTP_SERVER_ERROR`, not
     `HTTP_INTERNAL_SERVER_ERROR`).

4. **Show, don't tell** — When a developer asks how to do something, give them working Ruby they can
   drop into `src/routes/` or `src/orm/`. Brief explanation, then the code.

5. **Tina4CSS + frond.js are the default frontend stack** — For any server-rendered page, form, or
   AJAX interaction, use the built-in **Tina4CSS** (a Bootstrap-compatible drop-in in
   `src/public/css/`) and **frond.js** (`/js/frond.js`). They are already installed: no CDN, no npm,
   no Bootstrap, no jQuery, no Tailwind. The reactive **tina4-js** frontend is the exception — use it
   only for a decoupled SPA.

6. **Render a template with `response.render(name, data)`.** To render a page from a route:
   ```ruby
   response.render("login.twig", { title: "Login" })   # renders + responds
   ```
   Need the rendered HTML as a string instead? `Tina4::Template.render("login.twig", data)` (or
   `Tina4::Frond.new(template_dir: "src/templates").render(name, data)`).

7. **Use the built-in `Tina4::API` client for ALL outbound HTTP — never a raw HTTP library.** Every
   call to another service, REST API, webhook, payment gateway, or OAuth endpoint goes through
   `Tina4::API`, not `Net::HTTP` / `HTTParty` / `Faraday` / `open-uri`.
   - **`Tina4::API`** (note: all caps `API` — `Tina4::Api` raises `NameError`) gives automatic JSON
     encode/decode, a default timeout, bearer/basic/custom-header auth, an SSL-verify toggle for dev,
     and **opt-in retry/backoff** (`max_retries:` + `retry_backoff:` — retries transport errors +
     429/5xx, never other 4xx).
   ```ruby
   api = Tina4::API.new("https://api.example.com", bearer_token: token, max_retries: 3)
   r = api.get("/users")            # => Tina4::APIResponse
   users = r.json if r.success?     # r.status, r.body, r.headers, r.error, r.success?
   ```
   The response object is a **`Tina4::APIResponse`** (all caps `API`, not `ApiResponse`).

### Authentication — Secure by Default, Don't Reach for `.no_auth` Blindly

**Tina4 is secure by default.** GET routes are public; **POST/PUT/PATCH/DELETE already require a
`Bearer` token** — the framework returns 401 automatically when it's missing.

> **Hitting a 401 while building a write route? SEND THE TOKEN — don't delete the guard.**
> The 401 means auth is working. Authenticate the request; don't bypass it.

**Two independent gates protect a write route registered with `Tina4.post`:**
1. `Tina4.post` attaches the default bearer-token **auth_handler** (opt out with `auth: false`).
2. The router additionally sets **`auth_required`** for write methods (opt out with `.no_auth`).

**A genuinely public write route (login/register) must clear BOTH gates.** The right way — one public
login route mints a token; every other write carries it:

```ruby
# src/routes/auth.rb — login is public: clear both gates (auth: false + .no_auth)
Tina4.post("/api/login", auth: false) do |request, response|
  user = User.where("email = ?", [request.body["email"]]).first
  unless user && Tina4::Auth.check_password(request.body["password"], user.password)
    next response.json({ error: "Invalid credentials" }, 401)
  end
  token = Tina4::Auth.get_token({ "user_id" => user.id, "role" => user.role })  # signed with TINA4_SECRET
  response.json({ token: token })
end.no_auth

# src/routes/orders.rb — protected automatically; write NOTHING extra
Tina4.post("/api/orders") do |request, response|
  auth = Tina4::Auth.authenticate_request(request.headers)   # verified payload Hash, or nil
  next response.json({ error: "Unauthorized" }, 401) unless auth
  order = Order.create({ **request.body, "user_id" => auth["user_id"] })
  response.json(order.to_h, 201)
end
```

The alternative registration form clears only one gate because it never attaches an auth_handler:
`Tina4::Router.post("/api/login") { |request, response| ... }.no_auth` — `Tina4::Router.post` does
not add the bearer auth_handler, so `.no_auth` (clearing `auth_required`) alone makes it public.

**The client carries the token for you.** frond.js sends the current `Authorization: Bearer` on every
`saveForm`/`sendRequest`; the `Tina4::API` client (`bearer_token:`) does too. Browser forms also get
CSRF protection from `{{ form_token() }}`.

**Never make public** something that writes data, costs money, returns another user's data, uploads a
file, or is an admin action *without* its own check. If you reach for `auth: false` / `.no_auth`, the
handler MUST still authenticate another way (a webhook validated by signature, a SOAP/WS-Security
endpoint validating credentials inside the handler, or an explicitly anonymous read API).

## Language Version

Always target the latest supported Ruby: **Ruby 3.3+** (the Docker image is `ruby:3.3-alpine`). Use
modern Ruby features — keyword arguments, pattern matching, `Comparable`, safe navigation (`&.`).

## Reference Files

Read these when you need detailed Ruby patterns for a specific area:

- **`references/routes-and-api.md`** — Routing (`Tina4.get`/`Tina4.post`), middleware,
  request/response, API design, Swagger. Read for any HTTP/API work.
- **`references/data-and-orm.md`** — ORM models (`table_name`, `integer_field`, `string_field`),
  database connections, migrations, seeding, queries, relationships, QueryBuilder. Read for any data
  work.
- **`references/templates-and-frontend.md`** — Frond templates, live blocks, frond.js, forms, CRUD
  tables, WebSocket. Read for any UI/frontend work.
- **`references/auth-and-services.md`** — JWT auth, sessions, the queue system, email, GraphQL,
  events, caching, i18n. Read for auth or background services.
- **`references/deployment.md`** — Docker (multi-stage `ruby:3.3-alpine`), Docker Compose,
  environment variables, production checklist. Read for ANY deployment work.
- **`references/realtime.md`** — Real-time collaboration (`Tina4::Realtime.mount`): WebRTC
  signalling relay, ICE/TURN config, secured chat WebSocket (presence/typing/read receipts),
  message history, and file upload/download. Read for calls, chat, or collaboration features.
  Pairs with the frontend `tina4-js` `rtc` module, which consumes this surface.

## Environment Configuration

All Tina4 apps use a `.env` file:

```env
TINA4_SECRET=your-jwt-secret-here
TINA4_DATABASE_URL=sqlite:data/app.db
TINA4_DEBUG=true
TINA4_LOG_LEVEL=DEBUG
TINA4_LOCALE=en
TINA4_SESSION_BACKEND=file
```

Database connection strings:
```
sqlite:data/app.db
postgresql://user:password@localhost:5432/mydb
mysql://user:password@localhost:3306/mydb
mssql://user:password@localhost:1433/mydb
firebird://user:password@localhost:3050/mydb
mongodb://user:password@localhost:27017/mydb
```

The app entrypoint (`app.rb`) initialises the framework, binds a database, and starts:
```ruby
require "tina4"
Tina4.initialize!(__dir__)               # loads .env, logging, auth keys, auto-discovers routes/orm
Tina4.bind_database(Tina4::Database.new(ENV["TINA4_DATABASE_URL"]))

# In development just run `tina4 serve` and the CLI boots the server for you.
# A manual entrypoint boots a WebServer directly:
app = Tina4::RackApp.new(root_dir: __dir__)
Tina4::WebServer.new(app, host: ENV.fetch("HOST", "0.0.0.0"), port: ENV.fetch("PORT", 7147).to_i).start
```

## Testing

Tina4 Ruby uses **RSpec**. Tests live in `spec/`.

```bash
tina4 test          # framework test runner
bundle exec rspec   # or run RSpec directly
```

Encourage developers to write specs for their routes, models, and business logic. Use
`Tina4::TestClient` to drive routes in-process (it enforces the exact same auth gates as the live
server, so a tokenless write correctly 401s in a spec too).

**Mock tests are not acceptable, in any circumstances.** Never mock, stub, fake, spy on, or patch a
real dependency. A test that touches a database, queue, cache, session store, mail/HTTP service, or
the filesystem must run against the real thing: a real SQLite file, a real temp directory, the live
service the app uses. Trigger the real failure (a real connection error, a real timeout, a real bad
row), never a simulated one. A green mock test proves nothing.

## Deployment

Tina4 Ruby apps deploy via Docker using a multi-stage `ruby:3.3-alpine` build. **Read
`references/deployment.md` for the exact Dockerfile** — never guess at Docker configuration. The Ruby
server listens on port **7147**, and the app includes a health check at `/health`.

## Plan First — Always

Every feature starts with a plan file in `plan/<feature-name>.md`. Get the developer's approval
before writing code. The plan lists **Criteria** (checklist), **Approach**, and **Status**. Check off
items only when the code works, specs pass, and the developer has confirmed it. If a checked item
breaks, uncheck it — the plan must reflect reality, not aspirations. Close it as
`## Status: Complete` with the date when everything is done.

## Before Building Any Feature

1. **Create a plan** — `plan/<feature-name>.md`, get approval.
2. **"Server-rendered or client-rendered?"** — Ask for any UI work. Check the project for clues
   (`src/templates/` with app pages, or `src/public/` with a JS app). If unclear, ask.
3. **Stay in lane** — Server-rendered → Frond templates. Client-rendered → API endpoints + frontend.
4. **Check what exists** — Look at the project structure before creating new files.
5. **Work the checklist** — Check off items as they pass, uncheck if they regress.

## Code Quality Enforcement

When reviewing Ruby code (including the developer's), evaluate it against Tina4 paradigms:
- Routes are thin — business logic belongs in plain classes under `src/app/`
- No inline styles — CSS classes only (Tina4CSS preferred)
- Convention followed — files in the right directories (`src/routes/`, `src/orm/`)
- No third-party gems where Tina4 provides the feature (ORM, Auth, Queue, `Tina4::API`)
- No mixing server-rendered and client-rendered in the same feature
- Proper error handling — meaningful messages, not silent failures. `model.save` returns `self` on
  success and `false` on failure; recover the cause with `model.get_error` / `model.last_error`.
- Security — parameterized queries (`where("email = ?", [email])`), escaped output, CSRF tokens

If code fails the paradigms: explain what's wrong and why, propose the refactor, and insist. Don't be
passive about code quality — bad patterns spread if left unchecked.

**After completing any feature or milestone:** run specs (all pass), commit with a clear message, and
if on `development`/`staging`, push immediately. Local-only commits on shared branches are a risk.

**No code without tests.** Write the spec first or alongside the code — never "later". Route handlers
get request/response specs; ORM models get CRUD specs; business logic gets unit specs.

## Reporting a Stale or Incorrect Skill

Found guidance here that contradicts how tina4-ruby actually behaves? Then the skill has drifted from
the code. Report it so it gets fixed for everyone:

- Skill report: https://github.com/tina4stack/tina4-documentation/issues/new?labels=skill&template=skill-report.yml
- Or on the web: https://tina4.com/report-a-skill

Include the skill name (`tina4-developer-ruby`), the file and section, what the skill claims, and what
the code actually does (a `lib/tina4/*.rb:line` reference or a short repro). The code is the source of
truth; a skill that disagrees with it is the bug. If you are an AI agent and you hit this drift
mid-task, do not file silently: tell the developer what you found, then file only with their go-ahead.
