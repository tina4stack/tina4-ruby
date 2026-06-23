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
    it "honours the template stored on the Route object end-to-end via RackApp" do
      # The stored template value is only meaningful if dispatch actually uses
      # it: register a real twig file via template: and assert the rendered
      # HTML reflects that template (proving the stored value is read, not just
      # held). The Route still exposes the value it was given.
      tpl = write_template("dash.twig", "<h1>Dash: {{ name }}</h1>")

      route = Tina4::Router.get("/dash", template: tpl) do |_req, _res|
        { name: "Overview" }
      end
      expect(route.template).to eq(tpl)

      status, headers, body = app.call(rack_env("GET", "/dash"))
      html = body.join

      expect(status).to eq(200)
      expect(headers["content-type"]).to include("text/html")
      expect(html).to include("<h1>Dash: Overview</h1>")
    end

    it "returns the handler value verbatim (JSON) when no template: is given" do
      # The behavioural consequence of a nil template: a route with no template
      # serialises the handler's Hash as JSON rather than rendering HTML. The
      # Route still reports template == nil.
      route = Tina4::Router.get("/plain") do |_req, _res|
        { greeting: "hello" }
      end
      expect(route.template).to be_nil

      status, headers, body = app.call(rack_env("GET", "/plain"))
      html = body.join

      expect(status).to eq(200)
      expect(headers["content-type"]).to include("application/json")
      expect(html).not_to include("text/html")
      expect(JSON.parse(html)).to eq("greeting" => "hello")
    end

    it "wires the template passed to add into dispatch (rendered body)" do
      # add() is the lower-level registration path. Register a POST route with a
      # real twig file through add and assert the response body is the RENDERED
      # template output, proving add's template: is actually plumbed through to
      # the dispatcher (not merely stored on the Route).
      tpl = write_template("api.twig", "<p>API: {{ status }}</p>")

      route = Tina4::Router.add("POST", "/api", proc { { status: "ok" } }, template: tpl)
      route.no_auth # POST is secure-by-default; opt out so the handler runs
      expect(route.template).to eq(tpl)

      status, headers, body = app.call(rack_env("POST", "/api"))
      html = body.join

      expect(status).to eq(200)
      expect(headers["content-type"]).to include("text/html")
      expect(html).to include("<p>API: ok</p>")
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
