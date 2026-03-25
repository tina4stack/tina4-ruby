# Create a Tina4 Route

Create a new route file in `src/routes/`. Follow these rules exactly.

## Instructions

1. Create `src/routes/$ARGUMENTS.rb` (or ask the user for the resource name)
2. Use `Tina4::Router` methods for route registration
3. Follow auth defaults: GET=public, POST/PUT/PATCH/DELETE=secured
4. Use `noauth: true` to make a write route public, `secured: true` to protect a GET
5. Path parameters: `:id`, `:slug`, `*path`
6. Add Swagger options if the route is an API endpoint

## Template

```ruby
require "tina4/router"

Tina4::Router.get "/api/items",
  description: "List all items",
  tags: ["items"] do |request, response|
  # Query params: request.params.fetch("page", "1")
  response.json({ "items" => [] })
end

Tina4::Router.get "/api/items/:id",
  description: "Get a single item",
  tags: ["items"] do |id, request, response|
  response.json({ "id" => id.to_i })
end

Tina4::Router.post "/api/items",
  description: "Create an item",
  tags: ["items"],
  example: { "name" => "Widget", "price" => 9.99 },
  example_response: { "id" => 1, "name" => "Widget" } do |request, response|
  data = request.body
  response.json({ "created" => true }, 201)
end

Tina4::Router.put "/api/items/:id",
  description: "Update an item",
  tags: ["items"] do |id, request, response|
  data = request.body
  response.json({ "updated" => true })
end

Tina4::Router.delete "/api/items/:id",
  description: "Delete an item",
  tags: ["items"] do |id, request, response|
  response.json({ "deleted" => true })
end
```

## Option Order

```
Tina4::Router.post "/path",
  noauth: true,            # auth override (or secured: true for GET)
  description: "...",      # Swagger docs
  tags: ["..."],
  example: {...}
do |request, response|
  # handler
end
```

## Key Rules

- One resource per file (e.g., `users.rb`, `products.rb`)
- Routes auto-discovered from `src/routes/` -- no manual registration
- `request.body` is auto-parsed (Hash for JSON, Hash for form data)
- `request.params` for query string parameters
- `request.headers` for HTTP headers (lowercase keys)
- `request.files` for uploaded files
- Always return `response.json(data)` or `response.json(data, status_code)`
- Use `response.render("template.twig", data)` for HTML pages
