# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Template do
  let(:tmp_dir) { Dir.mktmpdir("tina4_tpl_test") }

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".add_global / .globals" do
    before { Tina4::Template.instance_variable_set(:@globals, nil) }

    it "stores global template variables" do
      Tina4::Template.add_global("app_name", "TestApp")
      expect(Tina4::Template.globals["app_name"]).to eq("TestApp")
    end
  end

  describe ".render" do
    it "renders a simple twig template" do
      path = File.join(tmp_dir, "hello.twig")
      File.write(path, "Hello {{ name }}!")
      result = Tina4::Template.render(path, { name: "World" })
      expect(result).to eq("Hello World!")
    end

    it "raises on missing template" do
      expect { Tina4::Template.render("nonexistent.twig") }.to raise_error(/Template not found/)
    end
  end

  describe ".render_error" do
    it "renders built-in error templates" do
      result = Tina4::Template.render_error(404)
      expect(result).to include("404")
    end
  end

  describe Tina4::Template::TwigEngine do
    def render(content, context = {})
      Tina4::Template::TwigEngine.new(context, tmp_dir).render(content)
    end

    describe "variable interpolation" do
      it "replaces variables" do
        expect(render("{{ name }}", { "name" => "Alice" })).to eq("Alice")
      end

      it "handles nested access via dot notation" do
        ctx = { "user" => { "name" => "Bob" } }
        expect(render("{{ user.name }}", ctx)).to eq("Bob")
      end

      it "renders integers and floats" do
        expect(render("{{ x }}", { "x" => 42 })).to eq("42")
      end
    end

    describe "filters" do
      it "applies upper filter" do
        expect(render("{{ name | upper }}", { "name" => "alice" })).to eq("ALICE")
      end

      it "applies lower filter" do
        expect(render("{{ name | lower }}", { "name" => "ALICE" })).to eq("alice")
      end

      it "applies capitalize filter" do
        expect(render("{{ name | capitalize }}", { "name" => "alice" })).to eq("Alice")
      end

      it "applies title filter" do
        expect(render("{{ name | title }}", { "name" => "hello world" })).to eq("Hello World")
      end

      it "applies trim filter" do
        expect(render("{{ name | trim }}", { "name" => "  hi  " })).to eq("hi")
      end

      it "applies length filter" do
        expect(render("{{ items | length }}", { "items" => [1, 2, 3] })).to eq("3")
      end

      it "applies default filter" do
        expect(render("{{ missing | default('fallback') }}", {})).to eq("fallback")
      end

      it "applies escape filter" do
        expect(render("{{ html | escape }}", { "html" => "<b>hi</b>" })).to include("&lt;b&gt;")
      end

      it "applies join filter" do
        expect(render("{{ items | join(', ') }}", { "items" => %w[a b c] })).to eq("a, b, c")
      end

      it "chains multiple filters" do
        expect(render("{{ name | trim | upper }}", { "name" => "  alice  " })).to eq("ALICE")
      end
    end

    describe "conditionals" do
      it "renders if block when true" do
        tpl = "{% if show %}visible{% endif %}"
        expect(render(tpl, { "show" => true })).to eq("visible")
      end

      it "renders else block when false" do
        tpl = "{% if show %}yes{% else %}no{% endif %}"
        expect(render(tpl, { "show" => false })).to eq("no")
      end

      it "handles comparison operators" do
        tpl = "{% if x > 5 %}big{% else %}small{% endif %}"
        expect(render(tpl, { "x" => 10 })).to eq("big")
        expect(render(tpl, { "x" => 3 })).to eq("small")
      end

      it "handles not operator" do
        tpl = "{% if not hidden %}shown{% endif %}"
        expect(render(tpl, { "hidden" => false })).to eq("shown")
      end

      it "handles and/or operators" do
        tpl = "{% if a and b %}both{% endif %}"
        expect(render(tpl, { "a" => true, "b" => true })).to eq("both")
        expect(render(tpl, { "a" => true, "b" => false })).to eq("")
      end

      it "handles is defined test" do
        tpl = "{% if x is defined %}yes{% else %}no{% endif %}"
        expect(render(tpl, { "x" => 1 })).to eq("yes")
        expect(render(tpl, {})).to eq("no")
      end

      it "handles is empty test" do
        tpl = "{% if items is empty %}none{% else %}some{% endif %}"
        expect(render(tpl, { "items" => [] })).to eq("none")
        expect(render(tpl, { "items" => [1] })).to eq("some")
      end
    end

    describe "for loops" do
      it "iterates over arrays" do
        tpl = "{% for item in items %}{{ item }} {% endfor %}"
        expect(render(tpl, { "items" => %w[a b c] })).to eq("a b c ")
      end

      it "provides loop variables" do
        tpl = "{% for item in items %}{{ loop.index }}{% endfor %}"
        expect(render(tpl, { "items" => %w[a b c] })).to eq("123")
      end

      it "provides loop.first and loop.last" do
        tpl = "{% for item in items %}{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %}{% endfor %}"
        expect(render(tpl, { "items" => %w[a b c] })).to eq("FL")
      end
    end

    describe "set tag" do
      it "sets variables" do
        tpl = "{% set greeting = 'Hello' %}{{ greeting }}"
        expect(render(tpl)).to eq("Hello")
      end
    end

    describe "extends and blocks" do
      it "supports template inheritance" do
        File.write(File.join(tmp_dir, "base.twig"), "<h1>{% block title %}Default{% endblock %}</h1>")
        child = "{% extends 'base.twig' %}{% block title %}Custom{% endblock %}"
        expect(render(child)).to eq("<h1>Custom</h1>")
      end
    end

    describe "includes" do
      it "includes partial templates" do
        File.write(File.join(tmp_dir, "partial.twig"), "Hello {{ name }}")
        tpl = "{% include 'partial.twig' %}"
        expect(render(tpl, { "name" => "World" })).to eq("Hello World")
      end
    end

    describe "comments" do
      it "strips twig comments" do
        tpl = "Hello{# this is a comment #} World"
        expect(render(tpl)).to eq("Hello World")
      end
    end

    describe "string concatenation" do
      it "supports tilde operator" do
        tpl = "{{ 'Hello' ~ ' ' ~ 'World' }}"
        expect(render(tpl)).to eq("Hello World")
      end
    end

    describe "math operations" do
      it "supports addition" do
        expect(render("{{ 2 + 3 }}")).to eq("5.0")
      end

      it "supports multiplication" do
        expect(render("{{ 4 * 5 }}")).to eq("20.0")
      end
    end
  end
end
