# Seeder / FakeData

Tina4 Ruby includes a zero-dependency fake data generator and a seeder system for populating databases. FakeData produces names, emails, addresses, companies, and more with optional deterministic seeding. The seeder integrates with ORM models and supports seed files.

## FakeData Generator

```ruby
fake = Tina4::FakeData.new

fake.name           # => "Sarah Johnson"
fake.first_name     # => "Michael"
fake.last_name      # => "Garcia"
fake.email          # => "sarah.johnson123@example.com"
fake.email(from_name: "Alice Smith")  # => "alice.smith42@test.org"
fake.phone          # => "+1 (415) 555-1234"

fake.sentence(words: 6)     # => "The good some make like time."
fake.paragraph(sentences: 3)
fake.text(max_length: 200)
fake.word            # => "system"
fake.slug(words: 3)  # => "data-report-system"
fake.url             # => "https://example.com/data-report-system"

fake.integer(min: 1, max: 100)     # => 42
fake.numeric(min: 0.0, max: 99.99, decimals: 2)  # => 47.83
fake.boolean         # => 0 or 1
fake.datetime        # => Time object between 2020-2026
fake.date            # => "2023-07-15"
fake.timestamp       # => "2024-01-03 14:22:08"

fake.city            # => "Tokyo"
fake.country         # => "Germany"
fake.address         # => "4521 Oak Boulevard"
fake.zip_code        # => "90210"
fake.company         # => "TechGlobal Solutions"

fake.color_hex       # => "#3a7f2c"
fake.uuid            # => "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
fake.password(length: 16)   # => "aB3cD4eF5gH6iJ7k"
fake.blob(size: 64)         # => binary data
fake.json_data               # => { "network" => "look", ... }
fake.choice(%w[a b c])      # => "b"
```

## Deterministic Seeding

Pass a seed for reproducible output -- same seed always generates the same data.

```ruby
fake1 = Tina4::FakeData.new(seed: 42)
fake2 = Tina4::FakeData.new(seed: 42)

fake1.name == fake2.name  # => true (always)
```

## Seeding ORM Models

Auto-populate a database table from an ORM class. FakeData uses column names to generate contextually appropriate data (e.g., "email" columns get email addresses).

```ruby
class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
  string_field  :email
  integer_field :age
  string_field  :city
  boolean_field :active
end

# Seed 50 users
Tina4.seed_orm(User, count: 50)

# Seed with overrides (static value or lambda)
Tina4.seed_orm(User, count: 100, overrides: {
  active: true,
  city: ->(fake) { fake.choice(["New York", "London", "Tokyo"]) }
})

# Clear existing data before seeding
Tina4.seed_orm(User, count: 50, clear: true)

# Reproducible seeding
Tina4.seed_orm(User, count: 50, seed: 42)
```

## Smart Column Detection

FakeData automatically generates appropriate data based on column names:

| Column Name Pattern | Generated Data |
|---|---|
| `email` | `fake.email` |
| `name`, `full_name` | `fake.name` |
| `first_name` | `fake.first_name` |
| `phone`, `mobile` | `fake.phone` |
| `city`, `town` | `fake.city` |
| `country` | `fake.country` |
| `address`, `street` | `fake.address` |
| `url`, `website` | `fake.url` |
| `company`, `org` | `fake.company` |
| `title`, `subject` | Short sentence |
| `description`, `bio` | Paragraph text |
| `status` | Choice of common statuses |
| `price`, `cost`, `total` | Numeric with 2 decimals |
| `age` | Integer 18-85 |
| `username`, `login` | Generated username |
| `password`, `token` | Random string |
| `lat` | Float -90 to 90 |
| `lon`, `lng` | Float -180 to 180 |

## Seeding Raw Tables

Seed a table without an ORM class:

```ruby
Tina4.seed_table("audit_log", {
  action: :string,
  user_id: :integer,
  details: :text,
  created_at: :datetime
}, count: 100)
```

## Batch Seeding (Multiple Models)

```ruby
results = Tina4.seed_batch([
  { orm_class: User, count: 20 },
  { orm_class: Product, count: 50 },
  { orm_class: Order, count: 200, overrides: {
    status: ->(f) { f.choice(%w[pending shipped delivered]) }
  }}
], clear: true)
# => { "User" => 20, "Product" => 50, "Order" => 200 }
```

## Seed Files

Create seed files in the `seeds/` directory. They run in alphabetical order.

```bash
tina4ruby seed:create users
# Creates seeds/001_users.rb
```

Example `seeds/001_users.rb`:

```ruby
Tina4.seed_orm(User, count: 50)
```

Example `seeds/002_products.rb`:

```ruby
Tina4.seed_orm(Product, count: 100, overrides: {
  price: ->(f) { f.numeric(min: 1.99, max: 299.99, decimals: 2) }
})
```

Run all seed files:

```bash
tina4ruby seed
tina4ruby seed --clear   # clear tables first
```

## Idempotency

`seed_orm` checks if the table already has enough records and skips seeding if so (unless `clear: true`).
