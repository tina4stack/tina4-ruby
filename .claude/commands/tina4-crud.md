# Generate Tina4 CRUD

Create a complete CRUD implementation: migration, ORM model, API routes, template page, and tests.

## Instructions

1. Ask the user for the resource name and fields
2. Create ALL of the following:
   - Migration file
   - ORM model
   - REST API routes (list, get, create, update, delete)
   - Template page with listing
   - Tests

## Example: Products CRUD

### 1. Migration (`migrations/NNNNNN_create_products.sql`)

```sql
CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    price REAL DEFAULT 0,
    category TEXT,
    active INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

### 2. ORM Model (`src/orm/product.rb`)

```ruby
require "tina4/orm"

class Product < Tina4::ORM
  field :id, :integer, primary_key: true, auto_increment: true
  field :name, :string
  field :price, :numeric
  field :category, :string
  field :active, :integer, default: 1
  field :created_at, :datetime
end
```

### 3. API Routes (`src/routes/products.rb`)

```ruby
require "tina4/router"

Tina4::Router.get "/api/products",
  description: "List products with pagination",
  tags: ["products"] do |request, response|
  require_relative "../orm/product"
  page = request.params.fetch("page", "1").to_i
  limit = request.params.fetch("limit", "20").to_i
  skip = (page - 1) * limit
  search = request.params.fetch("search", "")

  if search != ""
    results = Product.new.select(
      filter: "name LIKE ?", params: ["%#{search}%"],
      limit: limit, skip: skip
    )
  else
    results = Product.new.select(limit: limit, skip: skip)
  end

  response.json(results.to_paginate(page: page, per_page: limit))
end

Tina4::Router.get "/api/products/:id",
  description: "Get a product",
  tags: ["products"] do |id, request, response|
  require_relative "../orm/product"
  product = Product.new
  if product.load("id = ?", [id.to_i])
    response.json(product.to_hash)
  else
    response.json({ "error" => "Not found" }, 404)
  end
end

Tina4::Router.post "/api/products",
  description: "Create a product",
  tags: ["products"] do |request, response|
  require_relative "../orm/product"
  product = Product.new(request.body)
  product.save
  response.json(product.to_hash, 201)
end

Tina4::Router.put "/api/products/:id",
  description: "Update a product",
  tags: ["products"] do |id, request, response|
  require_relative "../orm/product"
  product = Product.new
  unless product.load("id = ?", [id.to_i])
    return response.json({ "error" => "Not found" }, 404)
  end
  request.body.each do |key, value|
    product.send("#{key}=", value) if product.respond_to?("#{key}=") && key != "id"
  end
  product.save
  response.json(product.to_hash)
end

Tina4::Router.delete "/api/products/:id",
  description: "Delete a product",
  tags: ["products"] do |id, request, response|
  require_relative "../orm/product"
  product = Product.new
  unless product.load("id = ?", [id.to_i])
    return response.json({ "error" => "Not found" }, 404)
  end
  product.delete
  response.json({ "deleted" => true })
end
```

### 4. Template (`src/templates/pages/products.twig`)

```twig
{% extends "base.twig" %}
{% block title %}Products{% endblock %}
{% block content %}
<div class="container mt-4">
    <h1>{{ title }}</h1>
    <table class="table">
        <thead>
            <tr>
                <th>Name</th>
                <th>Price</th>
                <th>Category</th>
            </tr>
        </thead>
        <tbody>
        {% for product in products %}
            <tr>
                <td>{{ product.name }}</td>
                <td>{{ product.price }}</td>
                <td>{{ product.category }}</td>
            </tr>
        {% endfor %}
        </tbody>
    </table>
</div>
{% endblock %}
```

### 5. Tests (`tests/test_products.rb`)

```ruby
require "minitest/autorun"
require_relative "../src/orm/product"

class TestProduct < Minitest::Test
  def test_create
    p = Product.new({ "name" => "Widget", "price" => 9.99, "category" => "Tools" })
    assert_equal "Widget", p.name
    assert_equal 9.99, p.price
  end

  def test_to_hash
    p = Product.new({ "name" => "Widget", "price" => 9.99 })
    d = p.to_hash
    assert_equal "Widget", d["name"]
  end

  def test_from_json
    p = Product.new('{"name": "Gadget", "price": 19.99}')
    assert_equal "Gadget", p.name
  end
end
```

### 6. Run

```bash
tina4 migrate
tina4 test
```

## After Generation

- Run `tina4 migrate` to create the table
- Run `tina4 test` to verify tests pass
- Visit `/swagger` to see the API documentation
- Use `tina4 routes` to list all registered routes
