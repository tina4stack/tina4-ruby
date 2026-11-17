# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A template global, filter or test registered through the public API reaches
# every page response.render produces, whenever it is registered (ADR-0106 for
# globals, ADR-0107 for filters and tests: they too were drained into an engine
# once, at construction).
#
# Tina4.template_global / Tina4::Template.add_global wrote only to the legacy
# Tina4::Template store, which response.render's Frond engine never reads, so
# such a global rendered EMPTY -- and the auto-wired t() was registered the same
# way. The engine also copied the Frond class globals once, when it was built
# at the first render, so a Tina4::Frond.add_global made later never reached a
# page; and t("key", {params}) raised ArgumentError. Every case renders a real
# template through a real route and the real Rack front controller
# (Tina4::TestClient). No mocks.
#
# Same case names in all four:
#   tina4-python/tests/test_frond_globals_reach_render.py
#   tina4-php/tests/FrondGlobalsReachRenderTest.php
#   tina4-nodejs/test/frondGlobalsReachRender.test.ts
RSpec.describe "Frond globals reach response.render" do
  let(:templates) do
    {
      "globals.twig" => "[{{ early }}][{{ late }}][{{ shared }}]",
      "flag.twig" => "{% if is_admin %}admin{% else %}guest{% endif %}",
      "call.twig" => '{{ shout("hi") }}',
      "filter.twig" => '{{ "hi"|loud }}',
      "test.twig" => "{% if 4 is quad %}yes{% else %}no{% endif %}",
      "greeting.twig" => '{{ t("greeting") }}',
      "welcome.twig" => '{{ t("welcome", {"name": "Ana"}) }}'
    }
  end

  around(:each) do |example|
    Dir.mktmpdir("tina4_globals_render") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src", "templates"))
      FileUtils.mkdir_p(File.join(dir, "src", "locales"))
      templates.each { |name, source| File.write(File.join(dir, "src", "templates", name), source) }
      File.write(File.join(dir, "src", "locales", "en.json"),
                 JSON.generate("greeting" => "Hello", "welcome" => "Welcome, {name}!"))
      @project_dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  before(:each) do
    Tina4::Frond.clear_registry
    Tina4::Template.instance_variable_set(:@globals, nil)
    Tina4::Localization.instance_variable_set(:@translations, {})
    Tina4::Localization.instance_variable_set(:@current_locale, nil)
    Tina4.set_frond(nil) # the next response.render builds a fresh engine
    templates.each_key do |name|
      Tina4::Router.get("/#{File.basename(name, '.twig')}") { |_request, response| response.render(name) }
    end
  end

  after(:each) do
    Tina4::Template.instance_variable_set(:@globals, nil)
    Tina4::Localization.instance_variable_set(:@translations, {})
    Tina4::Localization.instance_variable_set(:@current_locale, nil)
    Tina4.set_frond(nil)
  end

  def page(path)
    response = Tina4::TestClient.new.get(path)
    expect(response.status).to eq(200)
    response.body
  end

  # The real boot steps: Tina4.initialize! loads the locales, then auto-wires t().
  def auto_wire_i18n
    Tina4::Localization.load(@project_dir)
    Tina4.send(:autowire_i18n_template_global)
  end

  it "class global registered before first render reaches render" do
    Tina4::Frond.add_global("early", "E")
    expect(page("/globals")).to eq("[E][][]")
  end

  it "class global registered after first render reaches render" do
    expect(page("/globals")).to eq("[][][]") # the response engine now exists
    Tina4::Frond.add_global("late", "L")
    expect(page("/globals")).to eq("[][L][]")
  end

  it "template global helper reaches render" do
    expect(page("/globals")).to eq("[][][]")
    Tina4.template_global("late", "helper")
    expect(page("/globals")).to eq("[][helper][]")
  end

  it "zero arg class global registered after first render is called" do
    expect(page("/flag")).to eq("guest")
    Tina4::Frond.add_global("is_admin", -> { true }) # ADR-0085 auto-call
    expect(page("/flag")).to eq("admin")
  end

  it "callable class global registered after first render is called" do
    expect(page("/call")).to eq("")
    Tina4::Frond.add_global("shout", ->(text) { text.upcase })
    expect(page("/call")).to eq("HI")
  end

  it "auto wired t translates a key" do
    auto_wire_i18n
    expect(page("/greeting")).to eq("Hello")
  end

  it "auto wired t accepts a params map" do
    auto_wire_i18n
    expect(page("/welcome")).to eq("Welcome, Ana!")
  end

  it "auto wired t reaches every engine" do
    auto_wire_i18n
    expect(Tina4::Frond.new(template_dir: "src/templates").render("greeting.twig")).to eq("Hello")
  end

  it "auto wired t registered after first render reaches render" do
    expect(page("/globals")).to eq("[][][]")
    auto_wire_i18n
    expect(page("/greeting")).to eq("Hello")
  end

  it "instance global on another engine does not leak into render" do
    other_engine = Tina4::Frond.new(template_dir: "src/templates")
    other_engine.add_global("late", "LEAK")
    expect(page("/globals")).to eq("[][][]")
    expect(other_engine.render("globals.twig")).to eq("[][LEAK][]")
  end

  it "instance global overrides class global" do
    Tina4::Frond.add_global("shared", "class")
    expect(page("/globals")).to eq("[][][class]")
    Tina4.get_frond.add_global("shared", "instance")
    expect(page("/globals")).to eq("[][][instance]")
    expect(Tina4::Frond.new(template_dir: "src/templates").render("globals.twig")).to eq("[][][class]")
  end

  it "class filter registered before first render reaches render" do
    Tina4::Frond.add_filter("loud") { |value| value.to_s.upcase }
    expect(page("/filter")).to eq("HI")
  end

  it "class filter registered after first render reaches render" do
    expect(page("/filter")).to eq("hi") # the response engine now exists
    Tina4::Frond.add_filter("loud") { |value| value.to_s.upcase }
    expect(page("/filter")).to eq("HI")
  end

  it "class test registered before first render reaches render" do
    Tina4::Frond.add_test("quad") { |value| value == 4 }
    expect(page("/test")).to eq("yes")
  end

  it "class test registered after first render reaches render" do
    expect(page("/test")).to eq("no")
    Tina4::Frond.add_test("quad") { |value| value == 4 }
    expect(page("/test")).to eq("yes")
  end

  it "instance filter on another engine does not leak into render" do
    other_engine = Tina4::Frond.new(template_dir: "src/templates")
    other_engine.add_filter("loud") { |_value| "LEAK" }
    expect(page("/filter")).to eq("hi")
    expect(other_engine.render("filter.twig")).to eq("LEAK")
  end

  it "instance test on another engine does not leak into render" do
    other_engine = Tina4::Frond.new(template_dir: "src/templates")
    other_engine.add_test("quad") { |_value| true }
    expect(page("/test")).to eq("no")
    expect(other_engine.render("test.twig")).to eq("yes")
  end

  it "instance filter overrides class filter" do
    Tina4::Frond.add_filter("loud") { |_value| "class" }
    expect(page("/filter")).to eq("class")
    Tina4.get_frond.add_filter("loud") { |_value| "instance" }
    expect(page("/filter")).to eq("instance")
    Tina4::Frond.add_filter("loud") { |_value| "class again" } # a later class change
    expect(page("/filter")).to eq("instance")
    expect(Tina4::Frond.new(template_dir: "src/templates").render("filter.twig")).to eq("class again")
  end
end
