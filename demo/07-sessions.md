# Sessions

Tina4 Ruby provides server-side session management with pluggable storage backends: file (default), Redis, and MongoDB. Sessions are cookie-based, HttpOnly, and lazy-loaded (no session storage hit until accessed).

## Basic Session Usage

Sessions are available on the `request` object and work like a hash.

```ruby
Tina4.get "/login-page", auth: false do |request, response|
  session = request.session

  session["user_id"] = 42
  session["role"] = "admin"
  session.save

  response.json({ message: "Session set" })
end

Tina4.get "/profile", auth: false do |request, response|
  session = request.session

  user_id = session["user_id"]
  role = session["role"]

  response.json({ user_id: user_id, role: role })
end
```

## Session Operations

```ruby
session = request.session

# Read
session["key"]

# Write
session["key"] = "value"

# Delete a key
session.delete("key")

# Clear all session data
session.clear

# Persist changes
session.save

# Destroy session entirely (removes from storage)
session.destroy

# Get all session data as a hash
session.to_hash

# Get the cookie header string
session.cookie_header
```

## Configuration

Create a session with custom options:

```ruby
session = Tina4::Session.new(env, {
  cookie_name: "my_app_session",  # default: "tina4_session"
  max_age: 86400,                  # cookie max age in seconds (default: 86400)
  secret: "my-secret-key",        # default: ENV["SECRET"]
  handler: :file,                  # :file, :redis, or :mongo
  handler_options: {}              # backend-specific options
})
```

## File Backend (Default)

Sessions are stored as JSON files on disk. No external dependencies.

```ruby
session = Tina4::Session.new(env, {
  handler: :file,
  handler_options: {
    dir: "sessions"  # default: "sessions/" in project root
  }
})
```

## Redis Backend

Requires the `redis` gem.

```ruby
session = Tina4::Session.new(env, {
  handler: :redis,
  handler_options: {
    url: "redis://localhost:6379",
    prefix: "tina4:session:",
    ttl: 86400
  }
})
```

## MongoDB Backend

Requires the `mongo` gem.

```ruby
session = Tina4::Session.new(env, {
  handler: :mongo,
  handler_options: {
    url: "mongodb://localhost:27017",
    database: "myapp",
    collection: "sessions"
  }
})
```

## Lazy Sessions

`Tina4::LazySession` wraps the session and only initializes the storage backend when the session is actually accessed. This avoids unnecessary I/O on requests that never touch the session.

```ruby
lazy = Tina4::LazySession.new(env, { handler: :redis })

# No Redis connection yet
lazy["user_id"]  # NOW it connects and loads
lazy["user_id"] = 42
lazy.save
```

## Session in Middleware

```ruby
Tina4.before do |request, response|
  session = request.session
  if session["banned"]
    response.json({ error: "Account suspended" }, status: 403)
    return false
  end
  true
end
```
