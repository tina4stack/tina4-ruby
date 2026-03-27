# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Router template: keyword" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_tpl_kw_test") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }
  let(:tpl_dir) { File.join(tmp_dir, "templates") }

  before do
    Tina4::Router.clear!
    FileUtils.mkdir_p(tpl_dir)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  def rack_env(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new(""),
      "HTTP_HOST" => "localhost"
    }
  end

  # Helper to create a template file and return its absolute path
  def write_template(name, content)
    path = File.join(tpl_dir, name)
    File.write(path, content)
    path
  end

  describe "Route registration" do
    it "stores the template on the Route object" do
      route = Tina4::Router.get("/dash", template: "dash.twig") { |_req, _res| {} }
      expect(route.template).to eq("dash.twig")
    end

    it "defaults template to nil when not provided" do
      route = Tina4::Router.get("/plain") { |_req, _res| "hello" }
      expect(route.template).to be_nil
    end

    it "stores template via add_route" do
      route = Tina4::Router.add_route("POST", "/api", proc { {} }, template: "api.twig")
      expect(route.template).to eq("api.twig")
    end
  end

  describe "Template rendering through RackApp" do
    it "renders a twig template when handler returns a Hash" do
      tpl = write_template("dashboard.twig", "<h1>{{ title }}</h1><p>{{ count }} items</p>")

      Tina4::Router.get("/dashboard", template: tpl) do |_req, _res|
        { title: "My Dashboard", count: 42 }
      end

      status, headers, body = app.call(rack_env("GET", "/dashboard"))
      html = body.join

      expect(status).to eq(200)
      expect(headers["content-type"]).to include("text/html")
      expect(html).to include("<h1>My Dashboard</h1>")
      expect(html).to include("<p>42 items</p>")
    end

    it "does not render template when handler returns a non-Hash" do
      tpl = write_template("unused.twig", "<h1>{{ title }}</h1>")

      Tina4::Router.get("/string-response", template: tpl) do |_req, _res|
        "plain text response"
      end

      status, _headers, body = app.call(rack_env("GET", "/string-response"))
      html = body.join

      expect(status).to eq(200)
      expect(html).to eq("plain text response")
    end

    it "does not render template when template: is not set even if handler returns Hash" do
      Tina4::Router.get("/no-template") do |_req, _res|
        { title: "Ignored" }
      end

      status, headers, body = app.call(rack_env("GET", "/no-template"))
      html = body.join

      expect(status).to eq(200)
      expect(headers["content-type"]).to include("application/json")
      expect(html).to include('"title"')
    end

    it "works with for loops in templates" do
      tpl = write_template("list.twig", "{% for item in items %}<li>{{ item }}</li>{% endfor %}")

      Tina4::Router.get("/list", template: tpl) do |_req, _res|
        { items: %w[alpha beta gamma] }
      end

      status, _headers, body = app.call(rack_env("GET", "/list"))
      html = body.join

      expect(status).to eq(200)
      expect(html).to include("<li>alpha</li>")
      expect(html).to include("<li>beta</li>")
      expect(html).to include("<li>gamma</li>")
    end

    it "works with POST routes" do
      tpl = write_template("created.twig", "<p>Created {{ name }}</p>")

      Tina4::Router.post("/items", template: tpl) do |_req, _res|
        { name: "Widget" }
      end.no_auth

      status, _headers, body = app.call(rack_env("POST", "/items"))
      html = body.join

      expect(status).to eq(200)
      expect(html).to include("<p>Created Widget</p>")
    end
  end

  describe "GroupContext with template:" do
    it "passes template through group context" do
      tpl = write_template("admin.twig", "<h1>Admin: {{ section }}</h1>")

      Tina4::Router.group("/admin") do
        get("/home", template: tpl) do |_req, _res|
          { section: "Home" }
        end
      end

      status, _headers, body = app.call(rack_env("GET", "/admin/home"))
      html = body.join

      expect(status).to eq(200)
      expect(html).to include("<h1>Admin: Home</h1>")
    end
  end
end
