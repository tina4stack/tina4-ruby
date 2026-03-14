# frozen_string_literal: true
require "uri"
require "json"

module Tina4
  class Request
    attr_reader :env, :method, :path, :query_string, :content_type,
                :path_params, :ip

    def initialize(env, path_params = {})
      @env = env
      @method = env["REQUEST_METHOD"]
      @path = env["PATH_INFO"] || "/"
      @query_string = env["QUERY_STRING"] || ""
      @content_type = env["CONTENT_TYPE"] || ""
      @ip = env["REMOTE_ADDR"] || "127.0.0.1"
      @path_params = path_params

      # Lazy-initialized fields (nil = not yet computed)
      @headers = nil
      @cookies = nil
      @session = nil
      @body = nil
      @params = nil
      @files = nil
      @json_body = nil
    end

    # Lazy accessors — only compute when needed
    def headers
      @headers ||= extract_headers
    end

    def cookies
      @cookies ||= parse_cookies
    end

    def session
      @session ||= @env["tina4.session"] || {}
    end

    def body
      @body ||= read_body
    end

    def files
      @files ||= extract_files
    end

    def params
      @params ||= build_params
    end

    def [](key)
      params[key.to_s] || params[key.to_sym] || @path_params[key.to_sym]
    end

    def header(name)
      headers[name.to_s.downcase.gsub("-", "_")]
    end

    def json_body
      @json_body ||= begin
        JSON.parse(body)
      rescue JSON::ParserError, TypeError
        {}
      end
    end

    def bearer_token
      auth = header("authorization") || ""
      auth.sub(/\ABearer\s+/i, "") if auth =~ /\ABearer\s+/i
    end

    private

    def extract_headers
      h = {}
      @env.each do |key, value|
        if key.start_with?("HTTP_")
          h[key[5..].downcase] = value
        end
      end
      h
    end

    def parse_cookies
      cookie_str = @env["HTTP_COOKIE"]
      return {} unless cookie_str && !cookie_str.empty?

      result = {}
      cookie_str.split(";").each do |pair|
        key, value = pair.strip.split("=", 2)
        result[key] = value if key
      end
      result
    end

    def read_body
      input = @env["rack.input"]
      return "" unless input
      input.rewind if input.respond_to?(:rewind)
      data = input.read || ""
      input.rewind if input.respond_to?(:rewind)
      data
    end

    def build_params
      p = {}

      # Query string params
      parse_query_string(@query_string, p) unless @query_string.empty?

      # Body params
      if @content_type.include?("application/json")
        json_body.each { |k, v| p[k.to_s] = v }
      elsif @content_type.include?("application/x-www-form-urlencoded")
        parse_query_string(body, p)
      end

      # Path params (highest priority)
      @path_params.each { |k, v| p[k.to_s] = v }
      p
    end

    def parse_query_string(qs, target = {})
      return target if qs.nil? || qs.empty?
      qs.split("&").each do |pair|
        key, value = pair.split("=", 2)
        target[URI.decode_www_form_component(key.to_s)] = URI.decode_www_form_component(value.to_s)
      end
      target
    end

    def extract_files
      result = {}
      return result unless @content_type.include?("multipart/form-data")
      begin
        form_hash = @env["rack.request.form_hash"]
        if form_hash
          form_hash.each do |key, value|
            if value.is_a?(Hash) && value[:tempfile]
              result[key] = {
                filename: value[:filename],
                type: value[:type],
                tempfile: value[:tempfile],
                size: value[:tempfile].size
              }
            end
          end
        end
      rescue StandardError
        # Multipart parsing failed
      end
      result
    end
  end
end
