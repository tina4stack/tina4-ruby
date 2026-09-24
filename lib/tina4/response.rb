# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "json"
require "uri"

module Tina4
  # ---------------------------------------------------------------------------
  # Global Frond template engine registry
  # ---------------------------------------------------------------------------
  @_global_frond = nil
  @_framework_frond = nil

  # Return the global Frond engine, creating a default if needed.
  def self.get_frond
    @_global_frond ||= Tina4::Frond.new(template_dir: "src/templates")
  end

  # Return the singleton Frond engine for built-in framework templates.
  def self.get_framework_frond
    framework_dir = ::File.join(::File.dirname(__FILE__), "templates")
    if @_framework_frond.nil? && ::File.directory?(framework_dir)
      @_framework_frond = Tina4::Frond.new(template_dir: framework_dir)
    end
    # Sync custom filters/globals from the user engine
    if @_framework_frond
      user_engine = get_frond
      @_framework_frond.instance_variable_get(:@filters).merge!(user_engine.instance_variable_get(:@filters))
      @_framework_frond.instance_variable_get(:@globals).merge!(user_engine.instance_variable_get(:@globals))
    end
    @_framework_frond
  end

  # Register a pre-configured Frond engine for response.render().
  def self.set_frond(engine)
    @_global_frond = engine
  end

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

    # ADR-0068: a header name must be an RFC 9110 token, and a header value,
    # redirect location or cookie attribute may never carry CR, LF or NUL (a
    # cookie attribute not ';' either). They are REFUSED where the developer
    # sets them - never stripped - so the stack trace points at the line that
    # built the value. The messages are identical in all four frameworks.
    HEADER_TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    UNSAFE_HEADER_VALUE = /[\r\n\0]/
    UNSAFE_COOKIE_CONTENT = /[\r\n\0;]/

    def self.check_header!(name, value)
      unless name.to_s.match?(HEADER_TOKEN)
        raise ArgumentError, "Header name must be a valid HTTP token [#{JSON.generate(name.to_s)}]"
      end
      return value unless value.to_s.match?(UNSAFE_HEADER_VALUE)

      raise ArgumentError, "Invalid character in header content [#{JSON.generate(name.to_s)}]"
    end

    def initialize
      @status_code = 200
      @headers = { "content-type" => HTML_CONTENT_TYPE }
      @body = ""
      @cookies = nil  # Lazy -- most responses have no cookies
      @content_type_from_header = false
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
      Response.check_header!("Content-Type", content_type) if content_type
      @status_code = status_code
      data = jsonable(data)
      if content_type
        @headers["content-type"] = content_type
        @body = data.is_a?(Hash) || data.is_a?(Array) ? JSON.generate(data) : data.to_s
      elsif data.is_a?(Hash) || data.is_a?(Array)
        detected_content_type(JSON_CONTENT_TYPE)
        @body = JSON.generate(data)
      else
        detected_content_type(HTML_CONTENT_TYPE)
        @body = data.to_s
      end
      self
    end

    def json(data, status_or_opts = nil, status: nil)
      @status_code = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 200)
      @headers["content-type"] = JSON_CONTENT_TYPE
      data = jsonable(data)
      @body = data.is_a?(String) ? data : JSON.generate(data)
      self
    end

    # Normalise domain objects into JSON-serialisable structures so handlers can
    # `response.(model)` / `response.json(model)` without calling .to_h by hand:
    #
    #   response.json(user)            # ORM model      -> Hash
    #   response.json(User.all)        # Array<ORM>      -> Array<Hash>
    #   response.json(db.fetch(sql))   # DatabaseResult  -> Array<Hash>
    #
    # Plain Hash / Array / String pass through unchanged (Array members that are
    # models are still converted).
    def jsonable(data)
      return data.to_h if data.is_a?(Tina4::ORM)
      return data.records if data.is_a?(Tina4::DatabaseResult)
      return data.map { |item| item.is_a?(Tina4::ORM) ? item.to_h : item } if data.is_a?(Array)

      data
    end
    private :jsonable

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
      disposition = Response.check_header!("Content-Disposition", "attachment; filename=\"#{filename}\"")
      @status_code = status
      @headers["content-type"] = "text/csv"
      @headers["content-disposition"] = disposition
      @body = content.to_s
      self
    end

    def redirect(url, status_or_opts = nil, status: nil)
      Response.check_header!("Location", url)
      @status_code = status || (status_or_opts.is_a?(Integer) ? status_or_opts : 302)
      @headers["location"] = url
      @body = ""
      self
    end

    def file(path, content_type: nil, download: false, root: nil)
      Response.check_header!("Content-Type", content_type) if content_type
      # SECURITY: confine the read. The natural spelling of a download route,
      #
      #     response.file("downloads/" + name)   # name = "../secret.env"
      #
      # used to serve any file the process could read - measured at 200 with
      # the contents of a .env one directory above the intended one.
      #
      # TWO checks. Containment ALONE does not close it: that payload lands on
      # <project>/secret.env, which IS inside the project root, and the project
      # root is exactly where .env lives. Rejecting ".." on the way in is the
      # check that closes it; containment then catches absolute paths and
      # symlinks, neither of which carries a ".." segment.
      # Containment ONLY when a root is declared; defaulting to Dir.pwd broke
      # every legitimate absolute path.
      base = root ? ::File.expand_path(root) : nil
      forbidden = path.to_s.split(%r{[\\/]}).include?("..")

      unless forbidden
        candidate = (base.nil? || ::File.absolute_path?(path.to_s)) ? path.to_s : ::File.join(base, path.to_s)
        resolved =
          begin
            ::File.realpath(candidate)
          rescue Errno::ENOENT, Errno::ELOOP, Errno::ENAMETOOLONG, Errno::EACCES
            nil
          end
        if resolved && base && base != ::File::SEPARATOR &&
           resolved != base && !resolved.start_with?(base + ::File::SEPARATOR)
          forbidden = true
        end
        path = resolved || candidate
      end

      if forbidden
        # Refuse BEFORE reading: never load bytes we will not send.
        @status_code = 403
        @headers["content-type"] = "text/plain"
        @body = "Forbidden"
        return self
      end

      unless ::File.exist?(path)
        @status_code = 404
        @headers["content-type"] = "text/plain"
        @body = "File not found"
        return self
      end
      ext = ::File.extname(path).downcase
      @headers["content-type"] = content_type || MIME_TYPES[ext] || "application/octet-stream"
      if download
        @headers["content-disposition"] =
          Response.check_header!("Content-Disposition", "attachment; filename=\"#{::File.basename(path)}\"")
      end
      @body = ::File.binread(path)
      self
    end

    # Render a Frond/Twig template file with data and return self. Tries
    # the user template directory first, falling back to the framework's
    # built-in templates. Sets the response body to the rendered HTML.
    def render(template_path, data = {}, status: 200, template_dir: nil)
      @status_code = status
      @headers["content-type"] = HTML_CONTENT_TYPE

      engine = template_dir ? Tina4::Frond.new(template_dir: template_dir) : Tina4.get_frond

      # Try user templates first
      begin
        @body = engine.render(template_path, data)
        return self
      rescue Errno::ENOENT
        # Not found in user templates — try framework templates
      rescue => e
        @body = "<pre>Template error: #{e.message}</pre>"
        @status_code = 500
        return self
      end

      # Fallback: framework templates
      fw_engine = Tina4.get_framework_frond
      if fw_engine
        begin
          @body = fw_engine.render(template_path, data)
          return self
        rescue Errno::ENOENT
          # Not found in framework templates either
        rescue => e
          @body = "<pre>Template error: #{e.message}</pre>"
          @status_code = 500
          return self
        end
      end

      @body = "<pre>Template not found: #{template_path}</pre>"
      @status_code = 404
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
    #   response.json(Tina4::Response.error_response("NOT_FOUND", "Resource not found", 404), status: 404)
    #
    def self.error_response(code, message, status = 400)
      { error: true, code: code, message: message, status: status }
    end

    # Chainable header setter. Content-Type (any case) is not a second header:
    # it replaces the response's one content type, and call(data) keeps it
    # instead of detecting one (ADR-0072, tina4-python#144).
    def header(name, value = nil)
      if value.nil?
        @headers[content_type_key?(name) ? "content-type" : name]
      else
        set_header(name, Response.check_header!(name, value))
        self
      end
    end

    # Chainable cookie setter
    def cookie(name, value, opts = {})
      set_cookie(name, value, opts)
    end

    # The value is percent-encoded on the way out, so it can never carry CR,
    # LF, NUL or ';' to the wire and is not refused (ADR-0068 keeps encoding
    # where a framework already did). The name and every attribute are refused.
    def set_cookie(name, value, opts = {})
      label = JSON.generate(name.to_s)
      raise ArgumentError, "Cookie name must be a valid HTTP token [#{label}]" unless name.to_s.match?(HEADER_TOKEN)
      if [opts[:path], opts[:same_site], opts[:max_age]].any? { |attribute| attribute.to_s.match?(UNSAFE_COOKIE_CONTENT) }
        raise ArgumentError, "Invalid character in cookie content [#{label}]"
      end

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
      set_header(key, Response.check_header!(key, value))
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

    # Stream a response for Server-Sent Events (SSE) / chunked transfer.
    #
    # Two equivalent call styles (cross-framework parity — Python/PHP/Node
    # pass a generator positionally; Ruby additionally supports a block):
    #
    #   # 1. Positional generator (Enumerator, or anything responding to
    #   #    #each or #call that yields string chunks):
    #   gen = Enumerator.new do |y|
    #     10.times { |i| y << "data: message #{i}\n\n" }
    #   end
    #   response.stream(gen)
    #
    #   # 2. Block form (unchanged):
    #   Tina4::Router.get "/events" do |request, response|
    #     response.stream do |out|
    #       10.times do |i|
    #         out << "data: message #{i}\n\n"
    #         sleep 1
    #       end
    #     end
    #   end
    #
    # @param generator [#each, #call, nil] Optional source of string chunks.
    # @param content_type [String] Content type (default: text/event-stream)
    # @yield [Enumerator::Yielder] Block receives a yielder to push chunks
    # @return [self]
    def stream(generator = nil, content_type: "text/event-stream", &block)
      Response.check_header!("Content-Type", content_type)
      @status_code = @status_code || 200
      @headers["content-type"] = content_type
      @headers["cache-control"] = "no-cache"
      @headers["connection"] = "keep-alive"
      @headers["x-accel-buffering"] = "no"
      @_streaming = true
      @_stream_generator = generator
      @_stream_block = block
      self
    end

    # Finalize and return the response — matches Python/Node API.
    def send(data = nil, status_code: nil, content_type: nil)
      Response.check_header!("Content-Type", content_type) if content_type
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

    def content_type_key?(name)
      name.to_s.casecmp?("content-type")
    end

    def set_header(name, value)
      if content_type_key?(name)
        @headers["content-type"] = value
        @content_type_from_header = true
      else
        @headers[name] = value
      end
    end

    # A detected content type never replaces one the route set with header().
    def detected_content_type(content_type)
      @headers["content-type"] = content_type unless @content_type_from_header
    end
    private :content_type_key?, :set_header, :detected_content_type

    def to_rack
      final_headers = @headers.dup
      final_headers["set-cookie"] = @cookies.join("\n") if @cookies && !@cookies.empty?

      if @_streaming
        # Streaming mode — return an Enumerator as the Rack body. A positional
        # generator wins over a block when both are somehow present.
        gen = @_stream_generator
        blk = @_stream_block
        body = Enumerator.new do |yielder|
          # SSE hardening: a streaming source that raises mid-stream (a
          # generator/block error, or the client disconnecting and the server
          # tearing the body down) must NEVER crash the worker. We catch the
          # error, log it, and end the stream cleanly — the chunks emitted
          # before the failure are still delivered.
          #
          # A client disconnect surfaces in a hijack/Puma streaming body as a
          # write-side IOError/Errno on the socket; that is propagated up as a
          # normal stop and re-raised so Rack/Puma can close the connection,
          # while a *source* error is swallowed after logging.
          begin
            if gen
              if gen.respond_to?(:each)
                # Enumerator / array / any Enumerable of string chunks
                gen.each { |chunk| yielder << chunk }
              elsif gen.respond_to?(:call)
                # Callable that receives the yielder, like the block form
                gen.call(yielder)
              else
                yielder << gen.to_s
              end
            elsif blk
              blk.call(yielder)
            end
          rescue IOError, Errno::EPIPE, Errno::ECONNRESET => e
            # Client disconnected mid-stream — stop cleanly, do not crash, and
            # do not log loudly (a normal browser closing an SSE stream).
            Tina4::Log.debug("SSE/stream client disconnected: #{e.class}: #{e.message}") if defined?(Tina4::Log)
          rescue StandardError => e
            # The source (generator/block) itself raised mid-stream. Log it and
            # end the stream cleanly rather than crashing the handler/worker.
            Tina4::Log.error("SSE/stream source error: #{e.class}: #{e.message}") if defined?(Tina4::Log)
          end
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
