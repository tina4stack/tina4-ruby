# frozen_string_literal: true

require "spec_helper"

# Test model for CRUD
class CrudTestModel < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  string_field :email
  integer_field :age, default: 0
end

RSpec.describe Tina4::Crud do
  let(:tmp_dir) { Dir.mktmpdir("tina4_crud") }
  let(:db_path) { File.join(tmp_dir, "crud_test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.database = db
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
    Tina4::Crud.instance_variable_set(:@registered_tables, {})
    db.execute("CREATE TABLE IF NOT EXISTS crudtestmodels (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, age INTEGER DEFAULT 0)")
    db.insert("crudtestmodels", { name: "Alice", email: "alice@example.com", age: 30 })
    db.insert("crudtestmodels", { name: "Bob", email: "bob@example.com", age: 25 })
    db.insert("crudtestmodels", { name: "Charlie", email: "charlie@example.com", age: 35 })
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  def mock_request(path: "/admin/test", query: {})
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "QUERY_STRING" => query.map { |k, v| "#{k}=#{v}" }.join("&"),
      "CONTENT_TYPE" => "text/html"
    }
    Tina4::Request.new(env)
  end

  describe ".to_crud with :model" do
    it "generates a complete HTML page" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel, title: "Test CRUD" })
      expect(html).to include("Test CRUD")
      expect(html).to include("<table")
      expect(html).to include("Alice")
      expect(html).to include("Bob")
      expect(html).to include("Charlie")
    end

    it "includes create, edit, and delete modals" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel, title: "Test CRUD" })
      expect(html).to include("modal-create")
      expect(html).to include("modal-edit")
      expect(html).to include("modal-delete")
      expect(html).to include("Create New Record")
      expect(html).to include("Edit Record")
      expect(html).to include("Confirm Delete")
    end

    it "includes search form" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel })
      expect(html).to include('name="search"')
      expect(html).to include('placeholder="Search..."')
    end

    it "includes pagination info" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel })
      expect(html).to include("Showing 3 of 3 records")
    end

    it "includes sort links in headers" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel })
      expect(html).to include("sort=id")
      expect(html).to include("sort=name")
      expect(html).to include("sort=email")
    end

    it "includes JavaScript for CRUD operations" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel })
      expect(html).to include("crudShowCreate")
      expect(html).to include("crudSaveCreate")
      expect(html).to include("crudSaveEdit")
      expect(html).to include("crudConfirmDelete")
    end

    it "registers API routes" do
      request = mock_request
      Tina4::Crud.to_crud(request, { model: CrudTestModel })
      routes = Tina4::Router.routes.map { |r| "#{r.method} #{r.path}" }
      expect(routes).to include("POST /api/crudtestmodels")
      expect(routes).to include("PUT /api/crudtestmodels/{id}")
      expect(routes).to include("DELETE /api/crudtestmodels/{id}")
    end
  end

  describe ".to_crud with :sql" do
    it "generates HTML from a SQL query" do
      request = mock_request
      html = Tina4::Crud.to_crud(request, {
        sql: "SELECT id, name, email FROM crudtestmodels",
        title: "SQL CRUD",
        primary_key: "id"
      })
      expect(html).to include("SQL CRUD")
      expect(html).to include("Alice")
      expect(html).to include("Bob")
    end
  end

  describe ".to_crud search" do
    it "filters records by search term" do
      request = mock_request(query: { "search" => "Alice" })
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel, title: "Search Test" })
      expect(html).to include("Alice")
      expect(html).not_to include("Bob")
      expect(html).not_to include("Charlie")
    end
  end

  describe ".to_crud pagination" do
    it "paginates records" do
      request = mock_request(query: { "page" => "1" })
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel, limit: 2 })
      expect(html).to include("page 1 of 2")
      expect(html).to include("Next")
    end

    it "shows second page" do
      request = mock_request(query: { "page" => "2" })
      html = Tina4::Crud.to_crud(request, { model: CrudTestModel, limit: 2 })
      expect(html).to include("page 2 of 2")
      expect(html).to include("Prev")
    end
  end

  describe "CRUD alias" do
    it "Tina4::CRUD is an alias for Tina4::Crud" do
      expect(Tina4::CRUD).to eq(Tina4::Crud)
    end
  end

  describe ".generate_table" do
    it "generates an HTML table from records" do
      records = [{ id: 1, name: "Alice" }, { id: 2, name: "Bob" }]
      html = Tina4::Crud.generate_table(records, table_name: "users", primary_key: "id")
      expect(html).to include("<table")
      expect(html).to include("Alice")
      expect(html).to include("Bob")
      expect(html).to include("crudSave")
    end

    it "returns message when no records" do
      html = Tina4::Crud.generate_table([], table_name: "users")
      expect(html).to include("No records found")
    end
  end

  describe ".generate_form" do
    it "generates an HTML form from field definitions" do
      fields = [
        { name: "name", type: :string, label: "Full Name", required: true },
        { name: "email", type: :string, label: "Email" }
      ]
      html = Tina4::Crud.generate_form(fields, action: "/api/users", method: "POST")
      expect(html).to include("<form")
      expect(html).to include("Full Name")
      expect(html).to include('name="name"')
      expect(html).to include('name="email"')
    end
  end

  describe "raises on missing options" do
    it "raises ArgumentError when neither :sql nor :model given" do
      request = mock_request
      expect { Tina4::Crud.to_crud(request, { title: "Broken" }) }.to raise_error(ArgumentError)
    end
  end
end
