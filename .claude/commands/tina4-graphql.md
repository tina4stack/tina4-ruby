# Set Up Tina4 GraphQL Endpoint

Create a GraphQL API endpoint with schema, resolvers, and route integration.

## Instructions

1. Define your schema with types, queries, and mutations
2. Register resolvers
3. Create a route that handles GraphQL requests

## Schema & Resolvers (`src/app/graphql_schema.rb`)

```ruby
require "tina4/graphql"

schema = Tina4::Schema.new

# Define types
schema.add_type("User", {
  "id" => "ID!",
  "name" => "String!",
  "email" => "String!",
  "role" => "String"
})

# Define queries
schema.add_query("user", "User", { "id" => "ID!" })
schema.add_query("users", "[User]", { "limit" => "Int", "offset" => "Int" })

# Define mutations
schema.add_mutation("createUser", "User", { "name" => "String!", "email" => "String!" })

# Create engine and register resolvers
GQL = Tina4::GraphQL.new(schema)

GQL.resolver("user") do |args, context|
  require_relative "../orm/user"
  user = User.new
  if user.load("id = ?", [args["id"]])
    user.to_hash
  else
    nil
  end
end

GQL.resolver("users") do |args, context|
  require_relative "../orm/user"
  limit = args.fetch("limit", 20)
  offset = args.fetch("offset", 0)
  User.new.select(limit: limit, skip: offset).to_list
end

GQL.resolver("createUser") do |args, context|
  require_relative "../orm/user"
  user = User.new({ "name" => args["name"], "email" => args["email"] })
  user.save
  user.to_hash
end
```

## Route (`src/routes/graphql.rb`)

```ruby
require "tina4/router"
require_relative "../app/graphql_schema"

Tina4::Router.post "/graphql",
  noauth: true do |request, response|
  result = GQL.execute_json(request.raw_body)
  response.json(result)
end
```

## Auto-Generate Schema from ORM

```ruby
require "tina4/graphql"
require_relative "../orm/product"

schema = Tina4::Schema.new
schema.from_orm(Product)  # Auto-creates type, query, list query
```

## GraphQL Query Syntax Reference

```graphql
# Simple query
{ users { id name email } }

# Named query with variables
query GetUser($id: ID!) {
    user(id: $id) { id name email role }
}

# Mutation
mutation CreateUser($name: String!, $email: String!) {
    createUser(name: $name, email: $email) { id name }
}

# Aliases
{ admins: users(role: "admin") { name } guests: users(role: "guest") { name } }

# Fragments
fragment UserFields on User { id name email }
query { user(id: 1) { ...UserFields } }

# Directives
query ($showEmail: Boolean!) {
    user(id: 1) { name email @include(if: $showEmail) }
}
```

## Key Rules

- Put schema definition in `src/app/`, not in routes
- Resolvers receive `(args, context)` -- use context for auth info
- Use `execute_json` for raw JSON string input, `execute` for parsed hashes
- For protected GraphQL, remove `noauth: true` and pass token payload as context
