# ORM

Tina4 Ruby provides an Active Record-style ORM with a DSL for field definitions, relationships, soft delete, field mapping, and full CRUD. Models inherit from `Tina4::ORM` and use the `FieldTypes` module.

The ORM connects to whatever database is set via `Tina4.database` (auto-configured from `DATABASE_URL` in `.env`).

## Defining a Model

```ruby
class User < Tina4::ORM
  # Override table name (default: "users")
  table_name "users"

  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name, length: 100, nullable: false
  string_field  :email, length: 255
  integer_field :age
  boolean_field :active, default: true
  datetime_field :created_at
end
```

## Field Types

All available field type DSL methods:

```ruby
class Product < Tina4::ORM
  integer_field   :id, primary_key: true, auto_increment: true
  string_field    :name, length: 255, nullable: false
  text_field      :description
  float_field     :weight
  decimal_field   :price, precision: 10, scale: 2
  boolean_field   :in_stock, default: true
  date_field      :release_date
  datetime_field  :created_at
  timestamp_field :updated_at
  blob_field      :image_data
  json_field      :metadata
end
```

## CRUD Operations

### Create

```ruby
user = User.new(name: "Alice", email: "alice@example.com", age: 30)
user.save
# => true

# Or use the class method
user = User.create(name: "Bob", email: "bob@example.com")
user.persisted?  # => true
user.id          # => auto-assigned ID
```

### Read

```ruby
# Find by primary key
user = User.find(1)

# Find by filter hash
users = User.find(active: true)

# Where clause with SQL conditions
admins = User.where("age > ? AND active = ?", [18, true])

# All records with pagination and sorting
page = User.all(limit: 10, offset: 20, order_by: "name ASC")

# Count
total = User.count
active_count = User.count("active = ?", [true])
```

### Update

```ruby
user = User.find(1)
user.name = "Alice Smith"
user.save
```

### Delete

```ruby
user = User.find(1)
user.delete
```

### Load by ID

```ruby
user = User.new
user.id = 42
user.load  # populates all fields from DB
```

## Serialization

```ruby
user = User.find(1)

user.to_h      # => { id: 1, name: "Alice", email: "alice@example.com", ... }
user.to_hash   # alias for to_h
user.to_json   # => '{"id":1,"name":"Alice",...}'
user.to_s      # => '#<User {id: 1, name: "Alice", ...}>'
```

## Relationships

```ruby
class User < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :name

  has_one  :profile, class_name: "Profile", foreign_key: "user_id"
  has_many :posts,   class_name: "Post",    foreign_key: "user_id"
end

class Profile < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  integer_field :user_id
  text_field    :bio

  belongs_to :user, class_name: "User", foreign_key: "user_id"
end

class Post < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  integer_field :user_id
  string_field  :title
  text_field    :body

  belongs_to :user, class_name: "User", foreign_key: "user_id"
end

# Usage
user = User.find(1)
user.profile       # => Profile instance (lazy loaded, cached)
user.posts          # => Array of Post instances

post = Post.find(5)
post.user           # => User instance
```

## Soft Delete

```ruby
class Article < Tina4::ORM
  self.soft_delete = true
  self.soft_delete_field = :is_deleted  # default

  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title
  integer_field :is_deleted, default: 0
end

article = Article.find(1)
article.delete
# Sets is_deleted = 1 instead of removing the row.
# Article.all and Article.find automatically exclude soft-deleted records.
```

## Field Mapping

Map Ruby attribute names to different database column names.

```ruby
class LegacyUser < Tina4::ORM
  table_name "tbl_users"

  self.field_mapping = {
    "first_name" => "fName",
    "last_name"  => "lName",
    "email_addr" => "emailAddress"
  }

  integer_field :id, primary_key: true, auto_increment: true
  string_field  :first_name
  string_field  :last_name
  string_field  :email_addr
end

# In Ruby you use: user.first_name
# In DB it reads/writes: fName column
```

## Per-Model Database

Bind a model to a different database connection.

```ruby
class AnalyticsEvent < Tina4::ORM
  self.db = Tina4::Database.new("analytics.db")

  integer_field :id, primary_key: true, auto_increment: true
  string_field  :event_name
  datetime_field :occurred_at
end
```

## Validation

Fields with `nullable: false` are validated automatically on save. Check `errors` after a failed save.

```ruby
class Order < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :customer_name, nullable: false
  decimal_field :total, nullable: false
end

order = Order.new
order.save  # => false
order.errors
# => ["customer_name cannot be null", "total cannot be null"]
```

## Select Specific Fields

```ruby
user = User.find(1)
result = user.select(:name, :email)
# => { name: "Alice", email: "alice@example.com" }
```

## Using ORM in Routes

```ruby
Tina4.get "/api/users" do |request, response|
  users = User.all(limit: 20)
  response.json({ data: users.map(&:to_h) })
end

Tina4.get "/api/users/{id:int}" do |request, response|
  user = User.find(request.params["id"])
  if user
    response.json({ data: user.to_h })
  else
    response.json({ error: "Not found" }, status: 404)
  end
end

Tina4.post "/api/users", auth: false do |request, response|
  user = User.create(request.body_parsed)
  if user.persisted?
    response.json({ data: user.to_h }, status: 201)
  else
    response.json({ errors: user.errors }, status: 422)
  end
end
```
