# Data, ORM & Database (Ruby)

## Defining Models

Drop a model file in `src/orm/` and it's auto-registered. A model is a class that inherits
`Tina4::ORM` and **declares its columns with field-type class methods**.

```ruby
# src/orm/user.rb
class User < Tina4::ORM
  table_name "users"                                   # method call — NOT self.table_name =

  integer_field :id, primary_key: true, auto_increment: true   # primary key via a field option
  string_field  :name
  string_field  :email
  text_field    :bio
  boolean_field :is_active, default: true
  integer_field :age, nullable: true
end
```

**Three things that are commonly gotten wrong — get them right:**

1. **`table_name "users"` is a class-method call, not an assignment.** `self.table_name = "users"`
   does not work. Calling `table_name` with no argument returns the current name (defaults to the
   lowercased class name). Set `TINA4_ORM_PLURAL_TABLE_NAMES=true` to auto-append `s`.

2. **The primary key is declared with `primary_key: true` on a field — there is no
   `self.primary_key = "id"`.** Write `integer_field :id, primary_key: true, auto_increment: true`.
   The framework reads the primary key from the field that carries `primary_key: true`.

3. **`attr_accessor :id, :name` registers NO database fields.** A bare `attr_accessor` gives you a
   getter/setter but the ORM's `field_definitions` stays empty, so `save`, `validate`, `to_h`,
   `create_table`, and querying all see zero columns. **Always use the field-type declarations**
   (`integer_field`, `string_field`, `boolean_field`, …) — they register the column AND define the
   accessor for you.

### Available field types

`integer_field`, `string_field` (`length:` default 255), `text_field`, `float_field`,
`decimal_field` (`precision:`, `scale:`), `numeric_field`, `boolean_field`, `date_field`,
`datetime_field`, `timestamp_field`, `blob_field`, `json_field`, and `foreign_key_field`
(`references:`, `related_name:`). Common options: `primary_key:`, `auto_increment:`, `nullable:`,
`default:` (a Proc default like `default: -> { Time.now }` is evaluated per row).

## CRUD Operations

> **Query methods are CLASS methods — call them on the class, never on an instance.**
> `User.find_by_id(1)`, `User.all`, `User.find(...)`, `User.where(...)`, `User.create(...)`.
> `User.new.find_by_id(1)` is wrong — `find_by_id` is not an instance method.

### Create

```ruby
# Build then save (save returns self on success, false on failure)
user = User.new(name: "Alice", email: "alice@example.com")
user.save

# Or the static factory (returns the saved instance, or false on failure)
user = User.create({ name: "Alice", email: "alice@example.com" })

# From a request body (a Hash with String keys) — both work
user = User.create(request.body)
```

On failure, `save` returns `false` (never raises) and records the cause: recover it with
`user.get_error` / `user.last_error` and inspect `user.errors`.

### Read — by primary key

```ruby
user = User.find_by_id(1)      # returns an instance or nil
user = User.find(1)            # find(id) also does a primary-key lookup
user = User.find_or_fail(1)    # raises if not found
```

### Read — filtered

```ruby
# find(filter_hash) or keyword args — equality match on each key
users = User.find(is_active: true)
users = User.find({ "email" => "alice@example.com" })

# where(sql_condition, params) — returns an Array of model instances
active = User.where("is_active = ?", [1])

# A single record: where(...).first   ← the idiomatic "find one by condition"
user  = User.where("email = ?", ["alice@example.com"]).first

# all(...) — every record, with optional pagination / ordering
everyone = User.all(limit: 50, offset: 0, order_by: "name ASC")

# select(full_sql, params) — run a full SELECT, get model instances back
recent = User.select("SELECT * FROM users WHERE created_at > ?", ["2026-01-01"])
```

> **`find_one` DOES NOT EXIST.** The single-row method is **`select_one`**, and it takes a **FULL SQL
> statement** (not just a WHERE fragment): `User.select_one("SELECT * FROM users WHERE email = ?",
> ["a@b.c"])`. In practice, **prefer `User.where("email = ?", [...]).first`** — it's shorter and you
> don't hand-write the SELECT. Never call `User.select_one("email = ?", ...)` with a bare condition;
> that is not valid SQL.

### Update

