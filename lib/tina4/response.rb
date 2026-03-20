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

    def render(template_path, data = {}, status: 200)
      @status_code = status
      @headers["content-type"] = HTML_CONTENT_TYPE
      @body = Tina4::Template.render(template_path, data)
      self
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

    # Flush / finalize -- alias for to_rack for semantic clarity
    def send
      to_rack
    end

    def to_rack
      # Fast path: no cookies (99% of API responses)
      if @cookies.nil? || @cookies.empty?
        return [@status_code, @headers, [@body.to_s]]
      end

      # Cookie path
      final_headers = @headers.dup
      final_headers["set-cookie"] = @cookies.join("\n")
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
