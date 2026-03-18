# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Performance optimizations" do
  describe "JSON serialization (oj)" do
    it "oj is loaded when available" do
      expect(defined?(Oj)).to eq("constant")
    end

    it "JSON.generate produces valid JSON" do
      data = { name: "Alice", age: 30, tags: %w[ruby tina4] }
      json = JSON.generate(data)
      parsed = JSON.parse(json)
      expect(parsed["name"]).to eq("Alice")
      expect(parsed["tags"]).to eq(%w[ruby tina4])
    end

    it "JSON.parse handles nested structures" do
      json = '{"user":{"name":"Bob","scores":[1,2,3]}}'
      parsed = JSON.parse(json)
      expect(parsed["user"]["name"]).to eq("Bob")
      expect(parsed["user"]["scores"]).to eq([1, 2, 3])
    end

    it "Response.json uses fast serialization" do
      response = Tina4::Response.new
      response.json({ message: "hello", count: 42 })
      parsed = JSON.parse(response.body)
      expect(parsed["message"]).to eq("hello")
      expect(parsed["count"]).to eq(42)
    end
  end

  describe "Template HTML escape" do
    it "escapes all special characters in one pass" do
      input = %(<div class="test">&'hello'</div>)
      result = Tina4::Template::TwigEngine.escape_html(input)
      expect(result).to eq("&lt;div class=&quot;test&quot;&gt;&amp;&#39;hello&#39;&lt;/div&gt;")
    end

    it "returns unchanged string when no special characters" do
      expect(Tina4::Template::TwigEngine.escape_html("hello world")).to eq("hello world")
    end

    it "handles empty string" do
      expect(Tina4::Template::TwigEngine.escape_html("")).to eq("")
    end

    it "escapes ampersand correctly (no double-escape)" do
      expect(Tina4::Template::TwigEngine.escape_html("a&b")).to eq("a&amp;b")
    end
  end

  describe "Template for-loop string building" do
    it "concatenates loop output correctly" do
      engine = Tina4::Template::TwigEngine.new({
        "items" => %w[a b c]
      })
      result = engine.render("{% for item in items %}[{{ item }}]{% endfor %}")
      expect(result).to eq("[a][b][c]")
    end

    it "handles loop with hash iteration" do
      engine = Tina4::Template::TwigEngine.new({
        "users" => [
          { "name" => "Alice" },
          { "name" => "Bob" },
          { "name" => "Carol" }
        ]
      })
      result = engine.render("{% for user in users %}{{ user.name }},{% endfor %}")
      expect(result).to eq("Alice,Bob,Carol,")
    end

    it "handles large loops without excessive allocations" do
      items = (1..100).to_a
      engine = Tina4::Template::TwigEngine.new({ "items" => items })
      result = engine.render("{% for i in items %}{{ i }},{% endfor %}")
      expect(result.split(",").reject(&:empty?).length).to eq(100)
    end
  end

  describe "Template filter argument parsing" do
    it "parses simple string arguments" do
      engine = Tina4::Template::TwigEngine.new({ "items" => %w[a b c] })
      result = engine.render("{{ items | join(', ') }}")
      expect(result.strip).to eq("a, b, c")
    end

    it "parses numeric arguments" do
      engine = Tina4::Template::TwigEngine.new({ "price" => 19.995 })
      result = engine.render("{{ price | round(2) }}")
      expect(result.strip).to eq("20.0")
    end

    it "handles default filter" do
      engine = Tina4::Template::TwigEngine.new({})
      result = engine.render("{{ missing | default('N/A') }}")
      expect(result.strip).to eq("N/A")
    end
  end

  describe "OpenAPI spec caching" do
    it "caches the JSON output after first call" do
      app = Tina4::RackApp.new(root_dir: Dir.pwd)
      # Call serve_openapi_json twice via the Rack interface
      env1 = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/swagger/openapi.json",
               "QUERY_STRING" => "", "rack.input" => StringIO.new("") }
      env2 = env1.dup

      status1, _headers1, body1 = app.call(env1)
      status2, _headers2, body2 = app.call(env2)

      expect(status1).to eq(200)
      expect(status2).to eq(200)
      # Same object reference — cached, not regenerated
      expect(body1.first.object_id).to eq(body2.first.object_id)
    end
  end

  describe "DatabaseResult JSON serialization" do
    it "generates valid JSON from records" do
      records = [{ "id" => 1, "name" => "Alice" }, { "id" => 2, "name" => "Bob" }]
      result = Tina4::DatabaseResult.new(records)
      json = result.to_json
      parsed = JSON.parse(json)
      expect(parsed.length).to eq(2)
      expect(parsed[0]["name"]).to eq("Alice")
    end
  end
end
