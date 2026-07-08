# Authentication & Services (Ruby)

## JWT Authentication

All auth lives on the `Tina4::Auth` module. Ruby method names are snake_case.

### Setup

Set your secret in `.env`:
```env
TINA4_SECRET=a-long-random-string-here
```

Generate a strong secret with `openssl rand -hex 32`. In local dev (`TINA4_DEBUG=true`) a per-machine
secret is generated into `.env.local` automatically; in CI/production a blank secret triggers a loud
warning and JWT signing is insecure — always set `TINA4_SECRET` before serving traffic.

### The login route mints a token (public)

A write route is secure by default. Login must be public, so clear **both** auth gates:
`Tina4.post(..., auth: false)` (removes the bearer auth_handler) **and** `.no_auth` (clears the
write-method `auth_required` flag).

```ruby
# src/routes/auth.rb
Tina4.post("/api/login", auth: false) do |request, response|
  user = User.where("email = ?", [request.body["email"]]).first
  unless user && Tina4::Auth.check_password(request.body["password"], user.password)
    next response.json({ error: "Invalid credentials" }, 401)
  end
  token = Tina4::Auth.get_token({ "user_id" => user.id, "email" => user.email })
  response.json({ token: token })
end.no_auth
```

`get_token(payload, expires_in: 60, secret: nil)` returns a signed JWT (`expires_in` is in minutes).

### Protecting routes

POST/PUT/PATCH/DELETE are already protected (401 without a valid `Bearer` token). Inside a protected
handler, read the verified payload with `authenticate_request`:

```ruby
Tina4.post "/api/orders" do |request, response|
  auth = Tina4::Auth.authenticate_request(request.headers)   # verified payload Hash, or nil
  next response.json({ error: "Unauthorized" }, 401) unless auth
  order = Order.create({ **request.body, "user_id" => auth["user_id"] })
  response.json(order.to_h, 201)
end
```

To protect a **GET** route (public by default), register it with `Tina4.secure_get` instead of
`Tina4.get`, or attach an auth middleware.

Other `Tina4::Auth` helpers:
```ruby
Tina4::Auth.valid_token(token)      # => decoded payload Hash on success, nil on failure
Tina4::Auth.get_payload(token)      # decode WITHOUT verifying (read claims only)
Tina4::Auth.refresh_token(token)    # re-issue a fresh token if the current one is valid
```

### API-key auth

`authenticate_request` also accepts a static API key (timing-safe compared against `TINA4_API_KEY`).
To validate one directly, pass the expected value as the **keyword** `expected:`:

```ruby
Tina4::Auth.validate_api_key(provided_key, expected: ENV["TINA4_API_KEY"])
# expected: defaults to ENV["TINA4_API_KEY"] when omitted
```

### Password Hashing

```ruby
hashed  = Tina4::Auth.hash_password("mypassword")             # pbkdf2_sha256$...
matches = Tina4::Auth.check_password("mypassword", hashed)    # => true / false
```

`check_password(password, hash)` — plaintext first, stored hash second — timing-safe.

## Sessions

Configure the backend in `.env`:
```env
TINA4_SESSION_BACKEND=file    # file, redis, valkey, mongodb, database
```

`request.session` supports both `get`/`set` and `[]`/`[]=`:

```ruby
Tina4.post("/login", auth: false) do |request, response|
  # ...after validating credentials...
  request.session.set("user_id", user.id)      # or request.session["user_id"] = user.id
  response.redirect("/dashboard")
end.no_auth

Tina4.get "/dashboard" do |request, response|
  user_id = request.session.get("user_id")      # or request.session["user_id"]
  next response.redirect("/login") unless user_id
  response.render("dashboard.twig", { user: User.find_by_id(user_id) })
end

Tina4.get "/logout" do |request, response|
  request.session.clear
  response.redirect("/")
end
```

## Queue System

For background jobs — sending emails, processing uploads, external API calls. Create a queue with
`Tina4::Queue.new(topic: "...")`.

### Producing

