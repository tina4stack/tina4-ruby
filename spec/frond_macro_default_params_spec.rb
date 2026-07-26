# frozen_string_literal: true

# Regression: a macro parameter declared WITH a default was unusable.
#
# handle_macro / handle_from_import split the parameter list on "," only, so
# `{% macro greet(name, greeting='Hello') %}` produced a parameter literally
# NAMED "greeting='Hello'". Two things broke at once:
#
#   1. the body's {{ greeting }} matched no key    -> rendered EMPTY
#   2. a caller's positional argument was stored under that junk key -> LOST
#
#      {% macro d(a, b='B') %}[{{ a }}|{{ b }}]{% endmacro %}
#      {{ d(1) }}{{ d(1,2) }}
#      before: "[1|][1|]"      <- default gone AND the explicit 2 gone
#      after:  "[1|B][1|2]"
#
# Parameters with NO default always worked, which is why this hid for so long.
# Fixed by parse_macro_params, mirroring the Python master's
# _parse_macro_params. Python is the reference implementation; every expectation
# below was verified against a real Python render of the same template.
#
# No mocks: real template files in a real temp dir through the real engine.

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Frond macro default parameters" do
  around(:each) do |example|
    Dir.mktmpdir("frond_macro_defaults") do |dir|
      @dir = dir
      example.run
    end
  end

  def render(source, name: "t.twig", data: {})
    File.write(File.join(@dir, name), source)
    Tina4::Frond.new(template_dir: @dir).render(name, data)
  end

  # ---------------------------------------------------------------- positive

  it "applies a single-quoted default when the argument is omitted" do
    out = render("{% macro d(a, b='B') %}[{{ a }}|{{ b }}]{% endmacro %}{{ d(1) }}")
    expect(out).to eq("[1|B]")
  end

  it "applies a double-quoted default when the argument is omitted" do
    out = render('{% macro d(a, b="dq") %}[{{ a }}|{{ b }}]{% endmacro %}{{ d(1) }}')
    expect(out).to eq("[1|dq]")
  end

  it "lets an explicit argument override the default" do
    out = render("{% macro d(a, b='B') %}[{{ a }}|{{ b }}]{% endmacro %}{{ d(1,2) }}")
    expect(out).to eq("[1|2]")
  end

  it "still binds parameters that declare no default" do
    out = render("{% macro t(a, b, c) %}[{{ a }}|{{ b }}|{{ c }}]{% endmacro %}{{ t(1,2,3) }}")
    expect(out).to eq("[1|2|3]")
  end

  it "honours defaults through {% from \"file\" import %}" do
    File.write(File.join(@dir, "macros.twig"),
               "{% macro greet(name, greeting='Hello') %}" \
               "<p>{{ greeting }}, {{ name }}!</p>{% endmacro %}")
    out = render('{% from "macros.twig" import greet %}' \
                 '{{ greet("Andre") }}|{{ greet("Ann","Yo") }}',
                 name: "fromimp.twig")
    expect(out).to eq("<p>Hello, Andre!</p>|<p>Yo, Ann!</p>")
  end

  # ---------------------------------------------------------------- negative

  it "does not render an empty value where the default belongs" do
    out = render("{% macro d(a, b='B') %}[{{ a }}|{{ b }}]{% endmacro %}{{ d(1) }}")
    expect(out).not_to eq("[1|]"), "the default was dropped (pre-fix behaviour)"
    expect(out).to include("B")
  end

  it "does not silently drop an explicitly-passed argument" do
    out = render("{% macro d(a, b='B') %}[{{ a }}|{{ b }}]{% endmacro %}{{ d(1,2) }}")
    expect(out).not_to eq("[1|]"), "the explicit argument was swallowed (pre-fix behaviour)"
    expect(out).to include("2")
  end

  it "never leaks the default syntax into the rendered output" do
    out = render("{% macro d(a, b='B') %}[{{ a }}|{{ b }}]{% endmacro %}{{ d(1) }}")
    expect(out).not_to include("=")
    expect(out).not_to include("'")
  end
end
