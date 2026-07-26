# frozen_string_literal: true

# {% import "file" as alias %} — load every macro in a file under one namespace.
#
# Ruby did not implement this tag at all: it was silently ignored and
# {{ m.greet("Andre") }} rendered as EMPTY — worse than an error, because a template
# using it fails with no signal. Two things were missing:
#
#   1. no handle_import_as / IMPORT_AS_RE and no "import" branch in the tag dispatch
#   2. FUNC_CALL_RE was /\A(\w+)\s*\((.*)\)\z/ — a dot is not \w, so "m.greet(...)"
#      was never even recognised as a function call
#
# Macros are now registered under the dotted key "alias.name" and FUNC_CALL_RE admits
# a dot, so an aliased call goes through the ordinary function-call path and reuses
# _make_macro_fn — identical argument binding, defaults and SafeString output.
#
# Every expectation was verified against a real Python render of the same templates
# (Python is the reference implementation), so all four frameworks agree byte-for-byte.
#
# No mocks: real .twig files in a real temp dir through the real engine.

require "spec_helper"
require "tmpdir"

RSpec.describe "Frond {% import as %}" do
  around(:each) do |example|
    Dir.mktmpdir("frond_import_as") do |dir|
      @dir = dir
      File.write(File.join(dir, "macros.twig"),
                 "{% macro greet(name, greeting='Hello') %}<p>{{ greeting }}, {{ name }}!</p>{% endmacro %}" \
                 "{% macro shout(w) %}<b>{{ w }}</b>{% endmacro %}" \
                 "{% macro three(a, b, c) %}[{{ a }}|{{ b }}|{{ c }}]{% endmacro %}")
      example.run
    end
  end

  def render(source, name: "t.twig")
    File.write(File.join(@dir, name), source)
    Tina4::Frond.new(template_dir: @dir).render(name, {})
  end

  # ---------------------------------------------------------------- positive

  it "passes the argument to the aliased macro" do
    expect(render('{% import "macros.twig" as m %}{{ m.greet("Andre") }}'))
      .to eq("<p>Hello, Andre!</p>")
  end

  it "honours a second argument" do
    expect(render('{% import "macros.twig" as m %}{{ m.greet("Ann","Yo") }}'))
      .to eq("<p>Yo, Ann!</p>")
  end

  it "does not shift arguments across three parameters" do
    expect(render('{% import "macros.twig" as m %}{{ m.three(1, 2, 3) }}'))
      .to eq("[1|2|3]")
  end

  it "exposes every macro in the imported file" do
    expect(render('{% import "macros.twig" as m %}{{ m.shout("x") }}{{ m.greet("Z") }}'))
      .to eq("<b>x</b><p>Hello, Z!</p>")
  end

  it "renders identically to {% from import %}" do
    as_out   = render('{% import "macros.twig" as m %}{{ m.greet("Andre") }}', name: "cmp_as.twig")
    from_out = render('{% from "macros.twig" import greet %}{{ greet("Andre") }}', name: "cmp_from.twig")
    expect(as_out).to eq(from_out)
  end

  # ---------------------------------------------------------------- negative

  it "does not render empty (the pre-implementation behaviour)" do
    out = render('{% import "macros.twig" as m %}{{ m.greet("Andre") }}', name: "neg1.twig")
    expect(out).not_to eq(""), "the import tag was silently ignored"
    expect(out).to include("Andre")
  end

  it "never leaks a namespace object or address into the output" do
    out = render('{% import "macros.twig" as m %}{{ m.greet("Andre") }}', name: "neg2.twig")
    expect(out).not_to include("Namespace")
    expect(out).not_to match(/0x[0-9a-f]+/)
  end

  it "stays silent on a malformed import tag instead of crashing" do
    expect(render('{% import "macros.twig" %}after', name: "bad.twig")).to eq("after")
  end
end
