# API Client

Tina4 Ruby includes an HTTP client (`Tina4::API`) for consuming external REST APIs. It supports GET, POST, PUT, PATCH, DELETE, and multipart file uploads. Responses are wrapped in an `APIResponse` object with status, body, headers, and JSON parsing.

## Basic Usage

```ruby
api = Tina4::API.new("https://jsonplaceholder.typicode.com")

# GET
result = api.get("/posts/1")
puts result.status     # => 200
puts result.success?   # => true
puts result.json       # => { "userId" => 1, "id" => 1, "title" => "...", ... }

# GET with query params
result = api.get("/posts", params: { userId: 1, _limit: 5 })
```

## POST / PUT / PATCH / DELETE

```ruby
api = Tina4::API.new("https://jsonplaceholder.typicode.com")

# POST with JSON body
result = api.post("/posts", body: {
  title: "New Post",
  body: "Content here",
  userId: 1
})
puts result.status  # => 201
puts result.json    # => { "id" => 101, ... }

# PUT (full update)
result = api.put("/posts/1", body: {
  id: 1,
  title: "Updated Title",
  body: "Updated content",
  userId: 1
})

# PATCH (partial update)
result = api.patch("/posts/1", body: { title: "Patched Title" })

# DELETE
result = api.delete("/posts/1")
puts result.success?  # => true
```

## Custom Headers

```ruby
# Set default headers for all requests
api = Tina4::API.new("https://api.example.com", headers: {
  "Authorization" => "Bearer my-token",
  "X-Custom-Header" => "value"
})

# Override headers per-request
result = api.get("/data", headers: { "Accept" => "text/plain" })
```

## Timeout

```ruby
# Default timeout is 30 seconds
api = Tina4::API.new("https://api.example.com", timeout: 10)
```

## File Upload

```ruby
api = Tina4::API.new("https://api.example.com")

result = api.upload(
  "/files/upload",
  "/path/to/document.pdf",
  field_name: "file",               # form field name (default: "file")
  extra_fields: { folder: "docs" }  # additional form fields
)
```

## APIResponse Object

```ruby
result = api.get("/data")

result.status    # => Integer (HTTP status code)
result.body      # => String (raw response body)
result.headers   # => Hash (response headers)
result.error     # => String or nil (network/connection errors)
result.success?  # => true if status 200..299
result.json      # => Hash (parsed JSON, returns {} on parse error)
result.to_s      # => "APIResponse(status=200)"
```

## Error Handling

Network errors don't raise exceptions -- they return an `APIResponse` with `status: 0` and the error message.

```ruby
api = Tina4::API.new("https://nonexistent.invalid")
result = api.get("/")

result.status   # => 0
result.success? # => false
result.error    # => "Failed to open TCP connection..."
```

## Using in Routes

```ruby
Tina4.get "/weather/{city}" do |request, response|
  api = Tina4::API.new("https://api.weatherapi.com/v1")
  result = api.get("/current.json", params: {
    key: ENV["WEATHER_API_KEY"],
    q: request.params["city"]
  })

  if result.success?
    response.json(result.json)
  else
    response.json({ error: "Weather API failed", status: result.status }, status: 502)
  end
end
```

## Proxy / Forwarding Example

```ruby
Tina4.any "/proxy/{path:path}" do |request, response|
  api = Tina4::API.new("https://backend.internal")

  result = case request.method
           when "GET"    then api.get("/#{request.params['path']}", params: request.query)
           when "POST"   then api.post("/#{request.params['path']}", body: request.body)
           when "PUT"    then api.put("/#{request.params['path']}", body: request.body)
           when "DELETE" then api.delete("/#{request.params['path']}")
           end

  response.status(result.status)
  response.headers["content-type"] = result.headers["content-type"]&.first || "application/json"
  response.body = result.body
  response
end
```
