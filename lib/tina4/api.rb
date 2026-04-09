# frozen_string_literal: true
require "net/http"
require "uri"
require "json"
require "base64"

module Tina4
  class API
    attr_reader :base_url, :headers

    def initialize(base_url, headers: {}, timeout: 30)
      @base_url = base_url.chomp("/")
      @headers = {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }.merge(headers)
      @timeout = timeout
    end

    def get(path, params: {})
      uri = build_uri(path, params)
      request = Net::HTTP::Get.new(uri)
      apply_headers(request, {})
      execute(uri, request)
    end

    def post(path, body: nil, content_type: "application/json")
      uri = build_uri(path)
      request = Net::HTTP::Post.new(uri)
      if body
        request.body = body.is_a?(String) ? body : JSON.generate(body)
        request["Content-Type"] = content_type
      end
      apply_headers(request, {})
      execute(uri, request)
    end

    def put(path, body: nil, content_type: "application/json")
      uri = build_uri(path)
      request = Net::HTTP::Put.new(uri)
      if body
        request.body = body.is_a?(String) ? body : JSON.generate(body)
        request["Content-Type"] = content_type
      end
      apply_headers(request, {})
      execute(uri, request)
    end

    def patch(path, body: nil, content_type: "application/json")
      uri = build_uri(path)
      request = Net::HTTP::Patch.new(uri)
      if body
        request.body = body.is_a?(String) ? body : JSON.generate(body)
        request["Content-Type"] = content_type
      end
      apply_headers(request, {})
      execute(uri, request)
    end

    def delete(path, body: nil)
      uri = build_uri(path)
      request = Net::HTTP::Delete.new(uri)
      request.body = body.is_a?(String) ? body : JSON.generate(body) if body
      apply_headers(request, {})
      execute(uri, request)
    end

    def upload(path, file_path, field_name: "file", extra_fields: {}, headers: {})
      uri = build_uri(path)
      boundary = "----Tina4Boundary#{SecureRandom.hex(16)}"

      body = build_multipart_body(boundary, file_path, field_name, extra_fields)

      request = Net::HTTP::Post.new(uri)
      request.body = body
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      headers.each { |k, v| request[k] = v }
      execute(uri, request)
    end

    def set_basic_auth(username, password)
      @headers["Authorization"] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
      self
    end

    def set_bearer_token(token)
      @headers["Authorization"] = "Bearer #{token}"
      self
    end

    def add_headers(headers)
      @headers.merge!(headers)
      self
    end

    def send_request(method = "GET", path = "", body: nil, content_type: "application/json")
      case method.upcase
      when "GET"    then get(path)
      when "POST"   then post(path, body: body, content_type: content_type)
      when "PUT"    then put(path, body: body, content_type: content_type)
      when "PATCH"  then patch(path, body: body, content_type: content_type)
      when "DELETE" then delete(path, body: body)
      else get(path)
      end
    end

    private

    def build_uri(path, params = {})
      url = "#{@base_url}#{path}"
      uri = URI.parse(url)
      unless params.empty?
        query = URI.encode_www_form(params)
        uri.query = uri.query ? "#{uri.query}&#{query}" : query
      end
      uri
    end

    def apply_headers(request, extra_headers)
      @headers.merge(extra_headers).each do |key, value|
        request[key] = value
      end
    end

    def execute(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout

      response = http.request(request)

      APIResponse.new(
        status: response.code.to_i,
        body: response.body,
        headers: response.to_hash
      )
    rescue StandardError => e
      APIResponse.new(
        status: 0,
        body: "",
        headers: {},
        error: e.message
      )
    end

    def build_multipart_body(boundary, file_path, field_name, extra_fields)
      body = ""
      extra_fields.each do |key, value|
        body += "--#{boundary}\r\n"
        body += "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n"
        body += "#{value}\r\n"
      end

      filename = File.basename(file_path)
      body += "--#{boundary}\r\n"
      body += "Content-Disposition: form-data; name=\"#{field_name}\"; filename=\"#{filename}\"\r\n"
      body += "Content-Type: application/octet-stream\r\n\r\n"
      body += File.binread(file_path)
      body += "\r\n--#{boundary}--\r\n"
      body
    end
  end

  class APIResponse
    attr_reader :status, :body, :headers, :error

    def initialize(status:, body:, headers:, error: nil)
      @status = status
      @body = body
      @headers = headers
      @error = error
    end

    def success?
      @status >= 200 && @status < 300
    end

    def json
      @json ||= JSON.parse(@body)
    rescue JSON::ParserError
      {}
    end

    def to_s
      "APIResponse(status=#{@status})"
    end
  end
end
