# frozen_string_literal: true

require "tina4/frond"

# Frond auto-escaping + sandbox hardening -- F4, F5, F6, F7 (ADR-0077).
# Real renders, inert markup, mutation-proved.
RSpec.describe "Frond escaping hardening" do
  let(:f) { Tina4::Frond.new }

  it "escapes list/hash/object output (F4)" do
    expect(f.render_string("{{ items }}", { "items" => ["<b>x</b>"] })).not_to include("<b>x</b>")
    expect(f.render_string("{{ d }}", { "d" => { "a" => "<b>x</b>" } })).not_to include("<b>x</b>")
  end

  it "keeps plain strings escaped and primitives unchanged" do
    expect(f.render_string("{{ s }}", { "s" => "<b>x</b>" })).to eq("&lt;b&gt;x&lt;/b&gt;")
    expect(f.render_string("{{ n }}", { "n" => 5 })).to eq("5")
    expect(f.render_string("{{ t }}", { "t" => true })).to eq("true")
  end

  it "neutralises markup in js_escape (F5)" do
    out = f.render_string("{{ u|js_escape }}", { "u" => "</b>&'\"" })
    ["<", ">", "&", "/", "'", '"'].each { |b| expect(out).not_to include(b) }
  end

  it "honours e(url) / e(html_attr) strategies (F7)" do
    expect(f.render_string("{{ u|e('url') }}", { "u" => "a b&c/d" })).to eq("a%20b%26c%2Fd")
    expect(f.render_string("{{ u|e('html_attr') }}", { "u" => 'a"b' })).to eq("a&#x22;b")
  end

  it "raises on an unknown escape strategy" do
    expect { f.render_string("{{ u|e('bogus') }}", { "u" => "x" }) }.to raise_error(StandardError)
  end

  describe "sandbox (F6)" do
    let(:s) do
      e = Tina4::Frond.new
      e.sandbox(filters: ["upper"], tags: %w[if for set], vars: ["user"])
      e
    end

    it "blocks set/for/if from smuggling a blocked variable" do
      expect(s.render_string("{% set user = secret %}{{ user }}", { "secret" => "hunter2" })).not_to include("hunter2")
      expect(s.render_string("{% for x in [secret] %}{{ x }}{% endfor %}", { "secret" => "hunter2" })).not_to include("hunter2")
      expect(s.render_string("{% if secret == 'hunter2' %}YES{% endif %}", { "secret" => "hunter2" })).to eq("")
    end

    it "refuses reflection methods" do
      obj = Object.new
      expect(s.render_string("{{ user.class }}", { "user" => obj })).to eq("")
    end

    it "still renders an allowed variable and filter" do
      expect(s.render_string("{{ user|upper }}", { "user" => "bob" })).to eq("BOB")
    end
  end
end