```ruby
user = User.find_by_id(1)
user.name = "Alice Smith"
user.save
```

### Delete

```ruby
user = User.find_by_id(1)
user.delete          # hard delete (or soft delete if soft_delete is enabled)
```

`delete` raises if the instance has no primary-key value (deleting a keyless record is a programmer
error, not a quiet no-op).

### Existence

```ruby
User.exists(1)                                  # true if a row with PK 1 exists (class method, takes a PK)
User.where("email = ?", [email]).any?           # any matching row? (Array#any?)
```

## Serialisation

```ruby
user.to_h        # { id: 1, name: "Alice", ... }  (aliases: to_hash, to_dict, to_object)
user.to_h(case: "camel")   # { id: 1, firstName: "Alice", ... }
user.to_json     # '{"id":1,"name":"Alice",...}'
user.to_array    # [1, "Alice", ...]

# Serialise a collection for a JSON response:
User.all.map(&:to_h)
# ...or just hand the Array of models to response.json — it converts each one:
response.json(User.all)
```

## Relationships

Declare relationships as class methods; access them as instance methods. `foreign_key_field`
auto-wires both sides.

```ruby
class Post < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title
  foreign_key_field :user_id, references: "User"   # wires post.user + user.posts
end

class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
  has_many :posts, class_name: "Post", foreign_key: "user_id"   # explicit form (optional here)
end

user   = User.find_by_id(1)
posts  = user.posts        # Array of this user's posts
post   = Post.find_by_id(1)
author = post.user         # the post's author (belongs_to)
```

`has_one`, `has_many`, and `belongs_to` are all available. Prevent N+1 with eager loading:
`User.all(include: ["posts"])` or `User.find(1, include: ["posts"])`.

## Soft Delete

```ruby
class Article < Tina4::ORM
  self.soft_delete = true        # uses the is_deleted column (INTEGER 0/1)
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title
end

article = Article.find_by_id(1)
article.delete          # sets is_deleted = 1 (soft)
article.restore         # sets is_deleted = 0
article.force_delete    # actually removes the row

Article.all                                   # excludes soft-deleted by default
Article.with_trashed("1=1", [], limit: 100)   # includes soft-deleted
```

## Pagination

`all`, `where`, and `select` accept `limit:` and `offset:`:

```ruby
users = User.all(limit: 20, offset: 40)   # page 3 at 20/page
```

## QueryBuilder — Fluent Queries with JOINs

Use `Tina4::QueryBuilder` for complex queries (JOINs, aggregates, GROUP BY) instead of raw SQL.
Prefer it over `db.fetch` for maintainability. Start with `from_table(table, db:)` (the `from`
method does not exist — it was renamed to `from_table` to avoid the Ruby keyword clash).

```ruby
# Simple query
users = Tina4::QueryBuilder.from_table("users", db: db)
  .select("id", "name", "email")
  .where("is_active = ?", [1])
  .order_by("name ASC")
  .limit(10)
  .get                       # => Tina4::DatabaseResult

# JOINs
orders = Tina4::QueryBuilder.from_table("orders o", db: db)
  .select("o.*", "c.name AS customer_name")
  .join("customers c", "o.customer_id = c.id")
  .where("o.status = ?", ["pending"])
  .order_by("o.created_at DESC")
  .limit(20)
  .get

# LEFT JOIN
products = Tina4::QueryBuilder.from_table("products p", db: db)
  .select("p.*", "cat.name AS category_name")
  .left_join("categories cat", "p.category_id = cat.id")
  .where("p.is_active = ?", [1])
  .get

# Aggregate → single row
total = Tina4::QueryBuilder.from_table("orders", db: db)
  .select("COALESCE(SUM(total), 0) AS total")
  .where("status != ?", ["cancelled"])
  .first["total"]            # first → a single row Hash, or nil

# COUNT
count = Tina4::QueryBuilder.from_table("users", db: db)
  .where("is_active = ?", [1])
  .count                     # => Integer

# GROUP BY + HAVING
stats = Tina4::QueryBuilder.from_table("orders o", db: db)
  .select("c.name", "COUNT(*) AS order_count")
  .join("customers c", "o.customer_id = c.id")
  .group_by("c.name")
  .having("COUNT(*) > ?", [5])
  .get

# From an ORM model (inherits the model's DB connection)
adults = User.query.where("age > ?", [18]).order_by("name").get

# Existence — the method is exists? (with a question mark), returning a Boolean
any = Tina4::QueryBuilder.from_table("users", db: db)
  .where("email = ?", ["alice@example.com"])
  .exists?
```

