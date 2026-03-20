# AutoCRUD

Tina4 Ruby can auto-generate full REST API endpoints from ORM models. Register a model and get GET (list + single), POST, PUT, DELETE routes with pagination, filtering, and sorting -- zero boilerplate.

## Quick Start

```ruby
require "tina4"

class Product < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name, nullable: false
  decimal_field :price, precision: 10, scale: 2
  string_field  :category
  boolean_field :in_stock, default: true
end

# Register for auto-CRUD
Tina4::AutoCrud.register(Product)

# Generate all routes
Tina4::AutoCrud.generate_routes(prefix: "/api")
```

This creates:

| Method | Path | Description |
|---|---|---|
| GET | `/api/products` | List with pagination, filtering, sorting |
| GET | `/api/products/{id}` | Get single record |
| POST | `/api/products` | Create record |
| PUT | `/api/products/{id}` | Update record |
| DELETE | `/api/products/{id}` | Delete record |

## List Endpoint

```
GET /api/products?limit=10&offset=0&sort=-price&filter[category]=electronics
```

Response:

```json
{
  "data": [
    { "id": 1, "name": "Laptop", "price": 999.99, "category": "electronics", "in_stock": true }
  ],
  "total": 42,
  "limit": 10,
  "offset": 0
}
```

### Sorting

Use the `sort` parameter. Prefix with `-` for descending.

```
GET /api/products?sort=name         # name ASC
GET /api/products?sort=-price       # price DESC
GET /api/products?sort=-price,name  # price DESC, name ASC
```

### Filtering

Use `filter[field]=value` parameters.

```
GET /api/products?filter[category]=electronics&filter[in_stock]=true
```

## Single Record

```
GET /api/products/1
```

Response:

```json
{
  "data": { "id": 1, "name": "Laptop", "price": 999.99, "category": "electronics" }
}
```

Returns `404` if not found:

```json
{ "error": "Not found" }
```

## Create

```
POST /api/products
Content-Type: application/json

{ "name": "Keyboard", "price": 79.99, "category": "accessories" }
```

Response (201):

```json
{
  "data": { "id": 5, "name": "Keyboard", "price": 79.99, "category": "accessories", "in_stock": true }
}
```

Returns `422` on validation errors:

```json
{ "errors": ["name cannot be null"] }
```

## Update

```
PUT /api/products/5
Content-Type: application/json

{ "price": 69.99, "in_stock": false }
```

Response:

```json
{
  "data": { "id": 5, "name": "Keyboard", "price": 69.99, "category": "accessories", "in_stock": false }
}
```

## Delete

```
DELETE /api/products/5
```

Response:

```json
{ "message": "Deleted" }
```

## Multiple Models

```ruby
Tina4::AutoCrud.register(User)
Tina4::AutoCrud.register(Product)
Tina4::AutoCrud.register(Order)
Tina4::AutoCrud.generate_routes(prefix: "/api")

# Creates:
#   /api/users, /api/users/{id}
#   /api/products, /api/products/{id}
#   /api/orders, /api/orders/{id}
```

## Custom Prefix

```ruby
Tina4::AutoCrud.generate_routes(prefix: "/api/v2")
# Routes: /api/v2/products, /api/v2/products/{id}, etc.
```

## Clearing Registrations

```ruby
Tina4::AutoCrud.clear!
```
