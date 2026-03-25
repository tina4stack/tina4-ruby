# Create a Tina4 API Integration

Set up an external API client using the built-in Api class. Never use raw `net/http` or `open-uri`.

## Instructions

1. Create a service module in `src/app/` for the API client
2. Create route handlers that use the service
3. Use queues for slow API calls

## Service (`src/app/payment_service.rb`)

```ruby
require "tina4/api"

class PaymentService
  def initialize
    @api = Tina4::Api.new(base_url: "https://api.stripe.com/v1")
    @api.set_bearer_token("sk_live_xxx")
  end

  def charge(amount:, currency: "usd")
    result = @api.post("/charges", { amount: amount, currency: currency })
    if result["error"]
      { "success" => false, "error" => result["error"] }
    else
      { "success" => true, "charge" => result["body"] }
    end
  end

  def get_customer(customer_id)
    @api.get("/customers/#{customer_id}")
  end
end

PAYMENT = PaymentService.new  # Module-level singleton
```

## Route (`src/routes/payments.rb`)

```ruby
require "tina4/router"
require_relative "../app/payment_service"

Tina4::Router.post "/api/charge",
  description: "Create a payment charge",
  tags: ["payments"] do |request, response|
  result = PAYMENT.charge(
    amount: request.body["amount"],
    currency: request.body.fetch("currency", "usd")
  )
  if !result["success"]
    response.json({ "error" => result["error"] }, 502)
  else
    response.json(result)
  end
end
```

## Api Class Reference

```ruby
require "tina4/api"

api = Tina4::Api.new(base_url: "https://api.example.com")

# Auth options
api.set_bearer_token("token123")
api.set_basic_auth("username", "password")
api.add_headers({ "X-API-Key" => "key123" })

# HTTP methods -- all return {"http_code", "body", "headers", "error"}
result = api.get("/users")
result = api.post("/users", { "name" => "Alice" })
result = api.put("/users/1", { "name" => "Bob" })
result = api.patch("/users/1", { "name" => "Bob" })
result = api.delete("/users/1")

# Response is auto-parsed: JSON -> Hash, otherwise raw String
if result["error"].nil?
  data = result["body"]       # Hash if JSON, String if text
  status = result["http_code"]
end
```

## Key Rules

- Always create a service class in `src/app/` -- don't put API logic in routes
- Use module-level constants for API client singletons
- For slow APIs (>1s), push to a Queue and process asynchronously
- The Api class auto-handles: JSON parsing, error wrapping, auth headers, SSL
