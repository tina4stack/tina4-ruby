# Tina4 Ruby 3.10.44 — Conventions

## Framework

Tina4 Ruby is a zero-dependency, batteries-included web framework. Docs: https://tina4.com

## Project Structure

```
src/routes/    — Route handlers (auto-discovered)
src/orm/       — ORM models
src/templates/ — Twig templates
src/app/       — Service classes
src/scss/      — SCSS (auto-compiled)
src/public/    — Static assets
src/seeds/     — Database seeders
migrations/    — SQL migration files
spec/          — RSpec tests
```

## CLI

```bash
tina4ruby init .          # Scaffold project
tina4ruby serve           # Start dev server on port 7147
tina4ruby migrate         # Run database migrations
tina4ruby test            # Run test suite
tina4ruby routes          # List all registered routes
```

## Route Pattern

```ruby
Tina4.get "/api/users" do |request, response|
  response.call({ users: [] }, Tina4::HTTP_OK)
end

Tina4.post "/api/users" do |request, response|
  response.call({ created: request.body["name"] }, 201)
end
```

## ORM Pattern

```ruby
class User < Tina4::ORM
  table_name "users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, required: true
  string_field :email
end
```

## Conventions

1. Routes return `response.call(data, status)` — never `puts` or `render`
2. GET routes are public; POST/PUT/PATCH/DELETE require auth by default
3. Every template extends `base.twig`
4. All schema changes via migrations — never create tables in route code
5. Use built-in features — never install gems for things Tina4 already provides
6. Service pattern — complex logic in `src/app/`, routes stay thin
7. Use `snake_case` for methods and variables
8. Wrap route logic in `begin/rescue`, log with `Tina4::Log.error()`

## Built-in Features

Router, ORM, Database (SQLite/PostgreSQL/MySQL/MSSQL/Firebird), Frond templates (Twig-compatible), JWT auth, Sessions (File/Redis/Valkey/MongoDB/DB), GraphQL + GraphiQL, WebSocket + Redis backplane, WSDL/SOAP, Queue (File/RabbitMQ/Kafka/MongoDB), HTTP client, Messenger (SMTP/IMAP), FakeData/Seeder, Migrations, SCSS compiler, Swagger/OpenAPI, i18n, Events, Container/DI, HtmlElement, Inline testing, Error overlay, Dev dashboard, Rate limiter, Response cache, Logging, MCP server

## Testing

Run: `bundle exec rspec` or `tina4ruby test`. Tests in `spec/`.
