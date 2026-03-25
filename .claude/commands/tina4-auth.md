# Set Up Tina4 Authentication

Set up JWT authentication with login, password hashing, and route protection.

## Instructions

1. Ensure `SECRET` is set in `.env`
2. Create a users table with password_hash column (migration)
3. Create login/register routes
4. Protect routes with auth defaults or `secured: true`

## .env

```bash
SECRET=your-secure-random-secret
```

## Migration

```sql
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

## Auth Routes (`src/routes/auth.rb`)

```ruby
require "tina4/router"
require "tina4/auth"

auth = Tina4::Auth.new

Tina4::Router.post "/api/register",
  noauth: true,
  description: "Register a new user",
  tags: ["auth"] do |request, response|
  require_relative "../orm/user"
  data = request.body

  # Check if email already exists
  existing = User.new
  if existing.load("email = ?", [data.fetch("email", "")])
    return response.json({ "error" => "Email already registered" }, 409)
  end

  user = User.new({
    "name" => data["name"],
    "email" => data["email"],
    "password_hash" => Tina4::Auth.hash_password(data["password"])
  })
  user.save
  response.json({ "id" => user.id, "name" => user.name }, 201)
end

Tina4::Router.post "/api/login",
  noauth: true,
  description: "Login and get JWT token",
  tags: ["auth"] do |request, response|
  require_relative "../orm/user"
  email = request.body.fetch("email", "")
  password = request.body.fetch("password", "")

  user = User.new
  unless user.load("email = ?", [email])
    return response.json({ "error" => "Invalid credentials" }, 401)
  end

  unless Tina4::Auth.check_password(user.password_hash, password)
    return response.json({ "error" => "Invalid credentials" }, 401)
  end

  token = auth.create_token({ "user_id" => user.id, "email" => user.email, "role" => user.role })
  response.json({ "token" => token })
end

Tina4::Router.get "/api/me",
  secured: true,
  description: "Get current user profile",
  tags: ["auth"] do |request, response|
  token = request.headers.fetch("authorization", "").sub("Bearer ", "")
  payload = auth.get_payload(token)
  unless payload
    return response.json({ "error" => "Invalid token" }, 401)
  end
  response.json(payload)
end
```

## How Auth Works

- **GET routes** are public by default
- **POST/PUT/PATCH/DELETE routes** require `Authorization: Bearer <token>` by default
- Use `noauth: true` on write routes that should be public (login, register, webhooks)
- Use `secured: true` on GET routes that need protection (profile, admin pages)

## Auth Functions

```ruby
require "tina4/auth"

auth = Tina4::Auth.new                         # Uses SECRET from .env
auth = Tina4::Auth.new(secret: "custom-secret") # Or custom secret

token = auth.create_token({ "user_id" => 1 })  # Create JWT
valid = auth.validate_token(token)              # Returns true/false
payload = auth.get_payload(token)               # Returns Hash or nil
new_token = auth.refresh_token(token)           # Refresh before expiry

hashed = Tina4::Auth.hash_password("my-password")        # PBKDF2-HMAC-SHA256
valid = Tina4::Auth.check_password(hashed, "my-password") # Returns true/false
```
