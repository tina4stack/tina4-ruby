# Swagger / OpenAPI

Tina4 Ruby auto-generates an OpenAPI 3.0.3 specification from your registered routes. Path parameters, request bodies, and auth requirements are inferred automatically. You can enrich the spec with `swagger_meta` on each route.

## Auto-Generated Spec

```ruby
# Generate the full OpenAPI spec as a Ruby hash
spec = Tina4::Swagger.generate
puts JSON.pretty_generate(spec)
```

## Serving the Spec as JSON

```ruby
Tina4.get "/api/docs/openapi.json" do |request, response|
  spec = Tina4::Swagger.generate
  response.json(spec)
end
```

## Swagger Metadata on Routes

Annotate routes with `swagger_meta` for richer documentation.

```ruby
Tina4.get "/api/users/{id:int}", swagger_meta: {
  summary: "Get a user by ID",
  description: "Returns a single user record",
  tags: ["Users"],
  responses: {
    "200" => { "description" => "User found" },
    "404" => { "description" => "User not found" }
  }
} do |request, response|
  user = User.find(request.params["id"])
  if user
    response.json({ data: user.to_h })
  else
    response.json({ error: "Not found" }, status: 404)
  end
end

Tina4.post "/api/users", auth: false, swagger_meta: {
  summary: "Create a new user",
  tags: ["Users"],
  request_body: {
    "content" => {
      "application/json" => {
        "schema" => {
          "type" => "object",
          "properties" => {
            "name"  => { "type" => "string" },
            "email" => { "type" => "string" }
          },
          "required" => ["name", "email"]
        }
      }
    }
  }
} do |request, response|
  user = User.create(request.body_parsed)
  response.json({ data: user.to_h }, status: 201)
end
```

## Generated Spec Structure

The auto-generated spec includes:

- **info**: Project name and version from env vars (`PROJECT_NAME`, `VERSION`)
- **paths**: One entry per registered route (excluding `ANY` routes)
- **parameters**: Auto-detected from `{param}` and `{param:type}` in path
- **security**: Bearer auth added for routes with an auth handler
- **tags**: Auto-extracted from the first path segment
- **requestBody**: Auto-added for POST/PUT/PATCH methods

## Configuration via Environment

```
PROJECT_NAME="My API"
VERSION="1.0.0"
```

These values appear in the `info` section of the generated spec.

## Path Parameter Conversion

Tina4 route params like `{id:int}` are converted to standard OpenAPI `{id}` format with the correct schema type.

| Tina4 Syntax | OpenAPI Schema |
|---|---|
| `{id}` | `{ "type": "string" }` |
| `{id:int}` | `{ "type": "integer" }` |
| `{price:float}` | `{ "type": "number" }` |

## Swagger UI

Pair the JSON endpoint with Swagger UI for a browser-based API explorer:

```ruby
Tina4.get "/api/docs" do |request, response|
  response.html(<<~HTML)
    <!DOCTYPE html>
    <html>
    <head>
      <title>API Docs</title>
      <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
    </head>
    <body>
      <div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
      <script>
        SwaggerUIBundle({ url: '/api/docs/openapi.json', dom_id: '#swagger-ui' })
      </script>
    </body>
    </html>
  HTML
end
```
