# Migrations

Tina4 Ruby provides database schema migrations with both Ruby and SQL file support. Migrations are tracked in a `tina4_migration` table, support batched execution, and can be rolled back.

## Creating a Migration

```bash
tina4ruby migrate --create create_users
# Creates: src/migrations/20260320120000_create_users.rb
```

Generated file:

```ruby
# frozen_string_literal: true
# Migration: create_users

class CreateUsers < Tina4::MigrationBase
  def up(db)
    db.execute(<<~SQL)
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(255) NOT NULL UNIQUE,
        age INTEGER,
        active BOOLEAN DEFAULT 1,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    SQL
  end

  def down(db)
    db.execute("DROP TABLE IF EXISTS users")
  end
end
```

## Running Migrations

```bash
# Run all pending migrations
tina4ruby migrate
```

Output:

```
  [OK] 20260320120000_create_users.rb
  [OK] 20260320120100_create_products.rb
```

## Rollback

```bash
# Roll back the last batch
tina4ruby migrate --rollback 1

# Roll back the last 3 batches
tina4ruby migrate --rollback 3
```

## SQL Migrations

Place `.sql` files in `src/migrations/`. For rollback, create a matching `.down.sql` file.

**src/migrations/20260320130000_add_index.sql:**
```sql
CREATE INDEX idx_users_email ON users (email);
```

**src/migrations/20260320130000_add_index.down.sql:**
```sql
DROP INDEX IF EXISTS idx_users_email;
```

## Programmatic Usage

```ruby
db = Tina4.database
migration = Tina4::Migration.new(db)

# Run all pending
results = migration.run
results.each do |r|
  puts "#{r[:name]}: #{r[:status]}"
end

# Rollback
migration.rollback(1)

# Check status
status = migration.status
puts "Completed: #{status[:completed]}"
puts "Pending: #{status[:pending]}"

# Create a new migration file
path = migration.create("add_orders_table")
```

## Migration Examples

### Add a Column

```ruby
class AddPhoneToUsers < Tina4::MigrationBase
  def up(db)
    db.execute("ALTER TABLE users ADD COLUMN phone VARCHAR(20)")
  end

  def down(db)
    db.execute("ALTER TABLE users DROP COLUMN phone")
  end
end
```

### Create a Join Table

```ruby
class CreateUserRoles < Tina4::MigrationBase
  def up(db)
    db.execute(<<~SQL)
      CREATE TABLE user_roles (
        user_id INTEGER NOT NULL,
        role_id INTEGER NOT NULL,
        PRIMARY KEY (user_id, role_id),
        FOREIGN KEY (user_id) REFERENCES users(id),
        FOREIGN KEY (role_id) REFERENCES roles(id)
      )
    SQL
  end

  def down(db)
    db.execute("DROP TABLE IF EXISTS user_roles")
  end
end
```

### Seed Data in Migration

```ruby
class SeedDefaultRoles < Tina4::MigrationBase
  def up(db)
    db.insert("roles", { name: "admin", description: "Administrator" })
    db.insert("roles", { name: "editor", description: "Content editor" })
    db.insert("roles", { name: "viewer", description: "Read-only access" })
  end

  def down(db)
    db.execute("DELETE FROM roles WHERE name IN ('admin', 'editor', 'viewer')")
  end
end
```

## Migration Directory

Migrations are stored in `src/migrations/` by default. Override with:

```ruby
migration = Tina4::Migration.new(db, migrations_dir: "db/migrations")
```

## Tracking Table

Tina4 creates a `tina4_migration` table automatically to track which migrations have been applied:

| Column | Type | Description |
|---|---|---|
| `id` | INTEGER | Auto-incrementing primary key |
| `migration_name` | VARCHAR(255) | Filename of the migration |
| `batch` | INTEGER | Batch number (for grouped rollback) |
| `executed_at` | TIMESTAMP | When the migration ran |
