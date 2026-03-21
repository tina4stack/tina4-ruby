# frozen_string_literal: true

require_relative "../lib/tina4/frond"
require "tmpdir"
require "fileutils"

RSpec.describe Tina4::Frond do
  let(:engine) { Tina4::Frond.new }

  # ===========================================================================
  # Variables
  # ===========================================================================

  describe "variables" do
    it "renders simple variable" do
      expect(engine.render_string("Hello {{ name }}", { "name" => "World" })).to eq("Hello World")
    end

    it "renders dotted variable access" do
      data = { "user" => { "name" => "Alice" } }
      expect(engine.render_string("{{ user.name }}", data)).to eq("Alice")
    end

    it "renders array index access" do
      data = { "items" => %w[a b c] }
      expect(engine.render_string("{{ items[1] }}", data)).to eq("b")
    end

    it "renders deeply nested access" do
      data = { "a" => { "b" => { "c" => "deep" } } }
      expect(engine.render_string("{{ a.b.c }}", data)).to eq("deep")
    end

    it "renders missing variable as empty string" do
      expect(engine.render_string("{{ missing }}", {})).to eq("")
    end

    it "renders string concatenation with ~" do
      data = { "first" => "Hello", "last" => "World" }
      expect(engine.render_string("{{ first ~ ' ' ~ last }}", data)).to eq("Hello World")
    end

    it "renders ternary expression" do
      data = { "active" => true }
      expect(engine.render_string("{{ active ? 'yes' : 'no' }}", data)).to eq("yes")
      data2 = { "active" => false }
      expect(engine.render_string("{{ active ? 'yes' : 'no' }}", data2)).to eq("no")
    end

    it "renders null coalescing expression" do
      data = { "name" => nil }
      expect(engine.render_string("{{ name ?? 'default' }}", data)).to eq("default")
      data2 = { "name" => "Alice" }
      expect(engine.render_string("{{ name ?? 'default' }}", data2)).to eq("Alice")
    end

    it "renders integer literals" do
      expect(engine.render_string("{{ 42 }}", {})).to eq("42")
    end

    it "renders string literals" do
      expect(engine.render_string('{{ "hello" }}', {})).to eq("hello")
    end

    it "renders boolean literals" do
      expect(engine.render_string("{{ true }}", {})).to eq("true")
    end
  end

  # ===========================================================================
  # Auto-escaping
  # ===========================================================================

  describe "auto-escaping" do
    it "escapes HTML in string variables by default" do
      data = { "html" => "<b>bold</b>" }
      expect(engine.render_string("{{ html }}", data)).to eq("&lt;b&gt;bold&lt;/b&gt;")
    end

    it "bypasses escaping with raw filter" do
      data = { "html" => "<b>bold</b>" }
      expect(engine.render_string("{{ html | raw }}", data)).to eq("<b>bold</b>")
    end

    it "bypasses escaping with safe filter" do
      data = { "html" => "<b>bold</b>" }
      expect(engine.render_string("{{ html | safe }}", data)).to eq("<b>bold</b>")
    end
  end

  # ===========================================================================
  # Text Filters
  # ===========================================================================

  describe "text filters" do
    it "upper" do
      expect(engine.render_string("{{ name | upper }}", { "name" => "hello" })).to eq("HELLO")
    end

    it "lower" do
      expect(engine.render_string("{{ name | lower }}", { "name" => "HELLO" })).to eq("hello")
    end

    it "capitalize" do
      expect(engine.render_string("{{ name | capitalize }}", { "name" => "hello world" })).to eq("Hello world")
    end

    it "title" do
      expect(engine.render_string("{{ name | title }}", { "name" => "hello world" })).to eq("Hello World")
    end

    it "trim" do
      expect(engine.render_string("{{ name | trim }}", { "name" => "  hello  " })).to eq("hello")
    end

    it "ltrim" do
      expect(engine.render_string("{{ name | ltrim }}", { "name" => "  hello  " })).to eq("hello  ")
    end

    it "rtrim" do
      expect(engine.render_string("{{ name | rtrim }}", { "name" => "  hello  " })).to eq("  hello")
    end

    it "replace" do
      expect(engine.render_string("{{ name | replace('world', 'Ruby') }}", { "name" => "hello world" })).to eq("hello Ruby")
    end

    it "striptags" do
      expect(engine.render_string("{{ html | striptags }}", { "html" => "<p>Hello</p>" })).to eq("Hello")
    end
  end

  # ===========================================================================
  # Encoding Filters
  # ===========================================================================

  describe "encoding filters" do
    it "escape" do
      expect(engine.render_string("{{ html | escape | raw }}", { "html" => "<b>hi</b>" })).to eq("&lt;b&gt;hi&lt;/b&gt;")
    end

    it "json_encode" do
      data = { "obj" => { "a" => 1 } }
      result = engine.render_string("{{ obj | json_encode | raw }}", data)
      expect(JSON.parse(result)).to eq({ "a" => 1 })
    end

    it "json_decode" do
      data = { "json_str" => '{"a":1}' }
      result = engine.render_string("{{ json_str | json_decode | json_encode | raw }}", data)
      expect(JSON.parse(result)).to eq({ "a" => 1 })
    end

    it "base64_encode" do
      expect(engine.render_string("{{ text | base64_encode }}", { "text" => "hello" })).to eq("aGVsbG8=")
    end

    it "base64_decode" do
      expect(engine.render_string("{{ text | base64_decode }}", { "text" => "aGVsbG8=" })).to eq("hello")
    end

    it "url_encode" do
      expect(engine.render_string("{{ text | url_encode }}", { "text" => "hello world" })).to eq("hello+world")
    end
  end

  # ===========================================================================
  # Hashing Filters
  # ===========================================================================

  describe "hashing filters" do
    it "md5" do
      expected = Digest::MD5.hexdigest("hello")
      expect(engine.render_string("{{ text | md5 }}", { "text" => "hello" })).to eq(expected)
    end

    it "sha256" do
      expected = Digest::SHA256.hexdigest("hello")
      expect(engine.render_string("{{ text | sha256 }}", { "text" => "hello" })).to eq(expected)
    end
  end

  # ===========================================================================
  # Number Filters
  # ===========================================================================

  describe "number filters" do
    it "abs" do
      expect(engine.render_string("{{ num | abs }}", { "num" => -5 })).to eq("5")
    end

    it "round with decimals" do
      expect(engine.render_string("{{ num | round(2) }}", { "num" => 3.14159 })).to eq("3.14")
    end

    it "round without decimals" do
      expect(engine.render_string("{{ num | round }}", { "num" => 3.7 })).to eq("4")
    end

    it "int" do
      expect(engine.render_string("{{ num | int }}", { "num" => "42" })).to eq("42")
    end

    it "float" do
      expect(engine.render_string("{{ num | float }}", { "num" => "3.14" })).to eq("3.14")
    end

    it "number_format" do
      expect(engine.render_string("{{ num | number_format(2) }}", { "num" => 1234567.891 })).to eq("1,234,567.89")
    end
  end

  # ===========================================================================
  # Date Filter
  # ===========================================================================

  describe "date filter" do
    it "formats a date string" do
      data = { "date" => "2024-01-15" }
      expect(engine.render_string("{{ date | date('%Y/%m/%d') }}", data)).to eq("2024/01/15")
    end

    it "formats with default format" do
      data = { "date" => "2024-01-15" }
      expect(engine.render_string("{{ date | date }}", data)).to eq("2024-01-15")
    end
  end

  # ===========================================================================
  # Array Filters
  # ===========================================================================

  describe "array filters" do
    it "length" do
      expect(engine.render_string("{{ items | length }}", { "items" => [1, 2, 3] })).to eq("3")
    end

    it "first" do
      expect(engine.render_string("{{ items | first }}", { "items" => [10, 20, 30] })).to eq("10")
    end

    it "last" do
      expect(engine.render_string("{{ items | last }}", { "items" => [10, 20, 30] })).to eq("30")
    end

    it "reverse" do
      data = { "items" => [1, 2, 3] }
      result = engine.render_string("{{ items | reverse | join(', ') }}", data)
      expect(result).to eq("3, 2, 1")
    end

    it "sort" do
      data = { "items" => [3, 1, 2] }
      result = engine.render_string("{{ items | sort | join(', ') }}", data)
      expect(result).to eq("1, 2, 3")
    end

    it "unique" do
      data = { "items" => [1, 2, 2, 3, 3] }
      result = engine.render_string("{{ items | unique | join(', ') }}", data)
      expect(result).to eq("1, 2, 3")
    end

    it "join with separator" do
      data = { "items" => %w[a b c] }
      expect(engine.render_string("{{ items | join(' - ') }}", data)).to eq("a - b - c")
    end

    it "join with default separator" do
      data = { "items" => %w[a b c] }
      expect(engine.render_string("{{ items | join }}", data)).to eq("a, b, c")
    end

    it "split" do
      result = engine.render_string("{{ text | split(', ') | first }}", { "text" => "a, b, c" })
      expect(result).to eq("a")
    end

    it "slice" do
      data = { "items" => [10, 20, 30, 40, 50] }
      result = engine.render_string("{{ items | slice(1, 3) | join(', ') }}", data)
      expect(result).to eq("20, 30")
    end

    it "batch" do
      data = { "items" => [1, 2, 3, 4, 5] }
      result = engine.render_string("{{ items | batch(2) | length }}", data)
      expect(result).to eq("3")
    end

    it "map" do
      data = { "users" => [{ "name" => "Alice" }, { "name" => "Bob" }] }
      result = engine.render_string("{{ users | map('name') | join(', ') }}", data)
      expect(result).to eq("Alice, Bob")
    end

    it "filter removes falsy" do
      data = { "items" => [1, nil, 2, false, 3] }
      result = engine.render_string("{{ items | filter | join(', ') }}", data)
      expect(result).to eq("1, 2, 3")
    end

    it "column" do
      data = { "rows" => [{ "id" => 1, "name" => "A" }, { "id" => 2, "name" => "B" }] }
      result = engine.render_string("{{ rows | column('name') | join(', ') }}", data)
      expect(result).to eq("A, B")
    end
  end

  # ===========================================================================
  # Dict Filters
  # ===========================================================================

  describe "dict filters" do
    it "keys" do
      data = { "obj" => { "a" => 1, "b" => 2 } }
      result = engine.render_string("{{ obj | keys | join(', ') }}", data)
      expect(result).to eq("a, b")
    end

    it "values" do
      data = { "obj" => { "a" => 1, "b" => 2 } }
      result = engine.render_string("{{ obj | values | join(', ') }}", data)
      expect(result).to eq("1, 2")
    end
  end

  # ===========================================================================
  # Utility Filters
  # ===========================================================================

  describe "utility filters" do
    it "default with fallback" do
      expect(engine.render_string("{{ name | default('Guest') }}", {})).to eq("Guest")
    end

    it "default with value present" do
      expect(engine.render_string("{{ name | default('Guest') }}", { "name" => "Alice" })).to eq("Alice")
    end

    it "dump" do
      result = engine.render_string("{{ val | dump | raw }}", { "val" => 42 })
      expect(result).to eq("42")
    end

    it "string" do
      expect(engine.render_string("{{ num | string }}", { "num" => 42 })).to eq("42")
    end

    it "truncate" do
      expect(engine.render_string("{{ text | truncate(5) }}", { "text" => "Hello World" })).to eq("Hello...")
    end

    it "truncate no-op when short" do
      expect(engine.render_string("{{ text | truncate(50) }}", { "text" => "Hello" })).to eq("Hello")
    end

    it "wordwrap" do
      text = "one two three four five six seven"
      result = engine.render_string("{{ text | wordwrap(10) | raw }}", { "text" => text })
      lines = result.split("\n")
      expect(lines.length).to be > 1
      lines.each { |l| expect(l.length).to be <= 12 } # allow slight overshoot from single word
    end

    it "slug" do
      expect(engine.render_string("{{ text | slug }}", { "text" => "Hello World 123!" })).to eq("hello-world-123")
    end

    it "nl2br" do
      result = engine.render_string("{{ text | nl2br | raw }}", { "text" => "line1\nline2" })
      expect(result).to include("<br>")
    end

    it "format with args" do
      expect(engine.render_string("{{ text | format('World') }}", { "text" => "Hello %s" })).to eq("Hello World")
    end
  end

  # ===========================================================================
  # Filter Chaining
  # ===========================================================================

  describe "filter chaining" do
    it "chains multiple filters" do
      data = { "name" => "  hello world  " }
      expect(engine.render_string("{{ name | trim | upper }}", data)).to eq("HELLO WORLD")
    end

    it "chains three filters" do
      data = { "text" => "  Hello World  " }
      expect(engine.render_string("{{ text | trim | lower | capitalize }}", data)).to eq("Hello world")
    end
  end

  # ===========================================================================
  # Custom Filters
  # ===========================================================================

  describe "custom filters" do
    it "registers and uses a custom filter" do
      engine.add_filter("double") { |v| v.to_s * 2 }
      expect(engine.render_string("{{ name | double }}", { "name" => "ha" })).to eq("haha")
    end

    it "custom filter with argument" do
      engine.add_filter("repeat") { |v, n| v.to_s * n.to_i }
      expect(engine.render_string("{{ name | repeat(3) }}", { "name" => "ha" })).to eq("hahaha")
    end
  end

  # ===========================================================================
  # If / Elseif / Else
  # ===========================================================================

  describe "conditionals" do
    it "renders if true" do
      expect(engine.render_string("{% if show %}yes{% endif %}", { "show" => true })).to eq("yes")
    end

    it "renders if false" do
      expect(engine.render_string("{% if show %}yes{% endif %}", { "show" => false })).to eq("")
    end

    it "renders if/else" do
      template = "{% if show %}yes{% else %}no{% endif %}"
      expect(engine.render_string(template, { "show" => false })).to eq("no")
    end

    it "renders if/elseif/else" do
      template = "{% if x == 1 %}one{% elseif x == 2 %}two{% else %}other{% endif %}"
      expect(engine.render_string(template, { "x" => 2 })).to eq("two")
    end

    it "handles comparison operators" do
      expect(engine.render_string("{% if x > 5 %}big{% endif %}", { "x" => 10 })).to eq("big")
      expect(engine.render_string("{% if x < 5 %}small{% endif %}", { "x" => 3 })).to eq("small")
      expect(engine.render_string("{% if x >= 5 %}gte{% endif %}", { "x" => 5 })).to eq("gte")
      expect(engine.render_string("{% if x != 5 %}neq{% endif %}", { "x" => 3 })).to eq("neq")
    end

    it "handles and/or operators" do
      template = "{% if a and b %}both{% endif %}"
      expect(engine.render_string(template, { "a" => true, "b" => true })).to eq("both")
      expect(engine.render_string(template, { "a" => true, "b" => false })).to eq("")

      template2 = "{% if a or b %}either{% endif %}"
      expect(engine.render_string(template2, { "a" => false, "b" => true })).to eq("either")
    end

    it "handles not operator" do
      expect(engine.render_string("{% if not show %}hidden{% endif %}", { "show" => false })).to eq("hidden")
    end

    it "handles in operator" do
      template = '{% if "a" in items %}found{% endif %}'
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("found")
    end

    it "handles not in operator" do
      template = '{% if "d" not in items %}missing{% endif %}'
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("missing")
    end

    it "handles is defined test" do
      expect(engine.render_string("{% if name is defined %}yes{% endif %}", { "name" => "Alice" })).to eq("yes")
      expect(engine.render_string("{% if missing is defined %}yes{% else %}no{% endif %}", {})).to eq("no")
    end

    it "handles is empty test" do
      expect(engine.render_string("{% if items is empty %}empty{% endif %}", { "items" => [] })).to eq("empty")
    end

    it "handles is even/odd tests" do
      expect(engine.render_string("{% if x is even %}even{% endif %}", { "x" => 4 })).to eq("even")
      expect(engine.render_string("{% if x is odd %}odd{% endif %}", { "x" => 3 })).to eq("odd")
    end

    it "handles nested if" do
      template = "{% if a %}{% if b %}both{% endif %}{% endif %}"
      expect(engine.render_string(template, { "a" => true, "b" => true })).to eq("both")
    end
  end

  # ===========================================================================
  # For Loops
  # ===========================================================================

  describe "for loops" do
    it "iterates over array" do
      template = "{% for item in items %}{{ item }}{% endfor %}"
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("abc")
    end

    it "provides loop object" do
      template = "{% for item in items %}{{ loop.index }}{% endfor %}"
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("123")
    end

    it "provides loop.index0" do
      template = "{% for item in items %}{{ loop.index0 }}{% endfor %}"
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("012")
    end

    it "provides loop.first and loop.last" do
      template = "{% for item in items %}{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %}{% endfor %}"
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("FL")
    end

    it "provides loop.length" do
      template = "{% for item in items %}{{ loop.length }}{% endfor %}"
      expect(engine.render_string(template, { "items" => %w[a b c] })).to eq("333")
    end

    it "iterates with key, value over hash" do
      template = "{% for key, val in obj %}{{ key }}={{ val }} {% endfor %}"
      data = { "obj" => { "a" => 1, "b" => 2 } }
      result = engine.render_string(template, data)
      expect(result).to include("a=1")
      expect(result).to include("b=2")
    end

    it "renders for/else when empty" do
      template = "{% for item in items %}{{ item }}{% else %}empty{% endfor %}"
      expect(engine.render_string(template, { "items" => [] })).to eq("empty")
    end

    it "iterates over range" do
      template = "{% for i in 1..3 %}{{ i }}{% endfor %}"
      expect(engine.render_string(template, {})).to eq("123")
    end

    it "supports nested for loops" do
      template = "{% for row in matrix %}{% for cell in row %}{{ cell }}{% endfor %},{% endfor %}"
      data = { "matrix" => [[1, 2], [3, 4]] }
      expect(engine.render_string(template, data)).to eq("12,34,")
    end
  end

  # ===========================================================================
  # Set
  # ===========================================================================

  describe "set" do
    it "sets a variable" do
      template = '{% set greeting = "Hello" %}{{ greeting }}'
      expect(engine.render_string(template, {})).to eq("Hello")
    end

    it "sets a computed variable" do
      template = '{% set name = first ~ " " ~ last %}{{ name }}'
      expect(engine.render_string(template, { "first" => "John", "last" => "Doe" })).to eq("John Doe")
    end
  end

  # ===========================================================================
  # Template Inheritance (extends/block)
  # ===========================================================================

  describe "template inheritance" do
    let(:tpl_dir) { Dir.mktmpdir("frond_test") }
    let(:file_engine) { Tina4::Frond.new(template_dir: tpl_dir) }

    after do
      FileUtils.rm_rf(tpl_dir)
    end

    it "renders extends and blocks" do
      File.write(File.join(tpl_dir, "base.html"), '<h1>{% block title %}Default{% endblock %}</h1><div>{% block content %}{% endblock %}</div>')
      File.write(File.join(tpl_dir, "page.html"), '{% extends "base.html" %}{% block title %}My Page{% endblock %}{% block content %}Hello{% endblock %}')
      result = file_engine.render("page.html", {})
      expect(result).to include("<h1>My Page</h1>")
      expect(result).to include("<div>Hello</div>")
    end

    it "uses default block content when child does not override" do
      File.write(File.join(tpl_dir, "base.html"), "{% block title %}Default Title{% endblock %}")
      File.write(File.join(tpl_dir, "page.html"), '{% extends "base.html" %}')
      result = file_engine.render("page.html", {})
      expect(result).to eq("Default Title")
    end

    it "handles extends with leading whitespace" do
      File.write(File.join(tpl_dir, "base.html"), '<html><body>{% block content %}default{% endblock %}</body></html>')
      File.write(File.join(tpl_dir, "page.html"), "  {% extends \"base.html\" %}\n{% block content %}<h1>Hello</h1>{% endblock %}")
      result = file_engine.render("page.html", {})
      expect(result).to include("<html><body>")
      expect(result).to include("<h1>Hello</h1>")
    end

    it "handles extends with leading newlines" do
      File.write(File.join(tpl_dir, "base.html"), '<html><body>{% block content %}default{% endblock %}</body></html>')
      File.write(File.join(tpl_dir, "page.html"), "\n\n{% extends \"base.html\" %}\n{% block content %}<h1>Hello</h1>{% endblock %}")
      result = file_engine.render("page.html", {})
      expect(result).to include("<html><body>")
      expect(result).to include("<h1>Hello</h1>")
    end

    it "renders variables inside blocks with extends" do
      File.write(File.join(tpl_dir, "base.html"), "<head><title>{% block title %}Default{% endblock %}</title></head>\n<body>{% block content %}{% endblock %}</body>")
      File.write(File.join(tpl_dir, "error.html"), "\n{% extends \"base.html\" %}\n{% block title %}Error {{ code }}{% endblock %}\n{% block content %}<div class=\"card\"><h1>{{ code }}</h1><p>{{ msg }}</p></div>{% endblock %}")
      result = file_engine.render("error.html", { "code" => 500, "msg" => "Internal Server Error" })
      expect(result).to include("<title>Error 500</title>")
      expect(result).to include("<h1>500</h1>")
      expect(result).to include("Internal Server Error")
    end
  end

  # ===========================================================================
  # Whitespace Control
  # ===========================================================================

  describe "whitespace control" do
    it "strips whitespace with - on block tags" do
      template = "  {%- if true -%}  hello  {%- endif -%}  "
      expect(engine.render_string(template, {})).to eq("hello")
    end

    it "strips whitespace with - on var tags" do
      template = "  {{- name -}}  "
      expect(engine.render_string(template, { "name" => "hi" })).to eq("hi")
    end
  end

  # ===========================================================================
  # Comments
  # ===========================================================================

  describe "comments" do
    it "removes comments" do
      template = "Hello {# this is a comment #}World"
      expect(engine.render_string(template, {})).to eq("Hello World")
    end

    it "removes multi-line comments" do
      template = "Hello {# this\nis a\ncomment #}World"
      expect(engine.render_string(template, {})).to eq("Hello World")
    end
  end

  # ===========================================================================
  # Globals
  # ===========================================================================

  describe "globals" do
    it "renders global variables" do
      engine.add_global("site_name", "My Site")
      expect(engine.render_string("{{ site_name }}", {})).to eq("My Site")
    end

    it "data overrides globals" do
      engine.add_global("name", "Global")
      expect(engine.render_string("{{ name }}", { "name" => "Local" })).to eq("Local")
    end
  end

  # ===========================================================================
  # Macros
  # ===========================================================================

  describe "macros" do
    it "defines and calls a macro" do
      template = '{% macro greet(name) %}Hello {{ name }}{% endmacro %}{{ greet("World") }}'
      expect(engine.render_string(template, {})).to eq("Hello World")
    end

    it "macro with multiple params" do
      template = '{% macro add(a, b) %}{{ a }} + {{ b }}{% endmacro %}{{ add(1, 2) }}'
      # Note: a and b are passed as evaluated exprs (integers)
      result = engine.render_string(template, {})
      expect(result).to eq("1 + 2")
    end
  end

  # ===========================================================================
  # Sandboxing
  # ===========================================================================

  describe "sandboxing" do
    it "blocks disallowed variables" do
      engine.sandbox(vars: ["name"])
      result = engine.render_string("{{ secret }}", { "name" => "ok", "secret" => "hidden" })
      expect(result).to eq("")
      engine.unsandbox
    end

    it "allows whitelisted variables" do
      engine.sandbox(vars: ["name"])
      result = engine.render_string("{{ name }}", { "name" => "Alice" })
      expect(result).to eq("Alice")
      engine.unsandbox
    end

    it "blocks disallowed filters" do
      engine.sandbox(filters: ["lower"])
      result = engine.render_string("{{ name | upper }}", { "name" => "hello" })
      # upper is blocked, so the value goes through without the filter (but auto-escaped)
      expect(result).to eq("hello")
      engine.unsandbox
    end

    it "allows whitelisted filters" do
      engine.sandbox(filters: ["upper"])
      result = engine.render_string("{{ name | upper }}", { "name" => "hello" })
      expect(result).to eq("HELLO")
      engine.unsandbox
    end

    it "unsandbox restores full access" do
      engine.sandbox(vars: ["x"])
      engine.unsandbox
      result = engine.render_string("{{ name }}", { "name" => "Alice" })
      expect(result).to eq("Alice")
    end
  end

  # ===========================================================================
  # Fragment Caching
  # ===========================================================================

  describe "fragment caching" do
    it "caches rendered content" do
      # Render first time with counter = 1
      template = '{% cache "test" 60 %}{{ counter }}{% endcache %}'
      result1 = engine.render_string(template, { "counter" => 1 })
      expect(result1).to eq("1")

      # Render second time with counter = 2, should still get cached value
      result2 = engine.render_string(template, { "counter" => 2 })
      expect(result2).to eq("1")
    end
  end

  # ===========================================================================
  # Custom Tests
  # ===========================================================================

  describe "custom tests" do
    it "registers and uses custom test" do
      engine.add_test("positive") { |v| v.is_a?(Numeric) && v > 0 }
      template = "{% if x is positive %}yes{% else %}no{% endif %}"
      expect(engine.render_string(template, { "x" => 5 })).to eq("yes")
      expect(engine.render_string(template, { "x" => -1 })).to eq("no")
    end
  end

  # ===========================================================================
  # Arithmetic
  # ===========================================================================

  describe "arithmetic" do
    it "addition" do
      expect(engine.render_string("{{ 2 + 3 }}", {})).to eq("5")
    end

    it "subtraction" do
      expect(engine.render_string("{{ 10 - 4 }}", {})).to eq("6")
    end

    it "multiplication" do
      expect(engine.render_string("{{ 3 * 4 }}", {})).to eq("12")
    end

    it "division" do
      expect(engine.render_string("{{ 10 / 4 }}", {})).to eq("2.5")
    end

    it "modulo" do
      expect(engine.render_string("{{ 10 % 3 }}", {})).to eq("1")
    end
  end

  # ===========================================================================
  # API parity
  # ===========================================================================

  describe "API parity" do
    it "supports render_string" do
      expect(engine.render_string("{{ x }}", { "x" => 42 })).to eq("42")
    end

    it "supports add_filter" do
      engine.add_filter("exclaim") { |v| "#{v}!" }
      expect(engine.render_string("{{ text | exclaim }}", { "text" => "wow" })).to eq("wow!")
    end

    it "supports add_global" do
      engine.add_global("version", "1.0")
      expect(engine.render_string("v{{ version }}", {})).to eq("v1.0")
    end

    it "supports sandbox and unsandbox" do
      engine.sandbox(filters: ["upper", "lower"], vars: ["name"])
      engine.unsandbox
      # Should not raise
    end
  end

  # ===========================================================================
  # Edge cases
  # ===========================================================================

  describe "edge cases" do
    it "handles empty template" do
      expect(engine.render_string("", {})).to eq("")
    end

    it "handles template with only text" do
      expect(engine.render_string("Hello World", {})).to eq("Hello World")
    end

    it "handles multiple variables on one line" do
      data = { "a" => "1", "b" => "2" }
      expect(engine.render_string("{{ a }}-{{ b }}", data)).to eq("1-2")
    end

    it "handles nil in default filter" do
      expect(engine.render_string("{{ x | default('fallback') }}", {})).to eq("fallback")
    end

    it "renders array literal" do
      template = "{% set items = [1, 2, 3] %}{{ items | join(', ') }}"
      expect(engine.render_string(template, {})).to eq("1, 2, 3")
    end
  end

  # ===========================================================================
  # Form Token
  # ===========================================================================

  describe "form_token" do
    it "renders a hidden input with JWT via {{ form_token() }}" do
      result = engine.render_string("{{ form_token() | raw }}", {})
      expect(result).to include('<input type="hidden" name="formToken" value="')
      # Extract JWT and verify structure
      token = result.match(/value="([^"]+)"/)[1]
      parts = token.split(".")
      expect(parts.length).to eq(3)
    end

    it "renders via form_token filter {{ '' | form_token }}" do
      result = engine.render_string('{{ "" | form_token | raw }}', {})
      expect(result).to include('<input type="hidden" name="formToken" value="')
    end

    it "generates a valid JWT that Auth can validate" do
      result = engine.render_string("{{ form_token() | raw }}", {})
      token = result.match(/value="([^"]+)"/)[1]
      validated = Tina4::Auth.validate_token(token)
      expect(validated[:valid]).to be true
      expect(validated[:payload]["type"]).to eq("form")
    end

    it "supports descriptor to add context" do
      result = engine.render_string('{{ "admin" | form_token | raw }}', {})
      token = result.match(/value="([^"]+)"/)[1]
      payload = Tina4::Auth.get_payload(token)
      expect(payload["type"]).to eq("form")
      expect(payload["context"]).to eq("admin")
    end
  end

  # ===========================================================================
  # Raw Block
  # ===========================================================================

  describe "raw block" do
    it "preserves var syntax" do
      expect(engine.render_string('{% raw %}{{ name }}{% endraw %}', { "name" => "Alice" })).to eq("{{ name }}")
    end

    it "preserves block syntax" do
      expect(engine.render_string('{% raw %}{% if true %}yes{% endif %}{% endraw %}', {})).to eq("{% if true %}yes{% endif %}")
    end

    it "mixes raw and normal" do
      result = engine.render_string('Hello {{ name }}! {% raw %}{{ not_parsed }}{% endraw %} done', { "name" => "World" })
      expect(result).to eq("Hello World! {{ not_parsed }} done")
    end

    it "handles multiple raw blocks" do
      result = engine.render_string('{% raw %}{{ a }}{% endraw %} mid {% raw %}{{ b }}{% endraw %}', {})
      expect(result).to eq("{{ a }} mid {{ b }}")
    end

    it "handles multiline raw block" do
      src = "{% raw %}\n{{ var }}\n{% tag %}\n{% endraw %}"
      expect(engine.render_string(src, {})).to eq("\n{{ var }}\n{% tag %}\n")
    end
  end

  # ===========================================================================
  # From Import
  # ===========================================================================

  describe "from import" do
    let(:tpl_dir_import) { Dir.mktmpdir("frond_import_test") }
    let(:import_engine) { Tina4::Frond.new(template_dir: tpl_dir_import) }

    after do
      FileUtils.rm_rf(tpl_dir_import)
    end

    it "imports a basic macro" do
      File.write(File.join(tpl_dir_import, "macros.twig"), '{% macro greeting(name) %}Hello {{ name }}!{% endmacro %}')
      result = import_engine.render_string('{% from "macros.twig" import greeting %}{{ greeting("World") }}', {})
      expect(result).to eq("Hello World!")
    end

    it "imports multiple macros" do
      File.write(File.join(tpl_dir_import, "helpers.twig"), '{% macro bold(t) %}B{{ t }}B{% endmacro %}{% macro italic(t) %}I{{ t }}I{% endmacro %}')
      result = import_engine.render_string('{% from "helpers.twig" import bold, italic %}{{ bold("hi") }} {{ italic("there") }}', {})
      expect(result).to include("BhiB")
      expect(result).to include("IthereI")
    end

    it "imports selectively" do
      File.write(File.join(tpl_dir_import, "mix.twig"), '{% macro used(x) %}[{{ x }}]{% endmacro %}{% macro unused(x) %}{{{ x }}}{% endmacro %}')
      result = import_engine.render_string('{% from "mix.twig" import used %}{{ used("ok") }}', {})
      expect(result).to include("[ok]")
    end

    it "imports from subdirectory" do
      subdir = File.join(tpl_dir_import, "macros")
      FileUtils.mkdir_p(subdir)
      File.write(File.join(subdir, "forms.twig"), '{% macro field(label, name) %}{{ label }}:{{ name }}{% endmacro %}')
      result = import_engine.render_string('{% from "macros/forms.twig" import field %}{{ field("Name", "name") }}', {})
      expect(result).to include("Name:name")
    end
  end

  # ===========================================================================
  # Spaceless
  # ===========================================================================

  describe "spaceless tag" do
    it "removes whitespace between HTML tags" do
      result = engine.render_string("{% spaceless %}<div>  <p>  Hello  </p>  </div>{% endspaceless %}", {})
      expect(result).to eq("<div><p>  Hello  </p></div>")
    end

    it "preserves content whitespace" do
      result = engine.render_string("{% spaceless %}<span>  text  </span>{% endspaceless %}", {})
      expect(result).to eq("<span>  text  </span>")
    end

    it "handles multiline content" do
      src = "{% spaceless %}\n<div>\n    <p>Hi</p>\n</div>\n{% endspaceless %}"
      result = engine.render_string(src, {})
      expect(result).to include("<div><p>")
      expect(result).to include("</p></div>")
    end

    it "works with variables" do
      result = engine.render_string("{% spaceless %}<div>  <span>{{ name }}</span>  </div>{% endspaceless %}", { "name" => "Alice" })
      expect(result).to eq("<div><span>Alice</span></div>")
    end
  end

  # ===========================================================================
  # Autoescape
  # ===========================================================================

  describe "autoescape tag" do
    it "disables escaping when false" do
      result = engine.render_string('{% autoescape false %}{{ html }}{% endautoescape %}', { "html" => "<b>bold</b>" })
      expect(result).to eq("<b>bold</b>")
    end

    it "keeps escaping when true" do
      result = engine.render_string('{% autoescape true %}{{ html }}{% endautoescape %}', { "html" => "<b>bold</b>" })
      expect(result).to include("&lt;b&gt;")
    end

    it "works with filters when false" do
      result = engine.render_string('{% autoescape false %}{{ name | upper }}{% endautoescape %}', { "name" => "alice" })
      expect(result).to eq("ALICE")
    end

    it "handles multiple variables when false" do
      result = engine.render_string('{% autoescape false %}{{ a }} {{ b }}{% endautoescape %}', { "a" => "<i>x</i>", "b" => "<b>y</b>" })
      expect(result).to eq("<i>x</i> <b>y</b>")
    end
  end

  # ===========================================================================
  # Inline If
  # ===========================================================================

  describe "inline if expression" do
    it "evaluates true branch" do
      # Inline if with single-quoted string literals is escaped by auto-escaping before expression eval
      result = engine.render_string("{{ 'yes' if active else 'no' }}", { "active" => true })
      expect(result).to include("yes")
    end

    it "evaluates false branch" do
      result = engine.render_string("{{ 'yes' if active else 'no' }}", { "active" => false })
      expect(result).to include("no")
    end

    it "works with variable values" do
      result = engine.render_string("{{ name if name else 'Anonymous' }}", { "name" => "Alice" })
      expect(result).to eq("Alice")
    end

    it "falls back on missing variable" do
      result = engine.render_string("{{ name if name else 'Anonymous' }}", {})
      expect(result).to eq("Anonymous")
    end

    it "works with comparison condition" do
      result = engine.render_string("{{ 'adult' if age >= 18 else 'minor' }}", { "age" => 21 })
      expect(result).to include("adult")
    end

    it "works with numeric values" do
      result = engine.render_string("{{ count if count else 0 }}", { "count" => 5 })
      expect(result).to eq("5")
    end
  end

  # ===========================================================================
  # Token Pre-Compilation (Cache)
  # ===========================================================================

  describe "token cache" do
    it "render_string produces same output on second call (cached)" do
      src = "Hello {{ name }}!"
      first = engine.render_string(src, { "name" => "World" })
      second = engine.render_string(src, { "name" => "World" })
      expect(first).to eq("Hello World!")
      expect(second).to eq(first)
    end

    it "cached tokens work with different data" do
      src = "{{ greeting }}, {{ name }}!"
      r1 = engine.render_string(src, { "greeting" => "Hi", "name" => "Alice" })
      r2 = engine.render_string(src, { "greeting" => "Bye", "name" => "Bob" })
      expect(r1).to eq("Hi, Alice!")
      expect(r2).to eq("Bye, Bob!")
    end

    it "file render produces same output on second call (cached)" do
      Dir.mktmpdir do |dir|
        e = Tina4::Frond.new(template_dir: dir)
        File.write(File.join(dir, "cached.html"), "<p>{{ msg }}</p>")
        first = e.render("cached.html", { "msg" => "hello" })
        second = e.render("cached.html", { "msg" => "hello" })
        expect(first).to eq("<p>hello</p>")
        expect(second).to eq(first)
      end
    end

    it "cached file tokens work with different data" do
      Dir.mktmpdir do |dir|
        e = Tina4::Frond.new(template_dir: dir)
        File.write(File.join(dir, "cached2.html"), "{{ x }} + {{ y }}")
        r1 = e.render("cached2.html", { "x" => 1, "y" => 2 })
        r2 = e.render("cached2.html", { "x" => 10, "y" => 20 })
        expect(r1).to eq("1 + 2")
        expect(r2).to eq("10 + 20")
      end
    end

    it "cache invalidates on file change in dev mode" do
      Dir.mktmpdir do |dir|
        ENV["TINA4_DEBUG"] = "true"
        begin
          e = Tina4::Frond.new(template_dir: dir)
          path = File.join(dir, "changing.html")
          File.write(path, "Version 1: {{ v }}")
          r1 = e.render("changing.html", { "v" => "a" })
          expect(r1).to eq("Version 1: a")

          sleep 0.05
          File.write(path, "Version 2: {{ v }}")
          r2 = e.render("changing.html", { "v" => "b" })
          expect(r2).to eq("Version 2: b")
        ensure
          ENV.delete("TINA4_DEBUG")
        end
      end
    end

    it "clear_cache empties both caches" do
      engine.render_string("{{ x }}", { "x" => 1 })
      engine.clear_cache
      # After clearing, rendering still works (re-tokenizes)
      result = engine.render_string("{{ x }}", { "x" => 2 })
      expect(result).to eq("2")
    end

    it "for loop works correctly from cache" do
      src = "{% for i in items %}{{ i }},{% endfor %}"
      data = { "items" => [1, 2, 3] }
      first = engine.render_string(src, data)
      second = engine.render_string(src, data)
      expect(first).to eq("1,2,3,")
      expect(second).to eq(first)
    end

    it "conditionals work correctly from cache" do
      src = "{% if show %}visible{% else %}hidden{% endif %}"
      r1 = engine.render_string(src, { "show" => true })
      r2 = engine.render_string(src, { "show" => false })
      expect(r1).to eq("visible")
      expect(r2).to eq("hidden")
    end
  end
end
