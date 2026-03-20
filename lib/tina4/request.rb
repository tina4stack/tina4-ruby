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
      @path_params = path_params

      # Client IP with X-Forwarded-For support
      @ip = extract_client_ip

      # Lazy-initialized fields (nil = not yet computed)
      @headers = nil
      @cookies = nil
      @session = nil
      @body_raw = nil
      @params = nil
      @files = nil
      @json_body = nil
      @query_hash = nil
      @body_parsed = nil
    end

    # Full URL reconstruction
    def url
      scheme = env["rack.url_scheme"] || "http"
      host = env["HTTP_HOST"] || env["SERVER_NAME"] || "localhost"
      port = env["SERVER_PORT"]
      url_str = "#{scheme}://#{host}"
      url_str += ":#{port}" if port && port != "80" && port != "443"
      url_str += @path
      url_str += "?#{@query_string}" unless @query_string.empty?
      url_str
    end

    # Lazy accessors
    def headers
      @headers ||= extract_headers
    end

    def cookies
      @cookies ||= parse_cookies
    end

    def session
      @session ||= @env["tina4.session"] || {}
    end

    # Raw body string
    def body
      @body_raw ||= read_body
    end

    # Parsed body (JSON or form data)
    def body_parsed
      @body_parsed ||= parse_body
    end

    # Parsed query string as hash
    def query
      @query_hash ||= parse_query_to_hash(@query_string)
    end

    def files
      @files ||= extract_files
    end

    # Merged params: query + body + path_params (path_params highest priority)
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

    def extract_client_ip
      # Check X-Forwarded-For first (proxy/load balancer)
      forwarded = @env["HTTP_X_FORWARDED_FOR"]
      if forwarded && !forwarded.empty?
        # Take the first (original client) IP
        forwarded.split(",").first.strip
      else
        @env["HTTP_X_REAL_IP"] || @env["REMOTE_ADDR"] || "127.0.0.1"
      end
    end

    def extract_headers
      h = {}
      @env.each do |key, value|
        if key.start_with?("HTTP_")
          h[key[5..-1].downcase] = value
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

    def parse_body
      if @content_type.include?("application/json")
        json_body
      elsif @content_type.include?("application/x-www-form-urlencoded")
        parse_query_to_hash(body)
      else
        {}
      end
    end

    def build_params
      p = {}

      # Query string params
      query.each { |k, v| p[k] = v }

      # Body params
      body_parsed.each { |k, v| p[k.to_s] = v }

      # Path params (highest priority)
      @path_params.each { |k, v| p[k.to_s] = v }
      p
    end

    def parse_query_to_hash(qs)
      result = {}
      return result if qs.nil? || qs.empty?
      qs.split("&").each do |pair|
        key, value = pair.split("=", 2)
        result[URI.decode_www_form_component(key.to_s)] = URI.decode_www_form_component(value.to_s)
      end
      result
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
