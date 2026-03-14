# Tina4 Ruby

**Simple. Fast. Human. This is not a framework.**

A lightweight, zero-configuration, Windows-friendly Ruby web framework. If you know [tina4_python](https://tina4.com) or tina4_php, you'll feel right at home.

## Quick Start

```bash
gem install tina4
tina4 init myapp
cd myapp
bundle install
tina4 start
```

Your app is now running at `http://localhost:7145`.

## Routing

Register routes using a clean Ruby DSL:

```ruby
require "tina4"

# GET request
Tina4.get "/hello" do |request, response|
  response.json({ message: "Hello World!" })
end

# POST request
Tina4.post "/api/users" do |request, response|
  data = request.json_body
  response.json({ created: true, name: data["name"] }, 201)
end

# Path parameters with type constraints
Tina4.get "/api/users/{id:int}" do |request, response|
  user_id = request.params["id"]  # auto-cast to Integer
  response.json({ user_id: user_id })
end

Tina4.get "/files/{path:path}" do |request, response|
  response.json({ path: request.params["path"] })
end

# PUT, PATCH, DELETE
Tina4.put "/api/users/{id:int}" do |request, response|
  response.json({ updated: true })
end

Tina4.delete "/api/users/{id:int}" do |request, response|
  response.json({ deleted: true })
end

# Match any HTTP method
Tina4.any "/webhook" do |request, response|
  response.json({ method: request.method })
end
```

### Auth Defaults

Tina4 Ruby matches tina4_python's auth behavior:

- **GET** routes are **public** by default
- **POST/PUT/PATCH/DELETE** routes are **secured** by default (require `Authorization: Bearer <token>`)
- Use `auth: false` to make a write route public (equivalent to tina4_python's `@noauth()`)
- Set `API_KEY` in `.env` to allow API key bypass (token matches `API_KEY` → access granted)

```ruby
# POST is secured by default — requires Bearer token
Tina4.post "/api/users" do |request, response|
  response.json({ created: true })
end

# Make a POST route public (no auth required)
Tina4.post "/api/webhook", auth: false do |request, response|
  response.json({ received: true })
end

# Custom auth handler
custom_auth = lambda do |env|
  env["HTTP_X_API_KEY"] == "my-secret"
end

Tina4.post "/api/custom", auth: custom_auth do |request, response|
  response.json({ ok: true })
end
```

### Secured Routes

For explicitly securing GET routes (which are public by default):

```ruby
Tina4.secure_get "/api/profile" do |request, response|
  response.json({ user: "authenticated" })
end

Tina4.secure_post "/api/admin/action" do |request, response|
  response.json({ success: true })
end
```

### Route Groups

```ruby
Tina4.group "/api/v1" do
  get("/users") { |req, res| res.json(users) }
  post("/users") { |req, res| res.json({ created: true }) }
end
```

## Request Object

```ruby
Tina4.post "/example" do |request, response|
  request.method        # "POST"
  request.path          # "/example"
  request.params        # merged path + query params
  request.headers       # HTTP headers hash
  request.cookies       # parsed cookies
  request.body          # raw body string
  request.json_body     # parsed JSON body (hash)
  request.bearer_token  # extracted Bearer token
  request.ip            # client IP address
  request.files         # uploaded files
  request.session       # lazy-loaded session
end
```

## Response Object

```ruby
# JSON response
response.json({ key: "value" })
response.json({ key: "value" }, 201)  # custom status

# HTML response
response.html("<h1>Hello</h1>")

# Template rendering
response.render("pages/home.twig", { title: "Welcome" })

# Redirect
response.redirect("/dashboard")
response.redirect("/login", 301)  # permanent redirect

# Plain text
response.text("OK")

# File download
response.file("path/to/document.pdf")

# Custom headers
response.add_header("X-Custom", "value")

# Cookies
response.set_cookie("theme", "dark", max_age: 86400)
response.delete_cookie("theme")

# CORS headers (auto-added by RackApp)
response.add_cors_headers
```

## Templates (Twig)

Tina4 uses a Twig-compatible template engine. Templates go in `templates/` or `src/templates/`.

### Base template (`templates/base.twig`)

```twig
<!DOCTYPE html>
<html>
<head>
  <title>{% block title %}My App{% endblock %}</title>
</head>
<body>
  {% block content %}{% endblock %}
</body>
</html>
```

### Child template (`templates/home.twig`)

```twig
{% extends "base.twig" %}

{% block title %}Home{% endblock %}

{% block content %}
  <h1>Hello {{ name }}!</h1>

  {% if items %}
    <ul>
    {% for item in items %}
      <li>{{ loop.index }}. {{ item | capitalize }}</li>
    {% endfor %}
    </ul>
  {% else %}
    <p>No items found.</p>
  {% endif %}
{% endblock %}
```

### Rendering

```ruby
Tina4.get "/home" do |request, response|
  response.render("home.twig", {
    name: "Alice",
    items: ["apple", "banana", "cherry"]
  })
end
```

### Filters

```twig
{{ name | upper }}              {# ALICE #}
{{ name | lower }}              {# alice #}
{{ name | capitalize }}         {# Alice #}
{{ "hello world" | title }}     {# Hello World #}
{{ "  hi  " | trim }}           {# hi #}
{{ items | length }}            {# 3 #}
{{ items | join(", ") }}        {# a, b, c #}
{{ missing | default("N/A") }} {# N/A #}
{{ html | escape }}             {# &lt;b&gt;hi&lt;/b&gt; #}
{{ text | nl2br }}              {# line<br>break #}
{{ 3.14159 | round(2) }}        {# 3.14 #}
{{ data | json_encode }}        {# {"key":"value"} #}
```

### Includes

```twig
{% include "partials/header.twig" %}
```

### Variables and Math

```twig
{% set greeting = "Hello" %}
{{ greeting ~ " " ~ name }}     {# string concatenation #}
{{ price * quantity }}           {# math #}
```

### Comments

```twig
{# This is a comment and won't be rendered #}
```

## Database

Multi-database support with a unified API:

```ruby
# SQLite (default, zero-config)
db = Tina4::Database.new("sqlite://app.db")

# PostgreSQL
db = Tina4::Database.new("postgresql://localhost:5432/mydb")

# MySQL
db = Tina4::Database.new("mysql://localhost:3306/mydb")

# MSSQL
db = Tina4::Database.new("mssql://localhost:1433/mydb")
```

### Querying

```ruby
# Fetch multiple rows
result = db.fetch("SELECT * FROM users WHERE age > ?", [18])
result.each { |row| puts row[:name] }

# Fetch one row
user = db.fetch_one("SELECT * FROM users WHERE id = ?", [1])

# Pagination
result = db.fetch("SELECT * FROM users", [], limit: 10, skip: 20)

# Insert
db.insert("users", { name: "Alice", email: "alice@example.com" })

# Update
db.update("users", { name: "Alice Updated" }, { id: 1 })

# Delete
db.delete("users", { id: 1 })

# Raw SQL
db.execute("CREATE INDEX idx_email ON users(email)")

# Transactions
db.transaction do |tx|
  tx.insert("accounts", { name: "Savings", balance: 1000 })
  tx.update("accounts", { balance: 500 }, { id: 1 })
end

# Introspection
db.tables                    # ["users", "posts", ...]
db.table_exists?("users")   # true
db.columns("users")         # [{name: "id", type: "INTEGER", ...}, ...]
```

### DatabaseResult

```ruby
result = db.fetch("SELECT * FROM users")
result.count          # number of rows
result.empty?         # true/false
result.first          # first row hash
result.to_array       # array of hashes
result.to_json        # JSON string
result.to_csv         # CSV text
result.to_paginate    # { records_total:, record_count:, data: }
```

## ORM

Define models with a field DSL:

```ruby
class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name, nullable: false
  string_field  :email, length: 255
  integer_field :age, default: 0
  datetime_field :created_at
end

# Set the database connection
Tina4.database = Tina4::Database.new("sqlite://app.db")
```

### CRUD Operations

```ruby
# Create
user = User.new(name: "Alice", email: "alice@example.com")
user.save

# Or create in one step
user = User.create(name: "Bob", email: "bob@example.com")

# Read
user = User.find(1)                              # by primary key
users = User.where("age > ?", [18])              # with conditions
all_users = User.all                             # all records
all_users = User.all(limit: 10, order_by: "name")

# Update
user = User.find(1)
user.name = "Alice Updated"
user.save

# Delete
user.delete

# Load into existing instance
user = User.new
user.id = 1
user.load

# Serialization
user.to_hash   # { id: 1, name: "Alice", ... }
user.to_json   # '{"id":1,"name":"Alice",...}'
```

### Field Types

```ruby
integer_field   :id
string_field    :name, length: 255
text_field      :bio
float_field     :score
decimal_field   :price, precision: 10, scale: 2
boolean_field   :active
date_field      :birthday
datetime_field  :created_at
timestamp_field :updated_at
blob_field      :avatar
json_field      :metadata
```

## Migrations

```bash
# Create a migration
tina4 migrate --create "create users table"

# Run pending migrations
tina4 migrate

# Rollback
tina4 migrate --rollback 1
```

Migration files are plain SQL in `migrations/`:

```sql
-- migrations/20260313120000_create_users_table.sql
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  age INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## Authentication

JWT RS256 tokens with auto-generated RSA keys:

```ruby
# Generate a token
token = Tina4::Auth.generate_token({ user_id: 42, role: "admin" })

# Validate a token
result = Tina4::Auth.validate_token(token)
if result[:valid]
  payload = result[:payload]
  puts payload["user_id"]  # 42
end

# Password hashing (bcrypt)
hash = Tina4::Auth.hash_password("secret123")
Tina4::Auth.verify_password("secret123", hash)  # true
Tina4::Auth.verify_password("wrong", hash)       # false
```

### Protecting Routes

```ruby
# Built-in Bearer auth
Tina4.secure_get "/api/profile" do |request, response|
  # Only runs if valid JWT Bearer token is provided
  response.json({ user: "authenticated" })
end

# Custom auth handler
custom_auth = lambda do |env|
  api_key = env["HTTP_X_API_KEY"]
  api_key == "my-secret-key"
end

Tina4.secure_get "/api/data", auth: custom_auth do |request, response|
  response.json({ data: "protected" })
end
```

## Sessions

```ruby
Tina4.post "/login" do |request, response|
  request.session["user_id"] = 42
  request.session["role"] = "admin"
  request.session.save
  response.json({ logged_in: true })
end

Tina4.get "/profile" do |request, response|
  user_id = request.session["user_id"]
  response.json({ user_id: user_id })
end

Tina4.post "/logout" do |request, response|
  request.session.destroy
  response.json({ logged_out: true })
end
```

Session backends: `:file` (default), `:redis`, `:mongo`.

## Middleware

```ruby
# Run before every request
Tina4.before do |request, response|
  puts "Request: #{request.method} #{request.path}"
end

# Run after every request
Tina4.after do |request, response|
  puts "Response: #{response.status}"
end

# Pattern matching
Tina4.before("/api") do |request, response|
  # Only runs for paths starting with /api
end

Tina4.before(/\/admin\/.*/) do |request, response|
  # Regex pattern matching
  return false unless request.session["role"] == "admin"  # halts request
end
```

## Swagger / OpenAPI

Auto-generated API documentation at `/swagger`:

```ruby
Tina4.get "/api/users", swagger_meta: {
  summary: "List all users",
  tags: ["Users"],
  description: "Returns a paginated list of users"
} do |request, response|
  response.json(users)
end
```

Visit `http://localhost:7145/swagger` for the interactive Swagger UI.

## GraphQL

Zero-dependency GraphQL support with a custom parser, executor, and ORM auto-schema generation.

### Manual Schema

```ruby
schema = Tina4::GraphQLSchema.new

# Add queries
schema.add_query("hello", type: "String") { |_root, _args, _ctx| "Hello World!" }

schema.add_query("user", type: "User", args: { "id" => { type: "ID!" } }) do |_root, args, _ctx|
  User.find(args["id"])&.to_hash
end

# Add mutations
schema.add_mutation("createUser", type: "User",
  args: { "name" => { type: "String!" }, "email" => { type: "String!" } }
) do |_root, args, _ctx|
  User.create(name: args["name"], email: args["email"]).to_hash
end

# Register the /graphql endpoint
gql = Tina4::GraphQL.new(schema)
gql.register_route  # POST /graphql + GET /graphql (GraphiQL UI)
```

### ORM Auto-Schema

Generate full CRUD queries and mutations from your ORM models with one line:

```ruby
schema = Tina4::GraphQLSchema.new
schema.from_orm(User)     # Creates: user, users, createUser, updateUser, deleteUser
schema.from_orm(Product)  # Creates: product, products, createProduct, updateProduct, deleteProduct

gql = Tina4::GraphQL.new(schema)
gql.register_route("/graphql")
```

This auto-generates:
- **Queries:** `user(id)` (single), `users(limit, offset)` (list with pagination)
- **Mutations:** `createUser(input)`, `updateUser(id, input)`, `deleteUser(id)`

### Query Examples

```graphql
# Simple query
{ hello }

# Nested fields with arguments
{ user(id: 42) { id name email } }

# List with pagination
{ users(limit: 10, offset: 0) { id name } }

# Aliases
{ admin: user(id: 1) { name } guest: user(id: 2) { name } }

# Variables
query GetUser($userId: ID!) {
  user(id: $userId) { id name email }
}

# Fragments
fragment UserFields on User { id name email }
{ user(id: 1) { ...UserFields } }

# Mutations
mutation {
  createUser(name: "Alice", email: "alice@example.com") { id name }
}
```

### Programmatic Execution

```ruby
gql = Tina4::GraphQL.new(schema)

# Execute a query directly
result = gql.execute('{ hello }')
puts result["data"]["hello"]  # "Hello World!"

# With variables
result = gql.execute(
  'query($id: ID!) { user(id: $id) { name } }',
  variables: { "id" => 42 }
)

# Handle an HTTP request body (JSON string)
result = gql.handle_request('{"query": "{ hello }"}')
```

Visit `http://localhost:7145/graphql` for the interactive GraphiQL UI.

## REST API Client

```ruby
api = Tina4::API.new("https://api.example.com", headers: {
  "Authorization" => "Bearer sk-abc123"
})

# GET
response = api.get("/users", params: { page: 1 })
puts response.json  # parsed response body

# POST
response = api.post("/users", body: { name: "Alice" })
puts response.success?  # true for 2xx status
puts response.status    # 201

# PUT, PATCH, DELETE
api.put("/users/1", body: { name: "Updated" })
api.patch("/users/1", body: { name: "Patched" })
api.delete("/users/1")

# File upload
api.upload("/files", "path/to/file.pdf")
```

## Environment Variables

Tina4 auto-creates and loads `.env` files:

```env
PROJECT_NAME=My App
VERSION=1.0.0
SECRET=my-jwt-secret
API_KEY=your-api-key-here
DATABASE_URL=sqlite://app.db
TINA4_DEBUG_LEVEL=[TINA4_LOG_DEBUG]
ENVIRONMENT=development
```

`API_KEY` enables a static bearer token bypass — any request with `Authorization: Bearer <API_KEY>` is granted access without JWT validation.

Supports environment-specific files: `.env.development`, `.env.production`, `.env.test`.

## CLI Commands

```bash
tina4 init [NAME]       # Scaffold a new project
tina4 start             # Start the web server (default port 7145)
tina4 start -p 3000     # Custom port
tina4 start -d          # Dev mode with auto-reload
tina4 migrate           # Run pending migrations
tina4 migrate --create "desc"   # Create a migration
tina4 migrate --rollback 1      # Rollback migrations
tina4 test              # Run inline tests
tina4 routes            # List all registered routes
tina4 console           # Interactive Ruby console
tina4 version           # Show version
```

## Project Structure

```
myapp/
├── app.rb               # Entry point
├── .env                 # Environment config
├── Gemfile
├── migrations/          # SQL migrations
├── routes/              # Auto-discovered route files
├── templates/           # Twig/ERB templates
├── public/              # Static files (CSS, JS, images)
│   ├── css/
│   ├── js/
│   └── images/
├── src/                 # Application code
└── logs/                # Log files
```

Routes in `routes/` are auto-discovered at startup:

```ruby
# routes/users.rb
Tina4.get "/api/users" do |request, response|
  response.json(User.all.map(&:to_hash))
end
```

## Auto-Discovery

Tina4 automatically loads:
- Route files from `routes/`, `src/routes/`, `src/api/`, `api/`
- `app.rb` and `index.rb` from the project root

## Full Example App

```ruby
# app.rb
require "tina4"

# Database
Tina4.database = Tina4::Database.new("sqlite://app.db")

# Model
class Todo < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title, nullable: false
  boolean_field :done, default: false
end

# Routes
Tina4.get "/" do |request, response|
  response.render("home.twig", { todos: Todo.all.map(&:to_hash) })
end

Tina4.get "/api/todos" do |request, response|
  response.json(Todo.all.map(&:to_hash))
end

Tina4.post "/api/todos" do |request, response|
  todo = Todo.create(title: request.json_body["title"])
  response.json(todo.to_hash, 201)
end

Tina4.put "/api/todos/{id:int}" do |request, response|
  todo = Todo.find(request.params["id"])
  todo.done = request.json_body["done"]
  todo.save
  response.json(todo.to_hash)
end

Tina4.delete "/api/todos/{id:int}" do |request, response|
  Todo.find(request.params["id"]).delete
  response.json({ deleted: true })
end
```

## Requirements

- Ruby >= 3.1.0
- Works on Windows, macOS, and Linux

## License

MIT
