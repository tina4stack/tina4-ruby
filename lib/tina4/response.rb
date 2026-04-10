# frozen_string_literal: true
require "json"
require "uri"

module Tina4
  class Response
    MIME_TYPES = {
      ".html" => "text/html", ".htm" => "text/html",
      ".css" => "text/css", ".js" => "application/javascript",
      ".json" => "application/json", ".xml" => "application/xml",
      ".txt" => "text/plain", ".csv" => "text/csv",
      ".png" => "image/png", ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg", ".gif" => "image/gif",
      ".svg" => "image/svg+xml", ".ico" => "image/x-icon",
      ".webp" => "image/webp", ".pdf" => "application/pdf",
      ".zip" => "application/zip", ".woff" => "font/woff",
      ".woff2" => "font/woff2", ".ttf" => "font/ttf",
      ".eot" => "application/vnd.ms-fontobject",
      ".mp3" => "audio/mpeg", ".mp4" => "video/mp4",
      ".webm" => "video/webm"
    }.freeze

    # Pre-frozen header values
    JSON_CONTENT_TYPE = "application/json; charset=utf-8"
    HTML_CONTENT_TYPE = "text/html; charset=utf-8"
    TEXT_CONTENT_TYPE = "text/plain; charset=utf-8"
    XML_CONTENT_TYPE  = "application/xml; charset=utf-8"

    attr_accessor :status_code, :headers, :body, :cookies

    def initialize
      @status_code = 200
      @headers = { "content-type" => HTML_CONTENT_TYPE }
      @body = ""
      @cookies = nil  # Lazy -- most responses have no cookies
    end

    # Chainable status setter
    def status(code = nil)
      if code.nil?
        @status_code
      else
        @status_code = code
        self
      end
    end

    # Callable response — auto-detects content type from data.
    # Matches Python __call__ / PHP __invoke / Node response() pattern.
    def call(data = nil, status_code = 200, content_type = nil)
      @status_code = status_code
      if content_type
        @headers["content-type"] = content_type
        @body = data.to_s
      elsif data.is_a?(Hash) || data.is_a?(Array)
        @headers["content-type"] = JSON_CONTENT_TYPE
        @body = JSON.generate(data)
      else
        @headers["content-type"] = HTML_CONTENT_TYPE
        @body = data.to_s
      end
      self
    end

    def json(data, status_or_opts = nil, status: nil)
      @status_code = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = JSON_CONTENT_TYPE
      @body = data.is_a?(String) ? data : JSON.generate(data)
      self
    end

    def html(content, status_or_opts = nil, status: nil)
      @status_code = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = HTML_CONTENT_TYPE
      @body = content.to_s
      self
    end

    def text(content, status_or_opts = nil, status: nil)
      @status_code = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = TEXT_CONTENT_TYPE
      @body = content.to_s
      self
    end

    def xml(content, status: 200)
      @status_code = status
      @headers["content-type"] = XML_CONTENT_TYPE
      @body = content.to_s
      self
    end

    def csv(content, filename: "export.csv", status: 200)
      @status_code = status
      @headers["content-type"] = "text/csv"
      @headers["content-disposition"] = "attachment; filename=\"#{filename}\""
      @body = content.to_s
      self
    end

    def redirect(url, status_or_opts = nil, status: nil)
      @status_code = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 302)
      @headers["location"] = url
      @body = ""
      self
    end

    def file(path, content_type: nil, download: false)
      unless ::File.exist?(path)
        @status_code = 404
        @body = "File not found"
        return self
      end
      ext = ::File.extname(path).downcase
      @headers["content-type"] = content_type || MIME_TYPES[ext] || "application/octet-stream"
      if download
        @headers["content-disposition"] = "attachment; filename=\"#{::File.basename(path)}\""
      end
      @body = ::File.binread(path)
      self
    end

    def render(template_path, data = {}, status: 200, template_dir: nil)
      @status_code = status
      @headers["content-type"] = HTML_CONTENT_TYPE
      if template_dir
        frond = Tina4::Frond.new(template_dir: template_dir)
        @body = frond.render(template_path, data)
      else
        @body = Tina4::Template.render(template_path, data)
      end
      self
    end

    # Standard error response envelope.
    #
    # Usage:
    #   response.error("VALIDATION_FAILED", "Email is required", 400)
    #
    def error(code, message, status_code = 400)
      @status_code = status_code
      @headers["content-type"] = JSON_CONTENT_TYPE
      @body = JSON.generate({
        error: true,
        code: code,
        message: message,
        status: status_code
      })
      self
    end

    # Build a standard error envelope hash (class method).
    #
    # Usage:
    #   response.json(Tina4::Response.error_envelope("NOT_FOUND", "Resource not found", 404), status: 404)
    #
    def self.error_envelope(code, message, status = 400)
      { error: true, code: code, message: message, status: status }
    end

    # Static error response builder matching Python/PHP/Node API.
    def self.error_response(code, message, status = 400)
      error_envelope(code, message, status)
    end

    # Alias for render — matches PHP/Node naming.
    def template(template_path, data = {}, status: 200, template_dir: nil)
      render(template_path, data, status: status, template_dir: template_dir)
    end

    # Chainable header setter
    def header(name, value = nil)
      if value.nil?
        @headers[name]
      else
        @headers[name] = value
        self
      end
    end

    # Chainable cookie setter
    def cookie(name, value, opts = {})
      set_cookie(name, value, opts)
    end

    def set_cookie(name, value, opts = {})
      cookie_str = "#{name}=#{URI.encode_www_form_component(value)}"
      cookie_str += "; Path=#{opts[:path] || '/'}"
      cookie_str += "; HttpOnly" if opts.fetch(:http_only, true)
      cookie_str += "; Secure" if opts[:secure]
      cookie_str += "; SameSite=#{opts[:same_site] || 'Lax'}"
      cookie_str += "; Max-Age=#{opts[:max_age]}" if opts[:max_age]
      cookie_str += "; Expires=#{opts[:expires].httpdate}" if opts[:expires]
      @cookies ||= []
      @cookies << cookie_str
      self
    end

    def delete_cookie(name, path: "/")
      set_cookie(name, "", max_age: 0, path: path)
    end

    def add_header(key, value)
      @headers[key] = value
      self
    end

    def add_cors_headers(origin: "*", methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
                         headers_list: "Content-Type, Authorization, Accept", credentials: false)
      @headers["access-control-allow-origin"] = origin
      @headers["access-control-allow-methods"] = methods
      @headers["access-control-allow-headers"] = headers_list
      @headers["access-control-allow-credentials"] = "true" if credentials
      @headers["access-control-max-age"] = "86400"
      self
    end

    # Stream response from a block for Server-Sent Events (SSE).
    #
    # Usage:
    #   Tina4::Router.get "/events" do |request, response|
    #     response.stream do |out|
    #       10.times do |i|
    #         out << "data: message #{i}\n\n"
    #         sleep 1
    #       end
    #     end
    #   end
    #
    # @param content_type [String] Content type (default: text/event-stream)
    # @yield [Enumerator::Yielder] Block receives a yielder to push chunks
    # @return [self]
    def stream(content_type: "text/event-stream", &block)
      @status_code = @status_code || 200
      @headers["content-type"] = content_type
      @headers["cache-control"] = "no-cache"
      @headers["connection"] = "keep-alive"
      @headers["x-accel-buffering"] = "no"
      @_streaming = true
      @_stream_block = block
      self
    end

    # Finalize and return the response — matches Python/Node API.
    def send(data = nil, status_code: nil, content_type: nil)
      if data
        if data.is_a?(Hash) || data.is_a?(Array)
          return json(data, status_code || 200)
        end
        @headers["content-type"] = content_type if content_type
        @body = data.to_s
        @status_code = status_code if status_code
        return self
      end
      to_rack
    end

    def to_rack
      final_headers = @headers.dup
      final_headers["set-cookie"] = @cookies.join("\n") if @cookies && !@cookies.empty?

      if @_streaming
        # Streaming mode — return an Enumerator as the body
        body = Enumerator.new do |yielder|
          @_stream_block.call(yielder)
        end
        return [@status_code, final_headers, body]
      end

      # Normal buffered response
      [@status_code, final_headers, [@body.to_s]]
    end

    def self.auto_detect(result, response)
      case result
      when Tina4::Response
        result
      when Hash, Array
        response.json(result)
      when String
        if result.start_with?("<")
          response.html(result)
        else
          response.text(result)
        end
      when Integer
        response.status_code = result
        response.body = ""
        response
      when NilClass
        response.status_code = 204
        response.body = ""
        response
      else
        response.json(result.respond_to?(:to_hash) ? result.to_hash : { data: result.to_s })
      end
    end
  end
end
