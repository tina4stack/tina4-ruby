# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "tina4/xml_parser"

# Tina4::WSDL::XmlParser replaced REXML for SOAP bodies. It is pure logic over its
# input, so these are plain input -> output checks: what it must accept and
# decode, and everything it must refuse (DTDs, entities, non-UTF-8 bodies).
RSpec.describe Tina4::WSDL::XmlParser do
  def parse(xml)
    described_class.parse(xml)
  end

  def refuses(xml)
    expect { parse(xml) }.to raise_error(Tina4::WSDL::XmlParser::ParseError)
  end

  describe "accepts well-formed XML" do
    let(:envelope) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- leading comment -->
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <tns:Add xmlns:tns="urn:Calc" note="a &gt; b">
              <a>1</a>
              <b>2</b>
            </tns:Add>
          </soap:Body>
        </soap:Envelope>
      XML
    end

    it "strips namespace prefixes from element names and keeps the prefix separately" do
      root = parse(envelope).root
      expect(root.name).to eq("Envelope")
      expect(root.prefix).to eq("soap")
      body = root.elements.first
      expect(body.name).to eq("Body")
      operation = body.elements.first
      expect(operation.name).to eq("Add")
      expect(operation.elements.map { |e| [e.name, e.text] }).to eq([%w[a 1], %w[b 2]])
    end

    it "decodes attribute values, including a '>' inside quotes" do
      operation = parse(envelope).root.elements.first.elements.first
      expect(operation.attributes["note"]).to eq("a > b")
      expect(parse(%(<r a='x>y'/>)).root.attributes["a"]).to eq("x>y")
    end

    it "decodes the five predefined entities and character references" do
      text = parse("<r>&lt;&gt;&amp;&quot;&apos; &#65;&#x42;&#x1F600;</r>").root.text
      expect(text).to eq(%(<>&"' AB\u{1F600}))
    end

    it "returns CDATA verbatim, markup and all" do
      expect(parse("<r><![CDATA[<b>&amp;</b>]]></r>").root.text).to eq("<b>&amp;</b>")
    end

    it "gives ElementTree .text: data before the first child, across comments" do
      root = parse("<r>one<!-- c -->two<child/>tail</r>").root
      expect(root.text).to eq("onetwo")
      expect(parse("<r><child/></r>").root.text).to be_nil
      expect(parse("<r>  </r>").root.text).to eq("  ")
    end

    it "keeps multi-byte UTF-8 text intact" do
      root = parse("<r>caf\u00E9 \u6771\u4EAC</r>".b).root
      expect(root.text).to eq("caf\u00E9 \u6771\u4EAC")
      expect(root.text.encoding).to eq(Encoding::UTF_8)
    end

    # The shared SOAP body rule (all four frameworks): no byte order mark at
    # all, the UTF-8 one included, and no declared encoding but UTF-8.
    it "refuses a UTF-8 byte-order mark and a non-UTF-8 declared encoding" do
      refuses("\xEF\xBB\xBF<r>x</r>".b)
      refuses(%(<?xml version="1.0" encoding="ISO-8859-1"?><r>x</r>))
      expect(parse(%(<?xml version="1.0" encoding="utf-8"?><r>x</r>)).root.text).to eq("x")
    end

    it "handles deep nesting without recursion" do
      depth = 50_000
      root = parse(("<n>" * depth) + ("</n>" * depth)).root
      expect(root.name).to eq("n")
    end
  end

  describe "refuses what it does not support" do
    it "refuses a DOCTYPE in the prolog (no DTDs at all)" do
      refuses(%(<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x "y">]><r>&x;</r>))
      refuses(%(<!doctype r><r/>))
    end

    it "refuses a declaration inside content" do
      refuses(%(<r><!ENTITY x "y"></r>))
    end

    it "refuses an entity that is not predefined (no entity expansion)" do
      refuses("<r>&lol;</r>")
      refuses("<r>&amp</r>")
    end

    it "refuses character references to non-XML characters" do
      refuses("<r>&#0;</r>")
      refuses("<r>&#xD800;</r>")
    end

    it "refuses a UTF-16 body with or without a DOCTYPE, whichever byte order" do
      xml = %(<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE r [<!ENTITY a "b">]><r>&a;</r>)
      refuses("\xFF\xFE".b + xml.encode("UTF-16LE").b)
      refuses("\xFE\xFF".b + xml.encode("UTF-16BE").b)
      refuses(xml.encode("UTF-16LE").b) # no BOM: caught by the NUL bytes
    end

    it "refuses bytes that are not valid UTF-8" do
      refuses("<r>\xC3\x28</r>".b)
      refuses("<r>\xE9t\xE9</r>".b) # ISO-8859-1 bytes
    end

    it "refuses malformed structure" do
      refuses("<a><b></a></b>")       # mismatched
      refuses("<a><b></b>")           # unclosed
      refuses("<a/><b/>")             # two roots
      refuses("text<a/>")             # text before the root
      refuses("<a/>text")             # text after the root
      refuses("")                     # no root
      refuses("<a></a")               # unterminated end tag
      refuses("<a x=1/>")             # unquoted attribute
      refuses(%(<a x="1" x="2"/>))    # duplicate attribute
      refuses(%(<a x="<"/>))          # '<' in an attribute
      refuses("<a><!-- open</a>")     # unterminated comment
      refuses("<a><![CDATA[x</a>")    # unterminated CDATA
      refuses("<a><?xml version='1.0'?></a>") # XML declaration not at the start
    end
  end
end
