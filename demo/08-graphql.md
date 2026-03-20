# GraphQL

Tina4 Ruby includes a zero-dependency GraphQL implementation with a recursive-descent parser, depth-first executor, programmatic schema, and automatic ORM-to-GraphQL schema generation. It also serves a GraphiQL IDE at the endpoint.

## Quick Start

```ruby
require "tina4"

schema = Tina4::GraphQLSchema.new

# Define a type
user_type = Tina4::GraphQLType.new("User", :object, fields: {
  "id"    => { type: "ID" },
  "name"  => { type: "String" },
  "email" => { type: "String" }
})
schema.add_type(user_type)

# Define a query
schema.add_query("user", type: "User", args: { "id" => { type: "ID!" } }) do |_root, args, _ctx|
  { "id" => args["id"], "name" => "Alice", "email" => "alice@example.com" }
end

schema.add_query("users", type: "[User]", args: {
  "limit" => { type: "Int" }
}) do |_root, args, _ctx|
  [
    { "id" => "1", "name" => "Alice", "email" => "alice@example.com" },
    { "id" => "2", "name" => "Bob", "email" => "bob@example.com" }
  ]
end

# Create GraphQL handler and register routes
gql = Tina4::GraphQL.new(schema)
gql.register_route("/graphql")
# POST /graphql  -- execute queries
# GET  /graphql  -- serves GraphiQL IDE
```

## Mutations

```ruby
schema.add_mutation("createUser",
  type: "User",
  args: { "name" => { type: "String!" }, "email" => { type: "String!" } }
) do |_root, args, _ctx|
  user = User.create(name: args["name"], email: args["email"])
  user.to_h
end

schema.add_mutation("deleteUser",
  type: "Boolean",
  args: { "id" => { type: "ID!" } }
) do |_root, args, _ctx|
  user = User.find(args["id"].to_i)
  user ? user.delete : false
end
```

## ORM Auto-Schema

Generate a full GraphQL schema from an ORM model with one call. Creates queries (single + list) and mutations (create, update, delete) automatically.

```ruby
class Article < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :title
  text_field    :body
  boolean_field :published, default: false
end

schema = Tina4::GraphQLSchema.new
schema.from_orm(Article)

# This generates:
#   Query:
#     article(id: ID!): Article
#     articles(limit: Int, offset: Int): [Article]
#   Mutation:
#     createArticle(input: ArticleInput!): Article
#     updateArticle(id: ID!, input: ArticleInput!): Article
#     deleteArticle(id: ID!): Boolean

gql = Tina4::GraphQL.new(schema)
gql.register_route("/graphql")
```

## Multiple ORM Models

```ruby
schema = Tina4::GraphQLSchema.new
schema.from_orm(User)
schema.from_orm(Article)
schema.from_orm(Comment)

gql = Tina4::GraphQL.new(schema)
gql.register_route("/graphql")
```

## Executing Queries Programmatically

```ruby
gql = Tina4::GraphQL.new(schema)

# Execute a query string
result = gql.execute('{ user(id: "1") { name email } }')
puts result["data"]["user"]["name"]  # => "Alice"

# With variables
result = gql.execute(
  'query GetUser($id: ID!) { user(id: $id) { name } }',
  variables: { "id" => "1" }
)

# Handle JSON request body (HTTP integration)
result = gql.handle_request('{"query": "{ users { name } }"}')
```

## Query Syntax Examples

```graphql
# Simple query
{ users { id name email } }

# Named query with variables
query GetUser($id: ID!) {
  user(id: $id) {
    name
    email
  }
}

# Aliases
{
  firstUser: user(id: "1") { name }
  secondUser: user(id: "2") { name }
}

# Mutations
mutation {
  createUser(name: "Charlie", email: "charlie@example.com") {
    id
    name
  }
}

# Fragments
fragment UserFields on User {
  id
  name
  email
}

{
  user(id: "1") { ...UserFields }
}
```

## GraphiQL IDE

When you register a route with `gql.register_route("/graphql")`, a GET request without a `query` parameter serves the GraphiQL IDE, letting you explore and test your schema in the browser.

Visit `http://localhost:7145/graphql` in your browser to use it.

## Type System

```ruby
# Scalar types: String, Int, Float, Boolean, ID
# Non-null: "String!"
# List: "[String]"
# Nested: "[Int!]!"

type = Tina4::GraphQLType.parse("[String!]!")
type.non_null?   # => true
type.of_type.list? # => true
```

## Error Handling

GraphQL errors are returned in the standard format:

```json
{
  "data": null,
  "errors": [{ "message": "Unknown operation: badOp" }]
}
```
