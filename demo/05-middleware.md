# Middleware

Tina4 Ruby supports global before/after middleware hooks and per-route middleware. Before hooks can halt request processing by returning `false`. After hooks run after the route handler completes. Pattern matching lets you scope middleware to specific URL prefixes or regex patterns.

## Global Before Middleware

```ruby
# Runs before every request
Tina4.before do |request, response|
  Tina4::Log.info("#{request.method} #{request.path} from #{request.ip}")
  true  # must return true to continue
end

# Return false to halt the request
Tina4.before do |request, response|
  if request.header("x-blocked") == "true"
    response.json({ error: "Blocked" }, status: 403)
    false  # stops the pipeline
  else
    true
  end
end
```

## Global After Middleware

```ruby
# Runs after every request
Tina4.after do |request, response|
  response.headers["X-Powered-By"] = "Tina4 Ruby"
end
```

## Pattern-Scoped Middleware

Scope middleware to specific URL prefixes using a string pattern.

```ruby
# Only runs for /api/* routes
Tina4.before("/api") do |request, response|
  unless request.bearer_token
    response.json({ error: "Unauthorized" }, status: 401)
    return false
  end
  true
end

# Only runs for /admin/* routes
Tina4.before("/admin") do |request, response|
  auth = request.header("authorization")
  unless auth && auth.include?("admin-token")
    response.json({ error: "Forbidden" }, status: 403)
    return false
  end
  true
end
```

## Regex Pattern Matching

```ruby
# Match any path containing "private"
Tina4.before(/private/) do |request, response|
  Tina4::Log.warning("Accessing private resource: #{request.path}")
  true
end
```

## Per-Route Middleware

Attach middleware directly to individual routes. These run in addition to global middleware.

```ruby
rate_check = ->(request, response) {
  # custom per-route logic
  if request.header("x-rate-exceeded")
    response.json({ error: "Rate limit exceeded" }, status: 429)
    false
  else
    true
  end
}

Tina4::Router.get "/expensive", middleware: [rate_check] do |request, response|
  response.json({ result: "expensive operation" })
end
```

## Per-Route Middleware in Groups

```ruby
logger_mw = ->(request, response) {
  Tina4::Log.info("Group middleware: #{request.path}")
  true
}

Tina4::Router.group "/api/v2", middleware: [logger_mw] do
  get "/users" do |request, response|
    response.json({ users: [] })
  end
end
```

## Request Timing Example

```ruby
Tina4.before do |request, response|
  request.env["tina4.start_time"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  true
end

Tina4.after do |request, response|
  start = request.env["tina4.start_time"]
  if start
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
    response.headers["X-Response-Time"] = "#{elapsed}ms"
    Tina4::Log.info("#{request.method} #{request.path} completed in #{elapsed}ms")
  end
end
```

## CORS Middleware (Built-in)

CORS headers are handled automatically. Configure via environment variables in `.env`:

```
TINA4_CORS_ORIGINS="https://myapp.com,https://admin.myapp.com"
TINA4_CORS_METHODS="GET, POST, PUT, DELETE, OPTIONS"
TINA4_CORS_HEADERS="Content-Type, Authorization, Accept"
TINA4_CORS_CREDENTIALS="true"
TINA4_CORS_MAX_AGE="86400"
```

## Rate Limiting (Built-in)

```ruby
limiter = Tina4::RateLimiter.new(limit: 100, window: 60)

Tina4.before("/api") do |request, response|
  limiter.apply(request.ip, response)
  # Returns false and sets 429 status if rate limited
end
```

Rate limit headers are set automatically on every response:

```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 97
X-RateLimit-Reset: 1711234567
```

## Clearing Middleware (for tests)

```ruby
Tina4::Middleware.clear!
```
