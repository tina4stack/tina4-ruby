# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::HtmlElement do
  # -- Basic rendering --------------------------------------------------------

  it "renders a simple element" do
    el = described_class.new("div", { class: "card" }, ["Hello"])
    expect(el.to_s).to eq('<div class="card">Hello</div>')
  end

  it "renders an empty element" do
    el = described_class.new("div")
    expect(el.to_s).to eq("<div></div>")
  end

  it "renders multiple children" do
    el = described_class.new("ul", {}, [
      described_class.new("li", {}, ["One"]),
      described_class.new("li", {}, ["Two"]),
    ])
    expect(el.to_s).to eq("<ul><li>One</li><li>Two</li></ul>")
  end

  # -- Void tags --------------------------------------------------------------

  it "renders void tags without closing tag" do
    el = described_class.new("br")
    expect(el.to_s).to eq("<br>")
  end

  it "renders void tags with attributes" do
    el = described_class.new("img", { src: "photo.jpg", alt: "A photo" })
    expect(el.to_s).to eq('<img src="photo.jpg" alt="A photo">')
  end

  it "renders input as void tag" do
    el = described_class.new("input", { type: "text", name: "q" })
    expect(el.to_s).to eq('<input type="text" name="q">')
  end

  # -- Attribute handling -----------------------------------------------------

  it "renders boolean true as standalone attribute" do
    el = described_class.new("input", { disabled: true, type: "text" })
    expect(el.to_s).to eq('<input disabled type="text">')
  end

  it "omits boolean false attributes" do
    el = described_class.new("input", { disabled: false, type: "text" })
    expect(el.to_s).to eq('<input type="text">')
  end

  it "omits nil attributes" do
    el = described_class.new("div", { id: nil, class: "x" })
    expect(el.to_s).to eq('<div class="x"></div>')
  end

  it "escapes attribute values" do
    el = described_class.new("a", { href: "/search?q=a&b=c", title: 'say "hi"' })
    html = el.to_s
    expect(html).to include('href="/search?q=a&amp;b=c"')
    expect(html).to include('title="say &quot;hi&quot;"')
  end

  # -- Builder pattern (call) -------------------------------------------------

  it "appends children via call" do
    el = described_class.new("div")
    el2 = el.call("Hello", " ", "World")
    expect(el2.to_s).to eq("<div>Hello World</div>")
  end

  it "nests elements via call" do
    el = described_class.new("div").call(
      described_class.new("p").call("Text")
    )
    expect(el.to_s).to eq("<div><p>Text</p></div>")
  end

  it "merges attributes via call with Hash argument" do
    el = described_class.new("div", { class: "a" })
    el2 = el.call({ id: "main" }, "Content")
    expect(el2.to_s).to eq('<div class="a" id="main">Content</div>')
  end

  it "does not mutate the original element" do
    el = described_class.new("div")
    el.call("child")
    expect(el.to_s).to eq("<div></div>")
  end

  # -- XSS escaping (lock-in) -------------------------------------------------

  it "escapes a plain string child (defeats XSS)" do
    el = described_class.new("div").call("<script>alert(1)</script>")
    html = el.to_s
    expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    expect(html).not_to include("<script>")
  end

  it "escapes a plain string child passed via the children array" do
    el = described_class.new("div", {}, ["<script>alert(1)</script>"])
    html = el.to_s
    expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    expect(html).not_to include("<script>")
  end

  it "renders a Raw child unescaped (explicit opt-in)" do
    el = described_class.new("div").call(Tina4::Raw.new("<b>x</b>"))
    expect(el.to_s).to eq("<div><b>x</b></div>")
  end

  it "renders a Tina4.Raw(...) child unescaped" do
    el = described_class.new("div").call(Tina4.Raw("<b>x</b>"))
    expect(el.to_s).to eq("<div><b>x</b></div>")
  end

  it "renders a SafeString alias child unescaped" do
    el = described_class.new("div").call(Tina4::SafeString.new("<b>x</b>"))
    expect(el.to_s).to eq("<div><b>x</b></div>")
  end

  it "Raw and SafeString are the same class" do
    expect(Tina4::Raw).to equal(Tina4::SafeString)
  end

  it "renders a nested element child as-is (no double-escape)" do
    el = described_class.new("div").call(
      described_class.new("p").call("<b>safe</b>")
    )
    # The nested <p> tag itself is emitted as-is; its string child is escaped once.
    expect(el.to_s).to eq("<div><p>&lt;b&gt;safe&lt;/b&gt;</p></div>")
  end

  it "handles mixed escaped, raw, and nested children" do
    el = described_class.new("div").call(
      "<i>plain</i>",
      Tina4::Raw.new("<b>raw</b>"),
      described_class.new("span").call("kid")
    )
    expect(el.to_s).to eq(
      "<div>&lt;i&gt;plain&lt;/i&gt;<b>raw</b><span>kid</span></div>"
    )
  end

  it "escapes an attribute value containing a quote" do
    el = described_class.new("a", { title: 'say "hi"' })
    expect(el.to_s).to include('title="say &quot;hi&quot;"')
  end

  it "escapes an attribute value containing a less-than sign" do
    el = described_class.new("div", { "data-x" => "<script>" })
    html = el.to_s
    expect(html).to include('data-x="&lt;script&gt;"')
    expect(html).not_to include("data-x=\"<script>")
  end
end

RSpec.describe Tina4::HtmlHelpers do
  include Tina4::HtmlHelpers

  it "provides _div helper" do
    el = _div({ class: "card" }, "Hello")
    expect(el.to_s).to eq('<div class="card">Hello</div>')
  end

  it "provides _p helper" do
    el = _p("Text")
    expect(el.to_s).to eq("<p>Text</p>")
  end

  it "supports nested helpers" do
    el = _div({ class: "card" }, _p("Hello"))
    expect(el.to_s).to eq('<div class="card"><p>Hello</p></div>')
  end

  it "provides void tag helpers" do
    el = _br
    expect(el.to_s).to eq("<br>")
  end

  it "provides _a helper with attributes" do
    el = _a({ href: "/" }, "Home")
    expect(el.to_s).to eq('<a href="/">Home</a>')
  end

  it "builds complex nested HTML" do
    html = _div({ class: "nav" }, _a({ href: "/" }, "Home"))
    expect(html.to_s).to eq('<div class="nav"><a href="/">Home</a></div>')
  end

  # -- add_html_helpers --------------------------------------------------------

  it "injects helpers into a hash that produce correct HTML" do
    h = {}
    Tina4.add_html_helpers(h)
    # Don't just assert the keys exist — invoke the injected helpers and assert
    # they actually build the right markup (the keys hold callable Method
    # objects, so .call(...) exercises the real helper behaviour).
    expect(h[:_div].call({ class: "card" }, "Hello").to_s).to eq('<div class="card">Hello</div>')
    expect(h[:_p].call("Text").to_s).to eq("<p>Text</p>")
    expect(h[:_span].call("hi").to_s).to eq("<span>hi</span>")
  end

  it "hash helpers produce correct HTML" do
    h = {}
    Tina4.add_html_helpers(h)
    el = h[:_div].call({ class: "card" }, h[:_p].call("Hello"))
    expect(el.to_s).to eq('<div class="card"><p>Hello</p></div>')
  end

  it "injects helpers into an object" do
    obj = Object.new
    Tina4.add_html_helpers(obj)
    expect(obj).to respond_to(:_div)
    el = obj._div({ class: "test" }, "Hi")
    expect(el.to_s).to eq('<div class="test">Hi</div>')
  end
end
