# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::GraphQLType do
  describe "::SCALARS" do
    it "contains the five built-in scalars" do
      expect(Tina4::GraphQLType::SCALARS).to contain_exactly("String", "Int", "Float", "Boolean", "ID")
    end
  end

  describe "#scalar?" do
    it "returns true for scalar types" do
      type = Tina4::GraphQLType.new("String", :scalar)
      expect(type.scalar?).to be true
    end

    it "returns true for named scalars even if kind is :object" do
      type = Tina4::GraphQLType.new("Int", :object)
      expect(type.scalar?).to be true
    end

    it "returns false for object types" do
      type = Tina4::GraphQLType.new("User", :object)
      expect(type.scalar?).to be false
    end
  end

  describe "#list? and #non_null?" do
    it "detects list types" do
      type = Tina4::GraphQLType.new("[String]", :list)
      expect(type.list?).to be true
      expect(type.non_null?).to be false
    end

    it "detects non-null types" do
      type = Tina4::GraphQLType.new("String!", :non_null)
      expect(type.non_null?).to be true
      expect(type.list?).to be false
    end
  end

  describe ".parse" do
    it "parses a simple scalar" do
      type = Tina4::GraphQLType.parse("String")
      expect(type.scalar?).to be true
      expect(type.name).to eq("String")
    end

    it "parses a non-null scalar" do
      type = Tina4::GraphQLType.parse("String!")
      expect(type.non_null?).to be true
      expect(type.of_type.name).to eq("String")
    end

    it "parses a list type" do
      type = Tina4::GraphQLType.parse("[Int]")
      expect(type.list?).to be true
      expect(type.of_type.name).to eq("Int")
    end

    it "parses a non-null list type" do
      type = Tina4::GraphQLType.parse("[Int!]!")
      expect(type.non_null?).to be true
      expect(type.of_type.list?).to be true
    end

    it "parses an object type name" do
      type = Tina4::GraphQLType.parse("User")
      expect(type.kind).to eq(:object)
      expect(type.name).to eq("User")
    end
  end
end

RSpec.describe Tina4::GraphQLSchema do
  subject(:schema) { Tina4::GraphQLSchema.new }

  describe "#initialize" do
    it "registers all scalar types" do
      %w[String Int Float Boolean ID].each do |s|
        expect(schema.get_type(s)).not_to be_nil
      end
    end
  end

  describe "#add_type and #get_type" do
    it "registers and retrieves a custom type" do
      user_type = Tina4::GraphQLType.new("User", :object, fields: { "name" => { type: "String" } })
      schema.add_type(user_type)
      expect(schema.get_type("User")).to equal(user_type)
    end
  end

  describe "#add_query" do
    it "registers a query field" do
      schema.add_query("hello", {}, "String") { |_r, _a, _c| "world" }
      expect(schema.queries).to have_key("hello")
      expect(schema.queries["hello"][:type]).to eq("String")
    end

    it "stores the resolver block" do
      schema.add_query("greet", {}, "String") { |_r, _a, _c| "hi" }
      result = schema.queries["greet"][:resolve].call(nil, {}, {})
      expect(result).to eq("hi")
    end
  end

  describe "#add_mutation" do
    it "registers a mutation field" do
      schema.add_mutation("createUser", { "name" => { type: "String!" } }, "User") { |_r, a, _c| a }
      expect(schema.mutations).to have_key("createUser")
    end
  end
end