```ruby
Tina4.post "/orders" do |request, response|
  order = Order.create(request.body)
  Tina4::Queue.new(topic: "order-emails").push({
    "order_id" => order.id,
    "email"    => request.body["email"],
    "type"     => "confirmation"
  })
  response.json(order.to_h, 201)
end
```

`push(payload, priority: 0, delay_seconds: 0)` — higher `priority` runs first; `delay_seconds` defers
the job. There's also `produce(topic, payload, priority:, delay_seconds:)`.

### Consuming (background worker)

```ruby
Tina4::Queue.new(topic: "order-emails").consume do |job|
  send_order_email(job.payload)
  job.complete            # ack; use job.fail("reason") to nack, job.retry to requeue
end
```

`consume(topic = nil, poll_interval: 1.0, iterations: 0, batch_size: 1)` loops and yields each `Job`.
A `Job` exposes `payload`, `topic`, `attempts`, and `complete` / `fail(reason)` / `retry`. For a
single controlled pass use `process(max_jobs:, batch_size:) { |job| ... }`.

## Email (Messenger)

```ruby
Tina4.post "/contact", auth: false do |request, response|
  Tina4::Messenger.new.send(
    to: request.body["email"],
    subject: "Thanks for reaching out",
    body: "<h1>We received your message</h1>",
    html: true                          # note: html:, not is_html:
  )
  response.json({ status: "sent" })
end.no_auth
```

`send(to:, subject:, body:, html: false, cc: [], bcc: [], ...)` — all keyword arguments.

## WebSocket

Register a WebSocket route with `Tina4.websocket`. The handler block receives
`(connection, event, data)` where `event` is `:open`, `:message`, or `:close` and `data` is the
String payload for `:message`.

```ruby
# Server — public by default; use Tina4.secure_websocket (or .secure) to require a JWT on upgrade
Tina4.websocket "/ws/chat" do |connection, event, data|
  case event
  when :open
    connection.send("welcome")
  when :message
    connection.broadcast(data)         # send to all connected clients
  when :close
    # cleanup
  end
end
```

```javascript
// Client (frond.js)
const ws = Frond.ws("/ws/chat", {
  reconnect: true,
  onMessage: (data) => { document.getElementById("messages").innerHTML += `<p>${data}</p>`; }
});
document.getElementById("send").onclick = () => ws.send(document.getElementById("input").value);
```

## GraphQL

Auto-generate a GraphQL API from your ORM models:

```ruby
gql = Tina4::GraphQL.new
gql.auto_register(User, Post)
gql.register_route("/graphql")     # GET = GraphiQL IDE, POST = queries
```

Decorator-free resolvers register on the schema:
```ruby
Tina4::GraphQL.resolve("Query", "userByEmail") do |root, args, ctx|
  User.where("email = ?", [args["email"]]).first
end
```

Visit `/graphql` in the browser for the GraphiQL IDE.

## Events

Decouple app logic with events on `Tina4::Events`:

```ruby
Tina4::Events.on("user.created") do |data|
  Tina4::Messenger.new.send(to: data["email"], subject: "Welcome!", body: "...")
end

Tina4::Events.on("user.created") do |data|
  Settings.create({ "user_id" => data["id"], "theme" => "light" })
end

# Fire the event:
Tina4.post "/register", auth: false do |request, response|
  user = User.create(request.body)
  Tina4::Events.emit("user.created", { "id" => user.id, "email" => user.email })
  response.json(user.to_h, 201)
end.no_auth
```

`on(event, priority: 0, &block)` — higher priority runs first. `emit(event, *args)` fires all
listeners; `emit_async` runs them off the request path.

## i18n / Localization

Translation files go in `src/locales/` as JSON:
```json
// src/locales/en.json
{ "welcome": "Welcome, {name}!", "logout": "Sign out" }
```

Set the language in `.env` (`TINA4_LOCALE=en`). In code: `Tina4.t("welcome", name: user.name)`. In
templates:
```twig
{{ "welcome" | trans({"name": user.name}) }}
{{ "logout" | trans }}
```

## Caching

Built-in, zero-dep caching (`Tina4::Cache`). Use `{% cache %}` blocks in templates (see
`templates-and-frontend.md`), or the cache API in code for expensive operations.
