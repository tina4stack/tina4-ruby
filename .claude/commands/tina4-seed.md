# Generate Fake Data with Tina4 Seeder

Create seeders to populate tables with realistic fake data for development and testing.

## Instructions

1. Create a seeder file in `src/seeds/`
2. Use `FakeData` for realistic values
3. Run with `tina4 seed`

## Seeder File (`src/seeds/seed_products.rb`)

```ruby
require "tina4/seeder"

class ProductSeeder < Tina4::Seeder
  def run
    fake = Tina4::FakeData.new(seed: 42)  # Reproducible data

    50.times do
      db.insert("products", {
        "name" => fake.sentence(words: 3),
        "price" => fake.numeric(min_val: 1.0, max_val: 999.99, decimals: 2),
        "category" => fake.choice(["Electronics", "Books", "Clothing", "Food"]),
        "active" => fake.choice([0, 1])
      })
    end
  end
end
```

## ORM-Based Seeding (Simpler)

```ruby
require "tina4/seeder"
require_relative "../orm/product"

# Auto-generates 50 products using field types
count = Tina4::Seeder.seed_orm(Product, count: 50, overrides: {
  "category" => ->(fake) { fake.choice(["A", "B", "C"]) },
  "active" => 1
})
```

## Table-Based Seeding

```ruby
require "tina4/seeder"

count = Tina4::Seeder.seed_table(db, "products", count: 50, field_map: {
  "name" => "sentence",
  "price" => "numeric",
  "category" => "word"
}, overrides: {
  "active" => 1
})
```

## FakeData Reference

```ruby
require "tina4/seeder"

fake = Tina4::FakeData.new(seed: 42)

# Text
fake.name                            # "Alice Johnson"
fake.email                           # "alice.johnson@example.com"
fake.phone                           # "+1-555-0142"
fake.word                            # "quantum"
fake.sentence(words: 6)              # "The quick brown fox jumps over"
fake.paragraph(sentences: 3)         # Multi-sentence text

# Numbers
fake.integer(min_val: 0, max_val: 100) # 42
fake.numeric(min_val: 0, max_val: 1000, decimals: 2) # 123.45

# Dates
fake.datetime                        # DateTime object
fake.date                            # Date object

# Utility
fake.choice(["a", "b", "c"])         # Random pick from array
fake.boolean                         # true/false
fake.uuid                            # UUID string

# Auto-detect from ORM field
fake.for_field(:string, "email")     # Generates appropriate data based on column name
```

## Running Seeders

```bash
tina4 seed                 # Run all seeders in src/seeds/
```

## Key Rules

- Use `seed: N` for reproducible test data
- Seeder files are auto-discovered from `src/seeds/`
- Use `seed_orm` when you have an ORM model -- it auto-detects field types
- Use `seed_table` for tables without ORM models
- Use overrides for specific values (foreign keys, statuses, etc.)