RSpec.describe Tina4::GraphQLParser do
  def parse(query)
    Tina4::GraphQLParser.new(query).parse
  end

  it "parses a shorthand query" do
    doc = parse('{ hello }')
    expect(doc[:kind]).to eq(:document)
    expect(doc[:definitions].first[:operation]).to eq(:query)
    expect(doc[:definitions].first[:selection_set].first[:name]).to eq("hello")
  end

  it "parses a named query" do
    doc = parse('query GetUser { user { name } }')
    op = doc[:definitions].first
    expect(op[:name]).to eq("GetUser")
    expect(op[:operation]).to eq(:query)
  end

  it "parses a mutation" do
    doc = parse('mutation CreateUser { createUser(name: "Alice") { id } }')
    op = doc[:definitions].first
    expect(op[:operation]).to eq(:mutation)
  end

  it "parses arguments with string values" do
    doc = parse('{ user(id: "1") { name } }')
    field = doc[:definitions].first[:selection_set].first
    expect(field[:arguments]["id"]).to eq("1")
  end

  it "parses integer arguments" do
    doc = parse('{ users(limit: 10) { name } }')
    field = doc[:definitions].first[:selection_set].first
    expect(field[:arguments]["limit"]).to eq(10)
  end

  it "parses float arguments" do
    doc = parse('{ price(amount: 9.99) }')
    field = doc[:definitions].first[:selection_set].first
    expect(field[:arguments]["amount"]).to eq(9.99)
  end

  it "parses boolean arguments" do
    doc = parse('{ items(active: true) { name } }')
    field = doc[:definitions].first[:selection_set].first
    expect(field[:arguments]["active"]).to be true
  end

  it "parses null arguments" do
    doc = parse('{ item(ref: null) { id } }')
    field = doc[:definitions].first[:selection_set].first
    expect(field[:arguments]["ref"]).to be_nil
  end

  it "parses aliases" do
    doc = parse('{ first: user(id: "1") { name } }')
    field = doc[:definitions].first[:selection_set].first
    expect(field[:alias]).to eq("first")
    expect(field[:name]).to eq("user")
  end

  it "parses variable definitions" do
    doc = parse('query GetUser($id: ID!) { user(id: $id) { name } }')
    op = doc[:definitions].first
    expect(op[:variables].first[:name]).to eq("id")
    expect(op[:variables].first[:type]).to eq("ID!")
  end

  it "parses variable defaults" do
    doc = parse('query Greet($name: String = "World") { greeting(name: $name) }')
    op = doc[:definitions].first
    expect(op[:variables].first[:default]).to eq("World")
  end

  it "parses nested selection sets" do
    doc = parse('{ author { name posts { title } } }')
    author = doc[:definitions].first[:selection_set].first
    expect(author[:selection_set]).not_to be_nil
    posts = author[:selection_set].find { |s| s[:name] == "posts" }
    expect(posts[:selection_set].first[:name]).to eq("title")
  end

  it "raises on unexpected end of input" do
    expect { parse('{ user(') }.to raise_error(Tina4::GraphQLError)
  end

  it "raises on invalid token" do
    expect { parse('!!!') }.to raise_error(Tina4::GraphQLError)
  end

  it "skips comments" do
    doc = parse("# this is a comment\n{ hello }")
    expect(doc[:definitions].first[:selection_set].first[:name]).to eq("hello")
  end

  it "parses fragments" do
    query = 'fragment UserFields on User { name email } query { user { ...UserFields } }'
    doc = parse(query)
    frag = doc[:definitions].find { |d| d[:kind] == :fragment }
    expect(frag[:name]).to eq("UserFields")
    expect(frag[:on]).to eq("User")
  end
end

