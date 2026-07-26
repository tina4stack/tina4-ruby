# frozen_string_literal: true

# Lock-in specs for the bound on Frond's template caches (ADR-0004).
#
# @compiled (file templates) and @compiled_strings (render_string) were plain
# unbounded Hashes. Each entry is a whole token list, and render_string keys on
# md5(source), so an app that builds template strings dynamically grew them for
# the life of the worker.
#
# Reproduced for real below: real renders through the real engine, real
# template files on disk, and the real instance caches read directly. The bound
# must never cost correctness -- an evicted template re-tokenizes.
#
# No mocks: nothing here stands in for the engine or the filesystem.

require_relative "spec_helper"
require_relative "../lib/tina4/frond"
require "tmpdir"
require "fileutils"

RSpec.describe Tina4::Frond do
  describe "template cache bound (ADR-0004)" do
    let(:cap) { Tina4::Frond::TEMPLATE_CACHE_MAX }
    let(:template_dir) { Dir.mktmpdir("frond-template-cache") }
    let(:engine) { Tina4::Frond.new(template_dir: template_dir) }

    after do
      FileUtils.remove_entry(template_dir) if File.directory?(template_dir)
    end

    def write_template(name, contents)
      File.write(File.join(template_dir, name), contents)
      name
    end

    it "caps at a positive number of entries" do
      expect(cap).to be > 0
    end

    # render_string keys on md5(source), so dynamically-built template strings
    # must not grow the cache without limit.
    it "does not grow @compiled_strings without limit for dynamic sources" do
      distinct = (cap * 2) + 13

      distinct.times do |index|
        rendered = engine.render_string("t#{index}={{ n + #{index} }}", { "n" => 10 })
        expect(rendered).to eq("t#{index}=#{10 + index}")
      end

      size = engine.instance_variable_get(:@compiled_strings).size
      expect(size).to be <= cap,
                      "compiled_strings grew to #{size} entries for #{distinct} distinct sources; cap is #{cap}"
    end

    # The bound must not cost correctness: an evicted source re-tokenizes and
    # renders the same bytes, and still tracks the data (never a stale result).
    it "re-tokenizes an evicted string template and stays correct" do
      first_source = "first={{ n + 1 }}"
      expect(engine.render_string(first_source, { "n" => 10 })).to eq("first=11")

      (cap * 2).times { |index| engine.render_string("filler#{index}={{ n }}", { "n" => index }) }

      keys = engine.instance_variable_get(:@compiled_strings).keys
      expect(keys).not_to include(Digest::MD5.hexdigest(first_source)),
                          "the first entry should have been evicted"

      expect(engine.render_string(first_source, { "n" => 10 })).to eq("first=11")
      expect(engine.render_string(first_source, { "n" => 100 })).to eq("first=101")
    end

    it "does not grow @compiled without limit for distinct template files" do
      distinct = cap + 41

      distinct.times { |index| write_template("tpl#{index}.twig", "T#{index}={{ n + #{index} }}") }

      distinct.times do |index|
        expect(engine.render("tpl#{index}.twig", { "n" => 5 })).to eq("T#{index}=#{5 + index}")
      end

      size = engine.instance_variable_get(:@compiled).size
      expect(size).to be <= cap,
                      "compiled grew to #{size} entries for #{distinct} distinct templates; cap is #{cap}"

      # Every template still renders correctly after the sweep, including the
      # earliest ones, which were evicted and must re-read from disk.
      distinct.times do |index|
        expect(engine.render("tpl#{index}.twig", { "n" => 7 })).to eq("T#{index}=#{7 + index}")
      end
    end

    # Negative control: the cap must not fire EARLY.
    it "evicts nothing while the cache is under the cap" do
      below_cap = cap - 1
      below_cap.times { |index| engine.render_string("u#{index}={{ n }}", { "n" => index }) }

      expect(engine.instance_variable_get(:@compiled_strings).size).to eq(below_cap)
    end

    it "still empties every template cache on clear_cache" do
      write_template("page.twig", "page={{ n }}")
      expect(engine.render("page.twig", { "n" => 3 })).to eq("page=3")
      expect(engine.render_string("str={{ n }}", { "n" => 4 })).to eq("str=4")

      expect(engine.instance_variable_get(:@compiled)).not_to be_empty
      expect(engine.instance_variable_get(:@compiled_strings)).not_to be_empty

      engine.clear_cache

      expect(engine.instance_variable_get(:@compiled)).to be_empty
      expect(engine.instance_variable_get(:@compiled_strings)).to be_empty

      # Still renders correctly from cold after a clear.
      expect(engine.render("page.twig", { "n" => 3 })).to eq("page=3")
      expect(engine.render_string("str={{ n }}", { "n" => 4 })).to eq("str=4")
    end

    # Template inheritance re-reads the parent from disk rather than the token
    # cache, so an eviction storm must never break an {% extends %} chain.
    it "keeps inheritance rendering across an eviction storm" do
      write_template("base.twig", "BASE[{% block body %}dflt{% endblock %}]")
      write_template("child.twig", '{% extends "base.twig" %}{% block body %}{{ n * 2 }}{% endblock %}')

      expect(engine.render("child.twig", { "n" => 4 })).to eq("BASE[8]")

      (cap * 2).times { |index| engine.render_string("storm#{index}={{ n }}", { "n" => index }) }

      expect(engine.render("child.twig", { "n" => 4 })).to eq("BASE[8]")
      expect(engine.render("child.twig", { "n" => 10 })).to eq("BASE[20]")
    end
  end
end
