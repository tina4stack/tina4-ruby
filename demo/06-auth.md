# Auth

Tina4 Ruby includes JWT authentication with RS256 signing, password hashing via bcrypt, bearer token validation, and API key bypass. RSA key pairs are auto-generated in `.keys/` on first use.

## JWT Token Generation

```ruby
# Generate a JWT token with custom payload
token = Tina4::Auth.generate_token(
  { user_id: 42, role: "admin" },
  expires_in: 3600  # 1 hour (default)
)
# => "eyJhbGciOiJSUzI1NiJ9..."
```

## Token Validation

```ruby
result = Tina4::Auth.validate_token(token)

if result[:valid]
  payload = result[:payload]
  puts payload["user_id"]  # => 42
  puts payload["role"]     # => "admin"
  puts payload["exp"]      # => expiration timestamp
else
  puts result[:error]      # => "Token expired" or decode error
end
```

## Password Hashing

```ruby
# Hash a password (bcrypt)
hashed = Tina4::Auth.hash_password("my-secret-password")
# => "$2a$12$..."

# Verify a password
Tina4::Auth.verify_password("my-secret-password", hashed)
# => true

Tina4::Auth.verify_password("wrong-password", hashed)
# => false
```

## Secured Routes

POST, PUT, PATCH, DELETE routes are secured by default with bearer auth. GET routes are public by default.

```ruby
# This POST route requires a valid Bearer token
Tina4.post "/api/articles" do |request, response|
  # Token is already validated -- access payload via env
  auth_payload = request.env["tina4.auth"]
  response.json({ created_by: auth_payload["user_id"] })
end

# Make a POST route public
Tina4.post "/api/register", auth: false do |request, response|
  response.json({ registered: true })
end

# Explicitly secure a GET route
Tina4.secure_get "/api/profile" do |request, response|
  auth = request.env["tina4.auth"]
  response.json({ user_id: auth["user_id"] })
end
```

## Login Route Example

```ruby
Tina4.post "/api/login", auth: false do |request, response|
  begin
    email = request.body_parsed["email"]
    password = request.body_parsed["password"]

    user = User.find(email: email)&.first
    unless user
      next response.json({ error: "Invalid credentials" }, status: 401)
    end

    unless Tina4::Auth.verify_password(password, user.password_hash)
      next response.json({ error: "Invalid credentials" }, status: 401)
    end

    token = Tina4::Auth.generate_token(
      { user_id: user.id, email: user.email, role: user.role },
      expires_in: 86400  # 24 hours
    )

    response.json({ token: token, user: { id: user.id, email: user.email } })
  rescue => e
    Tina4::Log.error("Login failed: #{e.message}")
    response.json({ error: "Login failed" }, status: 500)
  end
end
```

## API Key Bypass

Set `API_KEY` in `.env` to allow API key authentication as an alternative to JWT.

```
API_KEY="my-api-key-here"
```

Clients can then authenticate with:

```
Authorization: Bearer my-api-key-here
```

When an API key is used, `request.env["tina4.auth"]` is set to `{ "api_key" => true }`.

## Custom Auth Handler

```ruby
# Define a custom auth check
custom_auth = ->(env) {
  api_key = env["HTTP_X_API_KEY"]
  if api_key == ENV["CUSTOM_API_KEY"]
    env["tina4.auth"] = { api_key: true }
    true
  else
    false
  end
}

Tina4.get "/custom-secured", auth: custom_auth do |request, response|
  response.json({ authenticated: true })
end
```

## Bearer Token Extraction

The `request` object provides a convenience method for extracting the bearer token.

```ruby
Tina4.get "/check-token" do |request, response|
  token = request.bearer_token
  if token
    result = Tina4::Auth.validate_token(token)
    response.json(result)
  else
    response.json({ error: "No token provided" }, status: 401)
  end
end
```

## Key Management

RSA keys are stored in `.keys/` (auto-generated on first use).

```ruby
# Access the keys programmatically
Tina4::Auth.private_key  # => OpenSSL::PKey::RSA
Tina4::Auth.public_key   # => OpenSSL::PKey::RSA
```

Add `.keys/` to your `.gitignore` -- these should never be committed.
