# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "uri"

# A bracketed form field (`tags[]`, `user[name]`) arrives nested however the
# form was sent. Multipart bodies always nested (Tina4::FormParser); an
# urlencoded body was split on "&" into flat keys, so `tags[]=red&tags[]=blue`
# arrived as {"tags[]" => "blue"} - the first value gone. Both encodings now go
# through the same nesting. The query string stays flat: AutoCrud reads
# `filter[...]` keys from it.
RSpec.describe "Form fields with bracketed names" do
  boundary = "----Tina4FormArrayFields"

  def request_for(content_type, body, query: "")
    Tina4::Request.new(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/form", "QUERY_STRING" => query,
      "rack.input" => StringIO.new(body), "rack.errors" => StringIO.new,
      "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147", "SCRIPT_NAME" => "",
      "rack.url_scheme" => "http", "CONTENT_TYPE" => content_type,
      "CONTENT_LENGTH" => body.bytesize.to_s
    )
  end

  define_method(:multipart) do |pairs|
    body = pairs.map do |name, value|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
    end.join + "--#{boundary}--\r\n"
    request_for("multipart/form-data; boundary=#{boundary}", body)
  end

  def urlencoded(pairs)
    request_for("application/x-www-form-urlencoded", URI.encode_www_form(pairs))
  end

  forms = {
    "a checkbox group" => [[["tags[]", "red"], ["tags[]", "blue"]], { "tags" => %w[red blue] }],
    "one ticked box" => [[["tags[]", "red"]], { "tags" => ["red"] }],
    "a nested field" => [[["user[name]", "Ann"], ["user[roles][]", "admin"]],
                         { "user" => { "name" => "Ann", "roles" => ["admin"] } }],
    "a list of records" => [[["rows[][id]", "1"], ["rows[][id]", "2"], ["rows[][qty]", "5"]],
                            { "rows" => [{ "id" => "1" }, { "id" => "2", "qty" => "5" }] }],
    "a repeated plain name" => [[["p", "1"], ["p", "2"]], { "p" => "2" }],
    "plain fields alongside" => [[["name", "x"], ["tags[]", "red"]], { "name" => "x", "tags" => ["red"] }]
  }

  forms.each do |form, (pairs, expected)|
    it "nests #{form} sent as multipart" do
      expect(multipart(pairs).body).to eq(expected)
    end

    it "nests #{form} sent urlencoded" do
      expect(urlencoded(pairs).body).to eq(expected)
    end
  end

  it "keeps an urlencoded conflicting field under its flat key and still nests the rest" do
    expect(urlencoded([["a", "1"], ["a[b]", "2"], ["tags[]", "red"]]).body)
      .to eq("a" => "1", "a[b]" => "2", "tags" => ["red"])
  end

  it "nests nothing in an urlencoded form past the field limit" do
    pairs = Array.new(4097) { |i| ["x[][k]", i.to_s] }
    expect(urlencoded(pairs).body).to eq("x[][k]" => "4096")
  end

  it "keeps flat keys past the nesting depth limit" do
    name = "x" + ("[k]" * 40)
    expect(urlencoded([[name, "v"]]).body).to eq(name => "v")
  end

  it "keeps an urlencoded field name that is not valid UTF-8" do
    request = request_for("application/x-www-form-urlencoded", "a%FF=1&t%5B%5D=2")
    expect(request.body).to eq("a\xFF".dup.force_encoding(Encoding::UTF_8) => "1", "t" => ["2"])
  end

  it "keeps a list item whose key is not valid UTF-8 under its flat key" do
    request = request_for("application/x-www-form-urlencoded", "rows[][%FF]=1&rows[][%FF]=2&t%5B%5D=3")
    expect(request.body.keys).to eq(["rows", "rows[][\xFF]".dup.force_encoding(Encoding::UTF_8), "t"])
    expect(request.body["t"]).to eq(["3"])
  end

  it "keeps a field name past the length limit under its flat key" do
    name = "a[k][" + ("x" * 2000) + "]"
    expect(urlencoded([[name, "v"], ["t[]", "1"]]).body).to eq(name => "v", "t" => ["1"])
  end

  it "leaves the query string flat" do
    request = request_for("application/x-www-form-urlencoded", "",
                          query: "filter%5Bname%5D=Ann&tags%5B%5D=a&tags%5B%5D=b")
    expect(request.query).to eq("filter[name]" => "Ann", "tags[]" => "b")
  end
end
