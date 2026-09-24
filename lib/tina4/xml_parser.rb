# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "strscan"

module Tina4
  class WSDL
    # A small, strict XML parser for SOAP request bodies (replaces REXML).
    #
    # Ported from the stack-based parser in tina4-nodejs (packages/core/src/wsdl.ts)
    # and made strict, because the Ruby WSDL server has always answered
    # "Malformed XML" for a broken body (Python's ElementTree does the same):
    # tags must nest, there is exactly one root, and only the five predefined
    # entities plus character references are understood.
    #
    # Deliberately NOT supported, so the attack surface does not exist:
    #   * DTDs. `<!DOCTYPE` and every other `<!` declaration is a ParseError, so
    #     there is no entity expansion (billion laughs) and no external entity
    #     (XXE). The WSDL server also rejects DOCTYPE before parsing.
    #   * Any encoding but UTF-8. Any byte order mark (UTF-8 included), a NUL
    #     byte, invalid UTF-8, or an XML declaration naming another encoding is a
    #     ParseError. A UTF-16 body used to slip past the `<!DOCTYPE` regex guard,
    #     because the guard read "<\0!\0D\0..." while REXML decoded the BOM and
    #     parsed the DTD.
    #
    # Element#text follows ElementTree (the Python master): the character data
    # before the first child element, entity- and CDATA-decoded; nil when there
    # is none. Element#name is the local name (prefix stripped), as REXML gave.
    module XmlParser
      class ParseError < StandardError; end

      class Element
        attr_reader :name, :prefix, :attributes, :elements

        def initialize(qualified_name, attributes)
          @prefix, _, local = qualified_name.rpartition(":")
          @prefix = nil if @prefix.empty?
          @name = local
          @attributes = attributes
          @elements = []
          @text = nil
          @seen_child = false
        end

        # Character data before the first child element (ElementTree .text).
        def text
          @text
        end

        def each_element(&block)
          @elements.each(&block)
        end

        def append_text(data) # :nodoc:
          return if @seen_child || data.empty?

          @text = @text ? @text + data : data.dup
        end

        def append_child(element) # :nodoc:
          @seen_child = true
          @elements << element
        end
      end

      Document = Struct.new(:root)

      PREDEFINED_ENTITIES = { "lt" => "<", "gt" => ">", "amp" => "&", "quot" => '"', "apos" => "'" }.freeze
      NAME = /[A-Za-z_:\u00C0-\u{EFFFF}][A-Za-z0-9_:.\-\u00B7\u00C0-\u{EFFFF}]*/
      # Every byte order mark, the UTF-8 one included (the shared SOAP body rule:
      # a body is plain UTF-8, never a BOM, in all four frameworks).
      BYTE_ORDER_MARKS = ["\xEF\xBB\xBF".b, "\xFE\xFF".b, "\xFF\xFE".b, "\x00\x00\xFE\xFF".b].freeze
      DECLARED_ENCODING = /\A<\?xml\b[^>]*?\bencoding\s*=\s*["']([^"']*)["']/

      module_function

      # Parse +xml+ (a String of any encoding tag; its BYTES must be UTF-8).
      # Returns a Document whose #root is the single root Element.
      def parse(xml)
        Reader.new(utf8_text(xml)).document
      end

      # The body as UTF-8 text, or a ParseError. Callers that must refuse BEFORE
      # any parse (the WSDL server) call this first; #parse calls it too.
      def utf8_text(xml)
        bytes = xml.to_s.b
        raise ParseError, "only UTF-8 XML without a byte order mark is accepted" if BYTE_ORDER_MARKS.any? { |bom| bytes.start_with?(bom) }
        raise ParseError, "only UTF-8 XML is accepted (NUL byte, UTF-16/UTF-32 body)" if bytes.include?("\x00")

        text = bytes.force_encoding(Encoding::UTF_8)
        raise ParseError, "only UTF-8 XML is accepted (invalid UTF-8 bytes)" unless text.valid_encoding?

        declared = text[DECLARED_ENCODING, 1]
        if declared && !declared.casecmp?("UTF-8")
          raise ParseError, "only UTF-8 XML is accepted (declared encoding #{declared.inspect})"
        end

        text
      end

      def decode_references(raw)
        return raw unless raw.include?("&")

        raw.gsub(/&([^;&\s]*);?/) do |match|
          raise ParseError, "unterminated reference #{match[0, 20].inspect}" unless match.end_with?(";")

          name = Regexp.last_match(1)
          if (replacement = PREDEFINED_ENTITIES[name])
            replacement
          elsif name =~ /\A#x([0-9A-Fa-f]{1,6})\z/ || name =~ /\A#([0-9]{1,7})\z/
            codepoint = name.start_with?("#x") ? Regexp.last_match(1).to_i(16) : Regexp.last_match(1).to_i
            raise ParseError, "invalid character reference &#{name};" unless xml_char?(codepoint)

            [codepoint].pack("U")
          else
            raise ParseError, "undefined entity &#{name}; (DTDs are not supported)"
          end
        end
      end

      def xml_char?(codepoint)
        [0x9, 0xA, 0xD].include?(codepoint) ||
          (0x20..0xD7FF).cover?(codepoint) ||
          (0xE000..0xFFFD).cover?(codepoint) ||
          (0x10000..0x10FFFF).cover?(codepoint)
      end

      # Iterative (no recursion, so nesting depth cannot exhaust the stack).
      class Reader
        def initialize(text)
          @scanner = StringScanner.new(text)
          @stack = []        # open Elements, innermost last
          @open_names = []   # their qualified names, for end-tag matching
          @root = nil
        end

        def document
          skip_xml_declaration
          until @scanner.eos?
            if @stack.empty?
              read_outside_root
            else
              read_content
            end
          end
          raise ParseError, "unclosed element <#{@stack.last.name}>" unless @stack.empty?
          raise ParseError, "no root element" unless @root

          Document.new(@root)
        end

        private

        def skip_xml_declaration
          return unless @scanner.check(/<\?xml[\s?]/)

          @scanner.scan_until(/\?>/) or raise ParseError, "unterminated XML declaration"
        end

        # Between the prolog and the end: whitespace, comments, PIs, the root.
        def read_outside_root
          return if @scanner.skip(/\s+/)
          return skip_comment if @scanner.check(/<!--/)
          return skip_processing_instruction if @scanner.check(/<\?/)
          raise ParseError, "DOCTYPE and other declarations are not supported" if @scanner.check(/<!/)
          raise ParseError, "content after the root element" if @root
          raise ParseError, "text outside the root element" unless @scanner.check(/</)

          open_element
        end

        def read_content
          if (data = @scanner.scan(/[^<]+/))
            raise ParseError, "']]>' is not allowed in character data" if data.include?("]]>")

            @stack.last.append_text(XmlParser.decode_references(data))
          elsif @scanner.check(/<\//)
            close_element
          elsif @scanner.check(/<!--/)
            skip_comment
          elsif @scanner.skip(/<!\[CDATA\[/)
            cdata = @scanner.scan_until(/\]\]>/) or raise ParseError, "unterminated CDATA section"
            @stack.last.append_text(cdata[0...-3])
          elsif @scanner.check(/<!/)
            raise ParseError, "DOCTYPE and other declarations are not supported"
          elsif @scanner.check(/<\?/)
            skip_processing_instruction
          else
            open_element
          end
        end

        def open_element
          @scanner.skip(/</)
          name = @scanner.scan(NAME) or raise ParseError, "invalid tag name at byte #{@scanner.pos}"
          attributes = read_attributes
          self_closing = !@scanner.skip(%r{/>}).nil?
          raise ParseError, "unterminated tag <#{name}>" unless self_closing || @scanner.skip(/>/)

          element = Element.new(name, attributes)
          if @stack.empty?
            @root = element
          else
            @stack.last.append_child(element)
          end
          return if self_closing

          @stack.push(element)
          @open_names.push(name)
        end

        def read_attributes
          attributes = {}
          loop do
            had_space = @scanner.skip(/\s+/)
            break if @scanner.check(%r{/?>})

            raise ParseError, "attributes must be separated by whitespace" unless had_space

            key = @scanner.scan(NAME) or raise ParseError, "invalid attribute at byte #{@scanner.pos}"
            @scanner.skip(/\s*=\s*/) or raise ParseError, "attribute #{key} has no value"
            quote = @scanner.getch
            raise ParseError, "attribute #{key} value must be quoted" unless ['"', "'"].include?(quote)

            value = @scanner.scan_until(/#{quote}/) or raise ParseError, "unterminated attribute #{key}"
            value = value[0...-1]
            raise ParseError, "'<' is not allowed in attribute #{key}" if value.include?("<")
            raise ParseError, "duplicate attribute #{key}" if attributes.key?(key)

            attributes[key] = XmlParser.decode_references(value)
          end
          attributes
        end

        def close_element
          @scanner.skip(%r{</})
          name = @scanner.scan(NAME) or raise ParseError, "invalid closing tag at byte #{@scanner.pos}"
          @scanner.skip(/\s*/)
          @scanner.skip(/>/) or raise ParseError, "unterminated closing tag </#{name}>"
          expected = @open_names.last
          raise ParseError, "unexpected closing tag </#{name}>" unless expected
          raise ParseError, "mismatched tag: expected </#{expected}>, found </#{name}>" unless expected == name

          @open_names.pop
          @stack.pop
        end

        def skip_comment
          @scanner.skip(/<!--/)
          @scanner.skip_until(/-->/) or raise ParseError, "unterminated comment"
        end

        def skip_processing_instruction
          @scanner.skip(/<\?/)
          target = @scanner.check(NAME)
          raise ParseError, "an XML declaration is only allowed at the very start" if target&.casecmp?("xml")

          @scanner.skip_until(/\?>/) or raise ParseError, "unterminated processing instruction"
        end
      end
    end
  end
end
