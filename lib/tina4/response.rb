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

    attr_accessor :status, :headers, :body, :cookies

    def initialize
      @status = 200
      @headers = { "content-type" => "text/html; charset=utf-8" }
      @body = ""
      @cookies = []
    end

    def json(data, status_or_opts = nil, status: nil)
      @status = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = "application/json; charset=utf-8"
      @body = data.is_a?(String) ? data : JSON.generate(data)
      self
    end

    def html(content, status_or_opts = nil, status: nil)
      @status = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = "text/html; charset=utf-8"
      @body = content.to_s
      self
    end

    def text(content, status_or_opts = nil, status: nil)
      @status = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = "text/plain; charset=utf-8"
      @body = content.to_s
      self
    end

    def xml(content, status: 200)
      @status = status
      @headers["content-type"] = "application/xml; charset=utf-8"
      @body = content.to_s
      self
    end

    def csv(content, filename: "export.csv", status: 200)
      @status = status
      @headers["content-type"] = "text/csv"
      @headers["content-disposition"] = "attachment; filename=\"#{filename}\""
      @body = content.to_s
      self
    end

    def redirect(url, status: 302)
      @status = status
      @headers["location"] = url
      @body = ""
      self
    end

    def file(path, content_type: nil, download: false)
      unless ::File.exist?(path)
        @status = 404
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
      @status = status
      @headers["content-type"] = "text/html; charset=utf-8"
      @body = Tina4::Template.render(template_path, data)
      self
    end

    def set_cookie(name, value, opts = {})
      cookie = "#{name}=#{URI.encode_www_form_component(value)}"
      cookie += "; Path=#{opts[:path] || '/'}"
      cookie += "; HttpOnly" if opts.fetch(:http_only, true)
      cookie += "; Secure" if opts[:secure]
      cookie += "; SameSite=#{opts[:same_site] || 'Lax'}"
      cookie += "; Max-Age=#{opts[:max_age]}" if opts[:max_age]
      cookie += "; Expires=#{opts[:expires].httpdate}" if opts[:expires]
      @cookies << cookie
      self
    end

    def delete_cookie(name, path: "/")
      set_cookie(name, "", max_age: 0, path: path)
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

    def to_rack
      final_headers = @headers.dup
      @cookies.each_with_index do |cookie, i|
        if i == 0
          final_headers["set-cookie"] = cookie
        else
          existing = [final_headers["set-cookie"]].flatten
          final_headers["set-cookie"] = existing.push(cookie).join("\n")
        end
      end
      [@status, final_headers, [@body.to_s]]
    end

    def self.auto_detect(result, response)
      case result
      when Tina4::Response
        result
      when Hash, Array
        response.json(result)
      when String
        if result.strip.start_with?("<")
          response.html(result)
        else
          response.text(result)
        end
      when Integer
        response.status = result
        response.body = ""
        response
      when NilClass
        response.status = 204
        response.body = ""
        response
      else
        response.json(result.respond_to?(:to_hash) ? result.to_hash : { data: result.to_s })
      end
    end
  end
end
