# frozen_string_literal: true
require "uri"
require "json"

module Tina4
  class Request
    attr_reader :env, :method, :path, :query_string, :content_type,
                :params, :headers, :cookies, :session, :files, :body,
                :path_params, :ip

    def initialize(env, path_params = {})
      @env = env
      @method = env["REQUEST_METHOD"]
      @path = env["PATH_INFO"] || "/"
      @query_string = env["QUERY_STRING"] || ""
      @content_type = env["CONTENT_TYPE"] || ""
      @ip = env["REMOTE_ADDR"] || "127.0.0.1"
      @path_params = path_params
      @headers = extract_headers(env)
      @cookies = parse_cookies(env)
      @session = env["tina4.session"] || {}
      @body = read_body(env)
      @params = build_params
      @files = extract_files(env)
    end

    def [](key)
      @params[key.to_s] || @params[key.to_sym] || @path_params[key.to_sym]
    end

    def header(name)
      @headers[name.to_s.downcase.gsub("-", "_")]
    end

    def json_body
      @json_body ||= begin
        JSON.parse(@body)
      rescue JSON::ParserError, TypeError
        {}
      end
    end

    def bearer_token
      auth = header("authorization") || ""
      auth.sub(/\ABearer\s+/i, "") if auth =~ /\ABearer\s+/i
    end

    private

    def extract_headers(env)
      headers = {}
      env.each do |key, value|
        if key.start_with?("HTTP_")
          header_name = key.sub("HTTP_", "").downcase
          headers[header_name] = value
        end
      end
      headers
    end

    def parse_cookies(env)
      cookie_str = env["HTTP_COOKIE"] || ""
      cookies = {}
      cookie_str.split(";").each do |pair|
        key, value = pair.strip.split("=", 2)
        cookies[key] = value if key
      end
      cookies
    end

    def read_body(env)
      input = env["rack.input"]
      return "" unless input
      input.rewind if input.respond_to?(:rewind)
      data = input.read || ""
      input.rewind if input.respond_to?(:rewind)
      data
    end

    def build_params
      params = {}
      parse_query_string(@query_string).each { |k, v| params[k] = v }
      if @content_type.include?("application/json")
        json_body.each { |k, v| params[k.to_s] = v }
      elsif @content_type.include?("application/x-www-form-urlencoded")
        parse_query_string(@body).each { |k, v| params[k] = v }
      end
      @path_params.each { |k, v| params[k.to_s] = v }
      params
    end

    def parse_query_string(qs)
      params = {}
      return params if qs.nil? || qs.empty?
      qs.split("&").each do |pair|
        key, value = pair.split("=", 2)
        key = URI.decode_www_form_component(key.to_s)
        value = URI.decode_www_form_component(value.to_s)
        params[key] = value
      end
      params
    end

    def extract_files(env)
      files = {}
      return files unless @content_type.include?("multipart/form-data")
      begin
        if env["rack.request.form_hash"]
          env["rack.request.form_hash"].each do |key, value|
            if value.is_a?(Hash) && value[:tempfile]
              files[key] = {
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
      files
    end
  end
end
