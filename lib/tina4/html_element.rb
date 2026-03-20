# frozen_string_literal: true

module Tina4
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
          escaped = value.to_s
            .gsub("&", "&amp;")
            .gsub('"', "&quot;")
            .gsub("<", "&lt;")
            .gsub(">", "&gt;")
          html << " #{key}=\"#{escaped}\""
        end
      end

      if VOID_TAGS.include?(@tag)
        html << ">"
        return html
      end

      html << ">"

      @children.each do |child|
        html << child.to_s
      end

      html << "</#{@tag}>"
      html
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
end
