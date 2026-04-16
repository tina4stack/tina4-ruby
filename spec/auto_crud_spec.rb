# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Test model for auto-CRUD
class CrudItem < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  integer_field :price, default: 0
end

RSpec.describe Tina4::AutoCrud do
  let(:tmp_dir) { Dir.mktmpdir("tina4_auto_crud") }
  let(:db_path) { File.join(tmp_dir, "crud.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.database = db
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
    db.execute("CREATE TABLE IF NOT EXISTS cruditems (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, price INTEGER DEFAULT 0)")
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".register" do
    it "registers a model class" do
      Tina4::AutoCrud.register(CrudItem)
      expect(Tina4::AutoCrud.models).to include(CrudItem)
    end

    it "does not duplicate registrations" do
      Tina4::AutoCrud.register(CrudItem)
      Tina4::AutoCrud.register(CrudItem)
      expect(Tina4::AutoCrud.models.length).to eq(1)
    end
  end

  describe ".generate_routes_for" do
    before do
      Tina4::AutoCrud.generate_routes_for(CrudItem)
    end

    it "creates GET list route" do
      route, _ = Tina4::Router.match("GET", "/api/cruditems")
      expect(route).not_to be_nil
    end

    it "creates GET single route" do
      route, params = Tina4::Router.match("GET", "/api/cruditems/1")
      expect(route).not_to be_nil
      expect(params[:id]).to eq("1")
    end

    it "creates POST route" do
      route, _ = Tina4::Router.match("POST", "/api/cruditems")
      expect(route).not_to be_nil
    end

    it "creates PUT route" do
      route, _ = Tina4::Router.match("PUT", "/api/cruditems/1")
      expect(route).not_to be_nil
    end

    it "creates DELETE route" do
      route, _ = Tina4::Router.match("DELETE", "/api/cruditems/1")
      expect(route).not_to be_nil
    end

    it "supports custom prefix" do
      Tina4::Router.clear!
      Tina4::AutoCrud.generate_routes_for(CrudItem, prefix: "/v2/api")
      route, _ = Tina4::Router.match("GET", "/v2/api/cruditems")
      expect(route).not_to be_nil
    end
  end

  describe "route handlers" do
    before do
      Tina4::AutoCrud.generate_routes_for(CrudItem)
      CrudItem.new(name: "Widget", price: 100).save
      CrudItem.new(name: "Gadget", price: 200).save
      CrudItem.new(name: "Doohickey", price: 50).save
    end

    it "list endpoint returns records" do
      route, params = Tina4::Router.match("GET", "/api/cruditems")
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/api/cruditems",
        "QUERY_STRING" => "limit=10&offset=0",
        "CONTENT_TYPE" => "",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new("")
      }
      req = Tina4::Request.new(env, params)
      res = Tina4::Response.new
      result = route.handler.call(req, res)
      body = JSON.parse(result.body)
      expect(body["data"].length).to eq(3)
      expect(body["total"]).to eq(3)
    end

    it "single endpoint returns one record" do
      item = CrudItem.all.first
      route, params = Tina4::Router.match("GET", "/api/cruditems/#{item.id}")
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/api/cruditems/#{item.id}",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new("")
      }
      req = Tina4::Request.new(env, params)
      res = Tina4::Response.new
      result = route.handler.call(req, res)
      body = JSON.parse(result.body)
      expect(body["data"]["name"]).to eq(item.name)
    end

    it "single endpoint returns 404 for missing record" do
      route, params = Tina4::Router.match("GET", "/api/cruditems/9999")
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/api/cruditems/9999",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new("")
      }
      req = Tina4::Request.new(env, params)
      res = Tina4::Response.new
      result = route.handler.call(req, res)
      expect(result.status_code).to eq(404)
    end

    it "create endpoint inserts a record" do
      route, params = Tina4::Router.match("POST", "/api/cruditems")
      json_body = '{"name":"NewItem","price":300}'
      env = {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/api/cruditems",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "application/json",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new(json_body)
      }
      req = Tina4::Request.new(env, params)
      res = Tina4::Response.new
      result = route.handler.call(req, res)
      expect(result.status_code).to eq(201)
      body = JSON.parse(result.body)
      expect(body["data"]["name"]).to eq("NewItem")
    end

    it "delete endpoint removes a record" do
      item = CrudItem.all.first
      route, params = Tina4::Router.match("DELETE", "/api/cruditems/#{item.id}")
      env = {
        "REQUEST_METHOD" => "DELETE",
        "PATH_INFO" => "/api/cruditems/#{item.id}",
        "QUERY_STRING" => "",
        "CONTENT_TYPE" => "",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new("")
      }
      req = Tina4::Request.new(env, params)
      res = Tina4::Response.new
      result = route.handler.call(req, res)
      body = JSON.parse(result.body)
      expect(body["message"]).to eq("Deleted")
      expect(CrudItem.find_by_id(item.id)).to be_nil
    end
  end

  describe ".generate_routes" do
    it "generates routes for all registered models" do
      Tina4::AutoCrud.register(CrudItem)
      Tina4::AutoCrud.generate_routes
      route, _ = Tina4::Router.match("GET", "/api/cruditems")
      expect(route).not_to be_nil
    end
  end

  describe ".clear!" do
    it "clears registered models" do
      Tina4::AutoCrud.register(CrudItem)
      Tina4::AutoCrud.clear!
      expect(Tina4::AutoCrud.models).to be_empty
    end
  end
end
