# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "stringio"

module Tina4
  # multipart/form-data parsing, owned by Tina4 (no Rack).
  #
  # Replaces Rack::Request#POST, which Tina4::Request used for multipart bodies
  # until rack stopped being a dependency. Field names nest exactly the way Rack
  # nested them - `user[name]` becomes a hash, `tags[]` an array, `a[][x]` an
  # array of hashes, a repeated plain name keeps its last value - so a Ruby app
  # that posts nested forms sees the same body it always did. spec/form_parser_spec.rb
  # pins every shape against values captured from Rack 3.2.7.
  #
  # Files are parsed in the SAME pass and keyed by field name, each name mapping
  # to a LIST of descriptors so a repeated file field keeps every file
  # (fileupload_contract upload-repeated-field-list).
  #
  # The part delimiter is CRLF + "--" + boundary, as RFC 2046 defines it, so a
  # file whose bytes happen to contain "--boundary" mid-line is not cut short.
  module FormParser
    # A name nested deeper than this is refused rather than recursed into.
    # Rack's QueryParser param_depth_limit, kept for the same reason.
    PARAM_DEPTH_LIMIT = 32

    # A field name that is both a value and a container (`a=1` then `a[b]=2`)
    # or nests past PARAM_DEPTH_LIMIT. Rack raised here too.
    class ParameterError < StandardError; end

    # Marks a hash the NESTING built, as opposed to a value that happens to be a
    # hash. Only these may be descended into.
    class NestedParams < Hash; end
    private_constant :NestedParams

    module_function

    # The boundary token from a multipart Content-Type, quotes removed; nil when
    # there is none.
    def boundary(content_type)
      content_type.to_s.split(";").each do |part|
        part = part.strip
        next unless part.downcase.start_with?("boundary=")

        value = part[9..].to_s.strip
        value = value[1...-1] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
        return value.empty? ? nil : value
      end
      nil
    end

    # Parse a multipart body.
    #
    # @return [Hash] { fields: Hash (nested, Rack-shaped), files: Hash{name => [descriptor]},
    #   error: ParameterError or nil }
    #   A descriptor is { filename:, type:, content:, size:, tempfile: } with the
    #   RAW client filename - Tina4::Request.save_upload sanitises it on write.
    #   A name conflict or over-deep nesting empties the fields and is returned
    #   as :error rather than raised, so one bad field name cannot lose the files.
    def parse_multipart(body, content_type)
      token = boundary(content_type)
      fields = NestedParams.new
      files = {}
      return { fields: {}, files: files, error: nil } if token.nil? || body.nil? || body.empty?

      pairs = []
      each_part(body.b, token) do |headers, content|
        name, filename = disposition_params(headers["content-disposition"].to_s)
        next if name.nil? || name.empty?

        if filename.nil?
          pairs << [name.dup.force_encoding(Encoding::UTF_8), text_value(content, headers["content-type"])]
        else
          (files[name] ||= []) << {
            filename: filename.dup.force_encoding(Encoding::UTF_8).scrub,
            type: headers["content-type"] || "application/octet-stream",
            content: content,
            size: content.bytesize,
            tempfile: StringIO.new(content)
          }
        end
      end
      # A name conflict voids the FIELDS only (Rack raised for the whole form);
      # the files were collected independently and survive it.
      error = nil
      begin
        pairs.each { |name, value| normalize_params(fields, name, value, 0) }
      rescue ParameterError => e
        error = e
        fields = NestedParams.new
      end
      { fields: to_plain_hash(fields), files: files, error: error }
    end

    # Yield [headers, content] for every part. headers keys are lowercased.
    def each_part(body, token)
      delimiter = "--#{token}".b
      position = body.index(delimiter)
      return if position.nil?

      position += delimiter.bytesize
      separator = "\r\n#{delimiter}".b
      while position < body.bytesize
        # "--" straight after a delimiter closes the body.
        break if body.byteslice(position, 2) == "--"

        position += 2 if body.byteslice(position, 2) == "\r\n"
        header_end = body.index("\r\n\r\n", position)
        break if header_end.nil?

        next_delimiter = body.index(separator, header_end + 4)
        break if next_delimiter.nil?

        yield part_headers(body.byteslice(position, header_end - position)),
              body.byteslice(header_end + 4, next_delimiter - header_end - 4)
        position = next_delimiter + separator.bytesize
      end
    end

    def part_headers(block)
      headers = {}
      block.split("\r\n").each do |line|
        name, value = line.split(":", 2)
        next if value.nil?

        headers[name.strip.downcase] = value.strip.force_encoding(Encoding::UTF_8).scrub
      end
      headers
    end

    # name= and filename= from a Content-Disposition value, by PARAMETER (not by
    # a substring match, which found "name=" inside "filename=").
    def disposition_params(disposition)
      params = {}
      disposition.scan(/;\s*([A-Za-z0-9!#$%&'*+.^_`|~-]+)\s*=\s*("(?:[^"\\]|\\.)*"|[^;]*)/) do |key, raw|
        value = raw.strip
        value = value[1...-1].gsub(/\\(.)/, '\1') if value.start_with?('"') && value.end_with?('"') && value.length >= 2
        params[key.downcase] ||= value
      end
      [params["name"], params["filename"]]
    end

    # A text field is UTF-8 unless the part says `text/plain; charset=...`
    # (Rack's rule). An unknown charset falls back to binary, never raises.
    def text_value(content, part_type)
      encoding = Encoding::UTF_8
      if part_type
        type, *parameters = part_type.split(";").map(&:strip)
        if type.casecmp?("text/plain")
          parameters.each do |parameter|
            key, value = parameter.split("=", 2)
            next unless key&.casecmp?("charset") && value

            encoding = begin
              Encoding.find(value.delete('"'))
            rescue ArgumentError
              Encoding::BINARY
            end
          end
        end
      end
      content.dup.force_encoding(encoding)
    end

    # Rack::QueryParser#normalize_params, ported. Returns params.
    def normalize_params(params, name, value, depth)
      raise ParameterError, "field name nests deeper than #{PARAM_DEPTH_LIMIT} levels" if depth >= PARAM_DEPTH_LIMIT

      if depth.zero?
        start = name.index("[", 1)
        key = start ? name[0, start] : name
        after = start ? name[start..] : ""
      elsif name.start_with?("[]")
        key = "[]"
        after = name[2..]
      elsif name.start_with?("[") && (close = name.index("]", 1))
        key = name[1, close - 1]
        after = name[(close + 1)..]
      else
        key = name
        after = ""
      end
      return if key.empty?

      if after.empty?
        return [value] if key == "[]" && !depth.zero?

        params[key] = value
      elsif after == "["
        params[name] = value
      elsif after == "[]"
        params[key] ||= []
        raise ParameterError, "expected Array for `#{key}'" unless params[key].is_a?(Array)

        params[key] << value
      elsif after.start_with?("[]")
        child_key = after[3, after.length - 4] if after[2] == "[" && after.end_with?("]")
        child_key = after[2..] if child_key.nil? || child_key.empty? || child_key.include?("[") || child_key.include?("]")
        params[key] ||= []
        raise ParameterError, "expected Array for `#{key}'" unless params[key].is_a?(Array)

        last = params[key].last
        if last.is_a?(NestedParams) && !nested_key?(last, child_key)
          normalize_params(last, child_key, value, depth + 1)
        else
          params[key] << normalize_params(NestedParams.new, child_key, value, depth + 1)
        end
      else
        params[key] ||= NestedParams.new
        raise ParameterError, "expected Hash for `#{key}'" unless params[key].is_a?(NestedParams)

        params[key] = normalize_params(params[key], after, value, depth + 1)
      end
      params
    end

    def nested_key?(hash, key)
      return false if key.include?("[]")

      key.split(/[\[\]]+/).reject(&:empty?).reduce(hash) do |level, part|
        return false unless level.is_a?(NestedParams) && level.key?(part)

        level[part]
      end
      true
    end

    def to_plain_hash(value)
      case value
      when Hash then value.each_with_object({}) { |(key, child), plain| plain[key] = to_plain_hash(child) }
      when Array then value.map { |child| to_plain_hash(child) }
      else value
      end
    end
  end
end
