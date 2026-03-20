# Routing

Tina4 Ruby provides a DSL for defining HTTP routes with path parameters, type hints, and route groups. Routes use `{param}` syntax (not `:param`). GET routes are public by default; POST/PUT/PATCH/DELETE are secured with bearer auth by default.

Routes can be defined inline in `app.rb` or in separate files under `routes/` (auto-discovered on startup).

## Basic Routes

```ruby
require "tina4"

# GET is public by default
Tina4.get "/hello" do |request, response|
  response.json({ message: "Hello, world!" })
end

# POST is secured by default (requires Bearer token)
Tina4.post "/items", auth: false do |request, response|
  data = request.body_parsed
  response.json({ created: data }, status: 201)
end

Tina4.put "/items/{id}", auth: false do |request, response|
  id = request.params["id"]
  response.json({ updated: id })
end

Tina4.patch "/items/{id}", auth: false do |request, response|
  response.json({ patched: request.params["id"] })
end

Tina4.delete "/items/{id}", auth: false do |request, response|
  response.json({ deleted: request.params["id"] })
end

# Match any HTTP method
Tina4.any "/catch-all" do |request, response|
  response.json({ method: request.method, path: request.path })
end
```

## Path Parameters with Type Hints

Parameters are extracted from `{name}` placeholders. Add type hints with `{name:type}`.

```ruby
# String param (default)
Tina4.get "/users/{username}" do |request, response|
  response.json({ username: request.params["username"] })
end

# Integer param -- auto-cast to Integer
Tina4.get "/users/{id:int}" do |request, response|
  id = request.params["id"]  # => Integer
  response.json({ id: id, type: id.class.name })
end

# Float param
Tina4.get "/products/{price:float}" do |request, response|
  response.json({ price: request.params["price"] })  # => Float
end

# Catch-all (path) param -- matches slashes
Tina4.get "/files/{path:path}" do |request, response|
  response.json({ file_path: request.params["path"] })
end
# GET /files/docs/readme.txt => { file_path: "docs/readme.txt" }
```

## Route Groups

Group routes under a shared prefix with optional shared auth.

```ruby
Tina4.group "/api/v1" do
  get "/users" do |request, response|
    response.json({ users: [] })
  end

  post "/users" do |request, response|
    response.json({ created: true })
  end

  get "/users/{id:int}" do |request, response|
    response.json({ id: request.params["id"] })
  end
end

# Nested groups
Tina4.group "/api" do
  group "/v2" do
    get "/status" do |request, response|
      response.json({ version: 2, status: "ok" })
    end
  end
end
```

## Secured Routes

```ruby
# Explicitly secured GET (GET is public by default)
Tina4.secure_get "/admin/dashboard" do |request, response|
  response.json({ admin: true })
end

# POST is secured by default -- use auth: false to make it public
Tina4.post "/public/submit", auth: false do |request, response|
  response.json({ submitted: true })
end

# Custom auth handler
custom_auth = ->(env) {
  token = env["HTTP_X_API_KEY"]
  token == "my-secret-key"
}

Tina4.get "/custom", auth: custom_auth do |request, response|
  response.json({ authenticated: true })
end
```

## File-Based Route Discovery

Place route files in `routes/` (or `src/routes/`). They are auto-loaded on startup.

```
routes/
  api/
    users/
      get.rb        # GET /api/users
      post.rb       # POST /api/users
      {id}/
        get.rb      # GET /api/users/{id}
        put.rb      # PUT /api/users/{id}
        delete.rb   # DELETE /api/users/{id}
```

Example `routes/api/users/get.rb`:

```ruby
Tina4.get "/api/users" do |request, response|
  limit = (request.query["limit"] || 10).to_i
  offset = (request.query["offset"] || 0).to_i
  response.json({ users: [], limit: limit, offset: offset })
end
```

## Response Types

The `response` object supports multiple output formats.

```ruby
Tina4.get "/html" do |request, response|
  response.html("<h1>Hello</h1>")
end

Tina4.get "/text" do |request, response|
  response.text("plain text")
end

Tina4.get "/xml" do |request, response|
  response.xml("<root><item>1</item></root>")
end

Tina4.get "/csv" do |request, response|
  response.csv("name,age\nAlice,30\n", filename: "export.csv")
end

Tina4.get "/redirect" do |request, response|
  response.redirect("/somewhere-else", status: 301)
end

Tina4.get "/download" do |request, response|
  response.file("/path/to/report.pdf", download: true)
end

Tina4.get "/template" do |request, response|
  response.render("pages/home.twig", { title: "Home", user: "Alice" })
end
```

## Request Object

Access query params, headers, body, cookies, and more from the `request` object.

```ruby
Tina4.post "/echo" do |request, response|
  response.json({
    method: request.method,
    path: request.path,
    url: request.url,
    ip: request.ip,
    query: request.query,
    body: request.body_parsed,
    json: request.json_body,
    headers: request.headers,
    cookies: request.cookies,
    bearer: request.bearer_token,
    files: request.files.keys
  })
end
```

## Listing Routes

```bash
tina4ruby routes
```

Output:

```
Registered Routes:
------------------------------------------------------------
  GET      /hello
  POST     /items
  GET      /api/v1/users
  POST     /api/v1/users [AUTH]
------------------------------------------------------------
Total: 4 routes
```