### QueryBuilder Methods

| Method | Description |
|--------|-------------|
| `from_table(table, db:)` | Start a query |
| `select(*cols)` | Set columns to select |
| `where(cond, params)` | AND condition |
| `or_where(cond, params)` | OR condition |
| `join(table, on)` | INNER JOIN |
| `left_join(table, on)` | LEFT JOIN |
| `group_by(col)` | GROUP BY |
| `having(expr, params)` | HAVING clause |
| `order_by(expr)` | ORDER BY |
| `limit(n, offset = nil)` | LIMIT + optional OFFSET |
| `get` | Execute → `DatabaseResult` |
| `first` | Execute → single row Hash or nil |
| `count` | Execute → Integer |
| `exists?` | Execute → Boolean |
| `to_sql` | Build SQL string without executing |
| `to_mongo` | Convert to a MongoDB query document |

## DatabaseResult

`db.fetch(...)` and `QueryBuilder#get` return a `Tina4::DatabaseResult`, which is `Enumerable`:

```ruby
results = db.fetch("SELECT * FROM users")
results.size        # record count
results.first       # first row Hash
results.to_array    # [ {..}, {..} ]  (alias: to_a via Enumerable)
results.to_json     # JSON string
results.to_csv      # CSV string
results.map { |row| row["name"] }
```

> ORM query methods (`User.all`, `User.where`, `User.select`) return a **plain Ruby Array of model
> instances**, not a `DatabaseResult`. Serialise with `User.all.map(&:to_h)` (or hand the Array to
> `response.json`, which converts each model). `to_array` / `to_json` / `to_csv` are `DatabaseResult`
> methods, available on the result of `db.fetch` and `QueryBuilder#get`.

## Raw SQL

For queries that ORM or QueryBuilder can't express, use the database directly. Always parameterize:

```ruby
db = Tina4::Database.new("sqlite:data/app.db")
results = db.fetch("SELECT * FROM users WHERE id = ?", [1])   # DatabaseResult
one     = db.fetch_one("SELECT * FROM users WHERE id = ?", [1]) # single row Hash or nil
db.execute("UPDATE users SET is_active = ? WHERE id = ?", [0, 1])
```

## Database Connection

Set `TINA4_DATABASE_URL` in `.env`, then bind a connection in `app.rb`:

```ruby
db = Tina4::Database.new(ENV["TINA4_DATABASE_URL"])   # e.g. "sqlite:data/app.db"
Tina4.bind_database(db)

# Or from the env directly:
db = Tina4::Database.from_env    # reads TINA4_DATABASE_URL
```

Connection string formats (same across every Tina4 language):
```
sqlite:data/app.db
postgresql://user:password@localhost:5432/mydb
mysql://user:password@localhost:3306/mydb
mssql://user:password@localhost:1433/mydb
firebird://user:password@localhost:3050/mydb
```

## Migrations

```bash
tina4 migrate           # run pending migrations
tina4 migrate:status    # show migration status
tina4 migrate:rollback  # roll back the last batch
```

Migration files are versioned SQL in `migrations/`. Write standard SQL:
```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

Alternatively, a model can create its own table from its field definitions with `User.create_table`
(engine-aware DDL; returns `false` if the DDL fails).

## Seeding

```bash
tina4 seed:create "initial users"   # create a seed file
tina4 seed                          # run all seeds in seeds/
```

Quick fake data:
```ruby
fake = Tina4::FakeData.new
fake.name     # "Alice Johnson"
fake.email    # "alice.johnson@example.com"

Tina4.seed_orm(User, count: 50)    # bulk-seed a model from its field types
```

## Auto-CRUD

Set `self.auto_crud = true` on a model — Tina4 auto-registers a full list/create/read/update/delete
route set for it, no handler to write:

```ruby
class User < Tina4::ORM
  self.auto_crud = true
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name
  string_field  :email
end
```
