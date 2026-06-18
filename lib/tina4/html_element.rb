# frozen_string_literal: true

module Tina4
  # Marker for trusted, pre-sanitised HTML that must render UNESCAPED.
  #
  # String/scalar children of an HtmlElement are HTML-escaped by default to
  # prevent stored/reflected XSS. Wrap a value in Raw to opt out of escaping
  # when (and only when) you have already sanitised it yourself.
  #
  #   Tina4::HtmlElement.new("div").call("<b>x</b>")             # &lt;b&gt;x&lt;/b&gt;  (escaped)
  #   Tina4::HtmlElement.new("div").call(Tina4::Raw.new("<b>x</b>"))  # <b>x</b>         (raw)
  #
  # Raw is the primary name; SafeString is the alias (and is the same class
  # Frond already uses to mark trusted output, so a SafeString returned by a
  # Frond filter also renders raw as an HtmlElement child). Defined defensively
  # in case this file is ever loaded before Frond.
  SafeString = Class.new(String) unless defined?(Tina4::SafeString)

  # Primary name for the trusted-markup wrapper — an alias of SafeString.
  Raw = SafeString

  # Convenience constructor so callers can write Tina4::Raw("<b>x</b>")
  # in addition to Tina4::Raw.new("<b>x</b>").
  def self.Raw(value)
    Raw.new(value.to_s)
  end

  # Programmatic HTML builder — avoids string concatenation.
  #
  # Usage:
  #   el = Tina4::HtmlElement.new("div", { class: "card" }, ["Hello"])
  #   el.to_s  # => '<div class="card">Hello</div>'
  #
  #   # Builder pattern (via call)
  #   el = Tina4::HtmlElement.new("div").call(Tina4::HtmlElement.new("p").call("Text"))
  #
  #   # Helper functions
  #   include Tina4::HtmlHelpers
  #   html = _div({ class: "card" }, _p("Hello"))
  #
  # String/scalar children are HTML-escaped by default to defeat XSS; nested
  # HtmlElement children render themselves (already escaped, no double-escape);
  # a Raw / SafeString child renders verbatim (explicit opt-in for trusted markup).
  class HtmlElement
    VOID_TAGS = %w[
      area base br col embed hr img input
      link meta param source track wbr
    ].freeze

    HTML_TAGS = %w[
      a abbr address area article aside audio
      b base bdi bdo blockquote body br button
      canvas caption cite code col colgroup
      data datalist dd del details dfn dialog div dl dt
      em embed
      fieldset figcaption figure footer form
      h1 h2 h3 h4 h5 h6 head header hgroup hr html
      i iframe img input ins
      kbd
      label legend li link
      main map mark menu meta meter
      nav noscript
      object ol optgroup option output
      p param picture pre progress
      q
      rp rt ruby
      s samp script section select slot small source span
      strong style sub summary sup
      table tbody td template textarea tfoot th thead time
      title tr track
      u ul
      var video
      wbr
    ].freeze

    attr_reader :tag, :attrs, :children

    # @param tag      [String] HTML tag name
    # @param attrs    [Hash]   attribute => value
    # @param children [Array]  child elements (strings or HtmlElement instances)
    def initialize(tag, attrs = {}, children = [])
      @tag = tag.to_s.downcase
      @attrs = attrs
      @children = children
    end

    # Builder pattern — appends children and/or merges attributes.
    #
    # @param args [Array] Strings, HtmlElements, Hashes (treated as attrs), or Arrays
    # @return [HtmlElement] a new HtmlElement with the appended children
    def call(*args)
      new_attrs = @attrs.dup
      new_children = @children.dup

      args.each do |arg|
        case arg
        when Hash
          new_attrs = new_attrs.merge(arg)
        when Array
          new_children.concat(arg)
        else
          new_children << arg
        end
      end

      self.class.new(@tag, new_attrs, new_children)
    end

    # Render to HTML string.
    def to_s
      html = "<#{@tag}"

      @attrs.each do |key, value|
        case value
        when true
          html << " #{key}"
        when false, nil
          next
        else
          html << " #{key}=\"#{escape_text(value.to_s)}\""
        end
      end

      if VOID_TAGS.include?(@tag)
        html << ">"
        return html
      end

      html << ">"

      @children.each do |child|
        case child
        when HtmlElement
          # Nested elements render themselves (they already escape their own
          # children) — emit as-is to avoid double-escaping.
          html << child.to_s
        when Raw
          # Explicitly trusted markup — emit unescaped. Raw subclasses String,
          # so this branch MUST come before the generic scalar escape below.
          html << child.to_s
        else
          # Plain string/scalar child — escape to defeat stored/reflected XSS.
          html << escape_text(child.to_s)
        end
      end

      html << "</#{@tag}>"
      html
    end

    private

    # HTML-escape a string for safe inclusion in text content or a
    # double-quoted attribute value. Mirrors Python's html.escape(quote=True):
    # & < > " ' are all encoded.
    def escape_text(value)
      value
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub('"', "&quot;")
        .gsub("'", "&#x27;")
    end
  end

  # Module providing _div, _p, _span, etc. helper methods.
  # Include in any class or use extend on a module.
  module HtmlHelpers
    HtmlElement::HTML_TAGS.each do |tag|
      define_method("_#{tag}") do |*args|
        attrs = {}
        children = []

        args.each do |arg|
          case arg
          when Hash
            attrs = attrs.merge(arg)
          when Array
            children.concat(arg)
          when HtmlElement
            children << arg
          else
            children << arg
          end
        end

        HtmlElement.new(tag, attrs, children)
      end
    end
  end

  # Module-level convenience: Tina4.html_helpers returns a module you can include.
  def self.html_helpers
    HtmlHelpers
  end

  # Inject _div(), _p(), _a(), etc. helper methods into the given namespace (hash or object).
  #
  # Usage:
  #   h = {}
  #   Tina4.add_html_helpers(h)
  #   h[:_div].call({ class: "card" }, h[:_p].call("Hello"))
  #
  def self.add_html_helpers(namespace)
    helper = Object.new.extend(HtmlHelpers)

    HtmlElement::HTML_TAGS.each do |tag|
      name = "_#{tag}"
      fn = helper.method(name.to_sym)

      if namespace.is_a?(Hash)
        namespace[name.to_sym] = fn
      else
        namespace.define_singleton_method(name.to_sym, &fn)
      end
    end
  end
end