RSpec.describe Tina4::GraphQL do
  subject(:gql) { Tina4::GraphQL.new }

  before do
    users = [
      { "id" => "1", "name" => "Alice", "email" => "alice@test.com" },
      { "id" => "2", "name" => "Bob", "email" => "bob@test.com" },
    ]

    gql.schema.add_query("user", { "id" => { type: "ID!" } }, "User") do |_root, args, _ctx|
      users.find { |u| u["id"] == args["id"] }
    end

    gql.schema.add_query("users", {}, "[User]") do |_root, _args, _ctx|
      users
    end
  end

  describe "#execute" do
    it "executes a simple query" do
      result = gql.execute('{ user(id: "1") { name email } }')
      expect(result["data"]["user"]["name"]).to eq("Alice")
      expect(result["data"]["user"]["email"]).to eq("alice@test.com")
    end

    it "returns no errors on success" do
      result = gql.execute('{ user(id: "1") { name } }')
      expect(result["errors"]).to be_nil
    end

    it "executes a list query" do
      result = gql.execute('{ users { id name } }')
      expect(result["data"]["users"]).to be_an(Array)
      expect(result["data"]["users"].size).to eq(2)
    end

    it "selects only requested fields" do
      result = gql.execute('{ users { name } }')
      first = result["data"]["users"].first
      expect(first).to have_key("name")
      expect(first).not_to have_key("email")
    end

    it "resolves aliases" do
      result = gql.execute('{ first: user(id: "1") { name } second: user(id: "2") { name } }')
      expect(result["data"]["first"]["name"]).to eq("Alice")
      expect(result["data"]["second"]["name"]).to eq("Bob")
    end

    it "substitutes variables" do
      result = gql.execute(
        'query GetUser($userId: ID!) { user(id: $userId) { name } }',
        variables: { "userId" => "2" }
      )
      expect(result["data"]["user"]["name"]).to eq("Bob")
    end

    it "applies variable defaults" do
      gql.schema.add_query("greeting", {}, "String") { |_r, args, _c| "Hello, #{args['name']}!" }
      result = gql.execute('query Greet($name: String = "World") { greeting(name: $name) }')
      expect(result["data"]["greeting"]).to eq("Hello, World!")
    end

    it "handles resolver errors gracefully" do
      gql.schema.add_query("broken", {}, "String") { |_r, _a, _c| raise "boom" }
      result = gql.execute('{ broken }')
      expect(result["errors"]).not_to be_nil
      expect(result["errors"].first["message"]).to eq("boom")
      expect(result["data"]["broken"]).to be_nil
    end

    it "handles parse errors" do
      result = gql.execute('{ broken(')
      expect(result["errors"]).not_to be_nil
      expect(result["data"]).to be_nil
    end

    it "handles empty query" do
      result = gql.execute('')
      # Empty query produces empty document with no operations
      expect(result["errors"]).not_to be_nil
    end
  end

  describe "#execute with mutations" do
    it "executes a mutation" do
      created = nil
      gql.schema.add_mutation("createUser", { "name" => { type: "String!" } }, "User") do |_r, args, _c|
        created = { "id" => "3", "name" => args["name"] }
        created
      end

      result = gql.execute('mutation { createUser(name: "Eve") { id name } }')
      expect(result["data"]["createUser"]["name"]).to eq("Eve")
      expect(created).not_to be_nil
    end
  end

  describe "#execute with nested objects" do
    it "resolves nested selection sets" do
      gql.schema.add_query("author", { "id" => { type: "ID!" } }, "Author") do |_r, args, _c|
        {
          "id" => args["id"],
          "name" => "Jane",
          "posts" => [
            { "id" => "p1", "title" => "First Post" },
            { "id" => "p2", "title" => "Second Post" },
          ]
        }
      end

      result = gql.execute('{ author(id: "1") { name posts { title } } }')
      expect(result["data"]["author"]["name"]).to eq("Jane")
      expect(result["data"]["author"]["posts"]).to be_an(Array)
      expect(result["data"]["author"]["posts"].first["title"]).to eq("First Post")
    end
  end

  describe "#execute with integer args" do
    it "parses integer arguments correctly" do
      gql.schema.add_query("add", { "x" => { type: "Int" } }, "Int") do |_r, args, _c|
        args["x"].to_i + 20
      end

      result = gql.execute('{ add(x: 10) }')
      expect(result["errors"]).to be_nil
      expect(result["data"]["add"]).to eq(30)
    end
  end

  describe "#handle_request" do
    it "handles a JSON request body" do
      gql.schema.add_query("ping", {}, "String") { |_r, _a, _c| "pong" }
      body = JSON.generate({ "query" => "{ ping }" })
      result = gql.handle_request(body)
      expect(result["data"]["ping"]).to eq("pong")
    end

    it "handles variables in request body" do
      body = JSON.generate({ "query" => 'query($id: ID!) { user(id: $id) { name } }', "variables" => { "id" => "1" } })
      result = gql.handle_request(body)
      expect(result["data"]["user"]["name"]).to eq("Alice")
    end

    it "returns error for invalid JSON" do
      result = gql.handle_request("not json")
      expect(result["errors"]).not_to be_nil
      expect(result["errors"].first["message"]).to include("Invalid JSON")
    end
  end
end
