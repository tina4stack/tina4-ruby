# Database

Tina4 Ruby provides a multi-driver database abstraction layer. It auto-detects the driver from the connection string and exposes a unified API for queries, inserts, updates, deletes, and transactions. Supported drivers: SQLite, PostgreSQL, MySQL, MSSQL, and Firebird.

The database connects automatically when `DATABASE_URL` is set in `.env`.

## Configuration

In your `.env` file:

```
# SQLite (default)
DATABASE_URL="app.db"

# PostgreSQL
DATABASE_URL="postgres://user:pass@localhost:5432/mydb"

# MySQL
DATABASE_URL="mysql2://user:pass@localhost:3306/mydb"

# MSSQL
DATABASE_URL="mssql://user:pass@localhost:1433/mydb"

# Firebird
DATABASE_URL="firebird://user:pass@localhost/path/to/db.fdb"
```

## Manual Connection

```ruby
require "tina4"

# Auto-detect driver from connection string
db = Tina4::Database.new("app.db")

# Explicit driver
db = Tina4::Database.new("mydb", driver_name: "postgres")

db.connected   # => true
db.driver_name # => "sqlite"
```

## Querying

```ruby
# Fetch all rows
results = db.fetch("SELECT * FROM users")
results.each { |row| puts row[:name] }

# Fetch with parameters (parameterized queries)
results = db.fetch("SELECT * FROM users WHERE age > ?", [18])

# Fetch with pagination
page = db.fetch("SELECT * FROM users", [], limit: 10, skip: 20)

# Fetch single row
user = db.fetch_one("SELECT * FROM users WHERE id = ?", [1])
# => { id: 1, name: "Alice", ... } or nil
```

## Insert / Update / Delete

```ruby
# Insert
result = db.insert("users", { name: "Alice", email: "alice@example.com", age: 30 })
result[:success]  # => true
result[:last_id]  # => auto-generated ID

# Update
db.update("users", { name: "Alice Smith" }, { id: 1 })

# Delete
db.delete("users", { id: 1 })
```

## Raw SQL Execution

```ruby
db.execute("CREATE INDEX idx_users_email ON users (email)")
db.execute("INSERT INTO logs (message) VALUES (?)", ["Something happened"])
```

## Transactions

```ruby
db.transaction do |tx|
  tx.insert("accounts", { name: "Alice", balance: 1000 })
  tx.insert("accounts", { name: "Bob", balance: 500 })
  # Commits on success, rolls back on exception
end

# Exception triggers automatic rollback
begin
  db.transaction do |tx|
    tx.update("accounts", { balance: 900 }, { name: "Alice" })
    tx.update("accounts", { balance: 600 }, { name: "Bob" })
    raise "Simulated failure"
  end
rescue => e
  puts "Rolled back: #{e.message}"
end
```

## Schema Introspection

```ruby
db.tables
# => ["users", "products", "orders"]

db.columns("users")
# => [{ name: "id", type: "INTEGER" }, { name: "name", type: "VARCHAR" }, ...]

db.table_exists?("users")
# => true
```

## Using with Tina4 Global

The framework sets `Tina4.database` automatically from `.env`. Access it anywhere:

```ruby
Tina4.get "/stats" do |request, response|
  db = Tina4.database
  result = db.fetch_one("SELECT COUNT(*) as total FROM users")
  response.json({ total_users: result[:total] })
end
```

## DatabaseResult

All `fetch` calls return a `Tina4::DatabaseResult`, which behaves like an Array of Hashes with symbol keys.

```ruby
results = db.fetch("SELECT id, name FROM users LIMIT 5")
results.length     # number of rows
results.first      # => { id: 1, name: "Alice" }
results.map { |r| r[:name] }
```

## Close Connection

```ruby
db.close
db.connected  # => false
```
