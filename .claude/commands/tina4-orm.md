# Create a Tina4 ORM Model

Create an ORM model with its corresponding migration. Always create both together.

## Instructions

1. Ask the user for the model name and fields (or infer from context)
2. Create the migration file in `migrations/`
3. Create the ORM model in `src/orm/`
4. Run the migration with `tina4 migrate`

## Step 1: Migration

Create `migrations/NNNNNN_create_<table>.sql`:
```sql
CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    price REAL DEFAULT 0,
    active INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

## Step 2: ORM Model

Create `src/orm/product.rb`:
```ruby
require "tina4/orm"

class Product < Tina4::ORM
  field :id, :integer, primary_key: true, auto_increment: true
  field :name, :string
  field :description, :text
  field :price, :numeric
  field :active, :integer, default: 1
  field :created_at, :datetime
end
```

## Step 3: Run Migration

```bash
tina4 migrate
```

## Field Types

| Ruby Field | SQLite | PostgreSQL | MySQL |
|-----------|--------|-----------|-------|
| `:integer` | INTEGER | INTEGER | INTEGER |
| `:string` | TEXT | VARCHAR(200) | VARCHAR(200) |
| `:text` | TEXT | TEXT | TEXT |
| `:numeric` | REAL | DOUBLE PRECISION | DOUBLE |
| `:datetime` | TEXT | TIMESTAMP | DATETIME |
| `:blob` | BLOB | BYTEA | BLOB |

## ORM Usage

```ruby
# Create
product = Product.new({ "name" => "Widget", "price" => 9.99 })
product.save

# Create from JSON string
product = Product.new('{"name": "Widget", "price": 9.99}')
product.save

# Load
product = Product.new
if product.load("id = ?", [1])
  puts product.name
end

# Query
results = Product.new.select(
  filter: "price > ?", params: [5.0],
  order_by: "name ASC", limit: 20, skip: 0
)
results.each do |row|
  puts row["name"]
end

# Update
product.name = "Super Widget"
product.save

# Delete
product.delete

# To hash/JSON
product.to_hash
product.to_json
```

## Key Rules

- One model per file, filename matches class name (snake_case)
- Always create a migration alongside the model
- Never use `ORM.create_table` in production -- use migrations
- Table name defaults to lowercase class name + "s" (Product -> products)
- Set custom table name: `self.table_name = "my_table"`
