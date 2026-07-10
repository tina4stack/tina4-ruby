# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"
require "base64"
require "securerandom"

module Tina4
  # Statuses that warrant an automatic retry when max_retries > 0: rate-limit
  # (429) plus the transient server-side 5xx family. 4xx client errors (401,
  # 404, …) are NOT retried — a repeat won't succeed. Parity with the Python
  # master's _RETRY_STATUSES.
  API_RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

  # Streaming download reads/writes this many bytes per chunk so a multi-megabyte
  # body never lands in memory in one piece. Parity with the Python master's
  # _DOWNLOAD_CHUNK_SIZE.
  API_DOWNLOAD_CHUNK_SIZE = 64 * 1024

  # Redirect codes we follow (301/302/303/307/308). Net::HTTP does NOT auto-follow,
  # so the client follows them itself in a bounded loop (see #network_call).
  API_REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

  # Upper bound on redirect hops before we stop following and return the last
  # 3xx response. Matches urllib's default (Python master).
  API_MAX_REDIRECTS = 10

  # Headers dropped when a redirect crosses to a different origin — a bearer
  # token or a session cookie must never be handed to a host you didn't
  # authenticate to. Compared case-insensitively. Parity with the Python
  # master's _STRIP_ON_CROSS_ORIGIN.
  API_STRIP_ON_CROSS_ORIGIN = %w[authorization cookie].freeze

  # A curated extension -> MIME map for guessing a multipart part's Content-Type
  # from its filename (Ruby core ships no mimetypes db, and pulling one in would
  # break the zero-dependency promise). tina4: a small built-in map covering the
  # common upload types; anything unlisted falls back to application/octet-stream.
  # Mirrors the guess-with-fallback the Python master gets from mimetypes.
  API_MIME_BY_EXTENSION = {
    "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
    "gif" => "image/gif", "webp" => "image/webp", "svg" => "image/svg+xml",
    "bmp" => "image/bmp", "ico" => "image/x-icon", "tif" => "image/tiff",
    "tiff" => "image/tiff",
    "pdf" => "application/pdf", "json" => "application/json",
    "xml" => "application/xml", "zip" => "application/zip",
    "gz" => "application/gzip", "tar" => "application/x-tar",
    "csv" => "text/csv", "txt" => "text/plain", "html" => "text/html",
    "htm" => "text/html", "css" => "text/css", "js" => "text/javascript",
    "md" => "text/markdown",
    "mp3" => "audio/mpeg", "wav" => "audio/wav", "ogg" => "audio/ogg",
    "mp4" => "video/mp4", "mov" => "video/quicktime", "webm" => "video/webm",
    "doc" => "application/msword",
    "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls" => "application/vnd.ms-excel",
    "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt" => "application/vnd.ms-powerpoint",
    "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  }.freeze

  class API
    attr_reader :base_url, :headers

    # 3.13.1: added ergonomic kwargs (bearer_token, username, password,
    # verify_ssl) so callers no longer need three follow-up setter calls.
    # Cross-framework parity with the Python tina4_python.api.Api kwargs.
    #
    #     api = Tina4::API.new("https://api.example.com", bearer_token: "sk-abc")
    #     api = Tina4::API.new("https://api.example.com", username: "u", password: "p")
    #     api = Tina4::API.new("https://api.example.com", headers: {"X-Tenant" => "acme"})
    #     api = Tina4::API.new("https://self-signed.local", verify_ssl: false)
    #
    # Bearer wins over basic-auth when both are passed.
    #
    # 3.13.39: +max_retries / +retry_backoff enable opt-in automatic retry with
    # exponential backoff (default max_retries: 0 = off, non-breaking) on a
    # transport error (APIResponse#status == 0) or a retryable status
    # (429/5xx). A retried non-idempotent request (POST/PUT/PATCH/DELETE) may be
    # re-sent — retries are opt-in for exactly that reason. Parity with the
    # Python master.
    #
    # 3.13.69: +transport (an injectable seam) and +cookies (an opt-in per-client
    # cookie jar), both parity with the Python master.
    #
    # `transport` (default nil = the real Net::HTTP network path) is an injectable
    # seam so that APPLICATION developers can unit-test their own code without a
    # live server. When supplied it must respond to #call with the signature
    # `call(method, url, headers, body, timeout)` and return a Hash shaped like
    # `{http_code:/status:, body:, headers:, error:}` (string or symbol keys). It
    # fully REPLACES the network call. NOTE: Tina4's own suite must NEVER inject a
    # fake/canned transport — the no-mock rule stands, so framework tests always
    # exercise the real network path against a real local server. The seam exists
    # purely for application-developer testing.
    #
    # `cookies` (default false = off, zero behaviour change) turns on a
    # per-client, in-memory cookie jar: `Set-Cookie` headers on responses are
    # parsed (leading name=value only, last write wins) and the accumulated
    # `Cookie` header is sent on subsequent requests. Not persisted; scoped to
    # this instance.
    def initialize(base_url, headers: {}, timeout: 30,
                   bearer_token: nil, username: nil, password: nil,
                   verify_ssl: nil, max_retries: 0, retry_backoff: 0.5,
                   transport: nil, cookies: false)
      if !transport.nil? && !transport.respond_to?(:call)
        raise ArgumentError, "transport must respond to #call(method, url, headers, body, timeout)"
      end

      @base_url = base_url.chomp("/")
      @headers = {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }.merge(headers)
      @timeout = timeout
      @verify_ssl = verify_ssl
      @max_retries = [0, max_retries.to_i].max
      @retry_backoff = retry_backoff.to_f
      @transport = transport
      @cookies_enabled = cookies ? true : false
      @cookies = {}

      # Bearer wins over basic-auth when both passed
      if bearer_token
        set_bearer_token(bearer_token)
      elsif username && password
        set_basic_auth(username, password)
      end
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

    # POST a multipart/form-data body — a file plus optional text fields.
    #
    # BREAKING (3.13.69): reconciled to the canonical cross-framework shape.
    # `file_path` was a REQUIRED positional; it is now a keyword. Two ways to
    # supply the file, so a caller never needs a temp file:
    #
    #   - file_path: — a file on disk. filename: defaults to its basename.
    #   - file_bytes: + filename: — an in-memory payload (String bytes).
    #
    # field_name: is the form field the file is sent under (default "file").
    # extra_fields: (Hash) become additional text parts. headers: (Hash) are
    # extra per-call headers merged onto the request. The part's Content-Type is
    # guessed from the filename (falling back to application/octet-stream) — this
    # replaces the old hard-coded application/octet-stream. The client's default
    # headers (including any Authorization) are sent too, unlike the old upload().
    #
    # Returns an APIResponse. A missing file or no source given returns a clean
    # error response (status 0, error set) — it does NOT raise, and nothing is
    # sent over the wire.
    #
    #   api.upload("/avatars", file_path: "/tmp/me.png")
    #   api.upload("/avatars", file_bytes: raw, filename: "me.png",
    #              extra_fields: { "user_id" => "42" })
    def upload(path, file_path: nil, field_name: "file", extra_fields: {},
               headers: {}, file_bytes: nil, filename: nil)
      unless file_bytes.nil?
        content = file_bytes.is_a?(String) ? file_bytes : file_bytes.to_s
        upload_name = filename || "upload.bin"
      end

      if content.nil? && file_path
        return error_response("file not found: #{file_path}") unless File.file?(file_path)

        begin
          content = File.binread(file_path)
        rescue SystemCallError => e
          return error_response(e.message)
        end
        upload_name = filename || File.basename(file_path)
      end

      return error_response("upload requires file_path or file_bytes") if content.nil?

      part_content_type = guess_content_type(upload_name)
      boundary = "----Tina4Boundary#{SecureRandom.hex(16)}"
      body = build_multipart_body(boundary, field_name, upload_name, content,
                                  part_content_type, extra_fields)

      uri = build_uri(path)
      request = Net::HTTP::Post.new(uri)
      request.body = body
      # Apply the client default headers (auth, etc.) FIRST, then force the
      # multipart Content-Type so it wins over the default application/json,
      # then any per-call headers last (parity with the Python master's order).
      apply_headers(request, {})
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      headers.each { |key, value| request[key] = value }
      execute(uri, request)
    end

    # Stream a GET response body to dest_path in chunks.
    #
    # The body is written to disk API_DOWNLOAD_CHUNK_SIZE bytes at a time instead
    # of being buffered whole in memory — safe for large payloads. Follows
    # redirects (with the same cross-origin auth/cookie strip as every verb) and
    # honours verify_ssl.
    #
    # Returns an APIResponse carrying `path` (and no body — it went to disk).
    # `path` is dest_path on success and nil on any error (missing dest, HTTP
    # error status, or a transport failure); the destination file is not written
    # on a pre-flight or HTTP-status error. status is 0 on a transport failure.
    def download(path, dest_path: nil, params: {})
      return error_response("download requires dest_path", path: nil) unless dest_path

      uri = build_uri(path, params)
      headers = @headers.dup
      cookie = cookie_header
      headers["Cookie"] = cookie if @cookies_enabled && cookie

      return download_via_transport(uri, headers, dest_path) if @transport

      begin
        result = network_call("GET", uri, headers, nil, stream_to: dest_path)
        code = result[:status]
        if result[:path]
          APIResponse.new(status: code, body: nil, headers: result[:headers],
                          error: nil, path: result[:path])
        else
          APIResponse.new(status: code, body: nil, headers: result[:headers],
                          error: "download failed (HTTP #{code})", path: nil)
        end
      rescue StandardError => e
        APIResponse.new(status: 0, body: nil, headers: {}, error: e.message, path: nil)
      end
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

    # Execute the request with opt-in retry/backoff. Returns an APIResponse.
    #
    # With @max_retries > 0, a transport error (APIResponse#status == 0, the
    # existing error sentinel) or a retryable status (429/5xx) is retried up to
    # @max_retries times with exponential backoff (@retry_backoff seconds base,
    # doubling each attempt); any other outcome (2xx, 3xx, other 4xx) returns at
    # once. Parity with the Python master's _request.
    def execute(uri, request)
      attempts = @max_retries + 1
      response = nil
      (0...attempts).each do |attempt|
        response = attempt_request(uri, request)
        code = response.status
        retryable = code.zero? || API_RETRY_STATUSES.include?(code)
        return response if !retryable || attempt == attempts - 1

        sleep(@retry_backoff * (2**attempt))
      end
      response
    end

    # A single HTTP attempt. Returns the standardized APIResponse. Dispatches to
    # the injected transport seam when one is set, else the real network path.
    def attempt_request(uri, request)
      method = request.method
      headers = {}
      request.each_header { |key, value| headers[key] = value }
      cookie = cookie_header
      headers["cookie"] = cookie if @cookies_enabled && cookie
      body = request.body

      if @transport
        transport_response(method, uri.to_s, headers, body)
      else
        result = network_call(method, uri, headers, body)
        APIResponse.new(status: result[:status], body: result[:body] || "",
                        headers: result[:headers], error: nil)
      end
    rescue StandardError => e
      APIResponse.new(status: 0, body: "", headers: {}, error: e.message)
    end

    # Perform a real HTTP round-trip via Net::HTTP, following redirects in a
    # bounded loop and stripping Authorization/Cookie on a cross-origin hop.
    # When stream_to is given, a 2xx body is streamed to that path in chunks
    # (never buffered whole) and no file is written on a non-2xx status.
    #
    # Returns { status:, headers:, body:, path: } (body nil when streamed; path
    # set only when a file was actually written). Raises on a transport failure
    # (caller turns that into a status-0 error response).
    def network_call(method, uri, headers, body, stream_to: nil)
      remaining = API_MAX_REDIRECTS
      current_method = method.to_s.upcase
      current_uri = uri.is_a?(URI) ? uri : URI.parse(uri.to_s)
      current_headers = headers.dup
      current_body = body

      loop do
        http = Net::HTTP.new(current_uri.host, current_uri.port)
        http.use_ssl = current_uri.scheme == "https"
        # Only disable verification when EXPLICITLY false — nil/true keep the
        # secure default (OpenSSL::SSL::VERIFY_PEER).
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @verify_ssl == false
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = build_net_request(current_method, current_uri, current_headers, current_body)

        status = nil
        resp_headers = {}
        body_string = nil
        wrote_file = false
        location = nil
        redirect_code = nil

        http.start do |conn|
          conn.request(request) do |response|
            status = response.code.to_i
            resp_headers = response.to_hash
            if API_REDIRECT_STATUSES.include?(status) && remaining.positive? && response["location"]
              response.read_body { |_chunk| } # drain (and discard) the redirect body
              location = response["location"]
              redirect_code = status
            else
              store_cookies(response.get_fields("Set-Cookie"))
              if stream_to && (200..299).cover?(status)
                # Stream to disk in API_DOWNLOAD_CHUNK_SIZE blocks. Net::HTTP's
                # read_body block yields socket-buffer-sized chunks; we coalesce
                # them and flush at the 64 KB threshold so the whole body never
                # lands in memory at once (bounded to ~one chunk + 64 KB).
                File.open(stream_to, "wb") do |file|
                  buffer = String.new(encoding: Encoding::BINARY)
                  response.read_body do |chunk|
                    buffer << chunk
                    if buffer.bytesize >= API_DOWNLOAD_CHUNK_SIZE
                      file.write(buffer)
                      buffer.clear
                    end
                  end
                  file.write(buffer) unless buffer.empty?
                end
                wrote_file = true
              elsif stream_to
                response.read_body { |_chunk| } # error status on a download: drain, write nothing
              else
                body_string = String.new(encoding: Encoding::BINARY)
                response.read_body { |chunk| body_string << chunk }
              end
            end
          end
        end

        if location
          new_uri = URI.join(current_uri.to_s, location)
          current_headers = strip_cross_origin(current_headers) unless same_origin?(current_uri, new_uri)
          # 301/302/303 downgrade a non-GET/HEAD to GET and drop the body
          # (matches urllib); 307/308 preserve method + body.
          if [301, 302, 303].include?(redirect_code) && !%w[GET HEAD].include?(current_method)
            current_method = "GET"
            current_body = nil
          end
          current_uri = new_uri
          remaining -= 1
          next
        end

        return { status: status, headers: resp_headers, body: body_string,
                 path: (wrote_file ? stream_to : nil) }
      end
    end

    # Build a Net::HTTP request object for one hop from a method/uri/headers/body.
    def build_net_request(method, uri, headers, body)
      klass = case method
              when "GET"    then Net::HTTP::Get
              when "POST"   then Net::HTTP::Post
              when "PUT"    then Net::HTTP::Put
              when "PATCH"  then Net::HTTP::Patch
              when "DELETE" then Net::HTTP::Delete
              when "HEAD"   then Net::HTTP::Head
              else Net::HTTP::Get
              end
      request = klass.new(uri)
      headers.each do |key, value|
        request[key] = value.is_a?(Array) ? value.first : value
      end
      request.body = body if body && !%w[GET HEAD].include?(method)
      request
    end

    # Invoke a user-injected transport and normalize its result into an
    # APIResponse. The transport fully replaces the network call.
    def transport_response(method, url, headers, body)
      result = @transport.call(method, url, headers, body, @timeout)
      result = {} unless result.is_a?(Hash)
      store_cookies(set_cookie_values(result_value(result, :headers)))
      APIResponse.new(
        status: (result_value(result, :http_code, :status) || 0).to_i,
        body: result_value(result, :body) || "",
        headers: result_value(result, :headers) || {},
        error: result_value(result, :error)
      )
    end

    # download() over the transport seam: the transport returns a buffered body,
    # so write it out (only on a 2xx) instead of streaming. Mirrors the Python
    # master's transport branch of download().
    def download_via_transport(uri, headers, dest_path)
      result = @transport.call("GET", uri.to_s, headers, nil, @timeout)
      result = {} unless result.is_a?(Hash)
      store_cookies(set_cookie_values(result_value(result, :headers)))
      code = (result_value(result, :http_code, :status) || 0).to_i
      error = result_value(result, :error)
      resp_headers = result_value(result, :headers) || {}

      if error.nil? && (200..299).cover?(code)
        data = result_value(result, :body).to_s
        begin
          File.binwrite(dest_path, data)
        rescue SystemCallError => e
          return APIResponse.new(status: code, body: nil, headers: resp_headers, error: e.message, path: nil)
        end
        APIResponse.new(status: code, body: nil, headers: resp_headers, error: nil, path: dest_path)
      else
        APIResponse.new(status: code, body: nil, headers: resp_headers,
                        error: error || "download failed (HTTP #{code})", path: nil)
      end
    rescue StandardError => e
      APIResponse.new(status: 0, body: nil, headers: {}, error: e.message, path: nil)
    end

    # Assemble a multipart/form-data body as raw bytes. Text fields come first,
    # then the file part, then the closing delimiter — byte-identical to the
    # Python master's _build_multipart_body so every framework produces the same
    # layout. Built as a BINARY string so raw file bytes concatenate cleanly.
    def build_multipart_body(boundary, field_name, filename, content, content_type, extra_fields)
      crlf = "\r\n"
      body = String.new(encoding: Encoding::BINARY)
      (extra_fields || {}).each do |key, value|
        body << "--#{boundary}#{crlf}".b
        body << %(Content-Disposition: form-data; name="#{key}"#{crlf}#{crlf}).b
        body << "#{value}#{crlf}".b
      end
      body << "--#{boundary}#{crlf}".b
      body << %(Content-Disposition: form-data; name="#{field_name}"; filename="#{filename}"#{crlf}).b
      body << "Content-Type: #{content_type}#{crlf}#{crlf}".b
      body << content.b
      body << crlf.b
      body << "--#{boundary}--#{crlf}".b
      body
    end

    # Guess a multipart part's Content-Type from a filename extension, falling
    # back to application/octet-stream (parity with the Python master).
    def guess_content_type(filename)
      ext = File.extname(filename.to_s).delete_prefix(".").downcase
      API_MIME_BY_EXTENSION[ext] || "application/octet-stream"
    end

    # True when two URLs share scheme + host + (effective) port.
    def same_origin?(uri_a, uri_b)
      a = uri_a.is_a?(URI) ? uri_a : URI.parse(uri_a.to_s)
      b = uri_b.is_a?(URI) ? uri_b : URI.parse(uri_b.to_s)
      defaults = { "http" => 80, "https" => 443 }
      port_a = a.port || defaults[a.scheme]
      port_b = b.port || defaults[b.scheme]
      a.scheme == b.scheme && a.host == b.host && port_a == port_b
    end

    def strip_cross_origin(headers)
      headers.reject { |key, _| API_STRIP_ON_CROSS_ORIGIN.include?(key.to_s.downcase) }
    end

    # Fetch a value from a Hash trying each key as both a symbol and a string.
    def result_value(result, *keys)
      keys.each do |key|
        return result[key] if result.key?(key)

        string_key = key.to_s
        return result[string_key] if result.key?(string_key)
      end
      nil
    end

    # ── cookie jar (opt-in, in-memory, per-client) ─────────────────────────
    # The accumulated Cookie request header, or nil when the jar is empty.
    def cookie_header
      return nil if @cookies.empty?

      @cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    # Parse Set-Cookie response header values into the jar (when enabled). Only
    # the leading name=value pair of each Set-Cookie is kept (attributes like
    # Path/HttpOnly/Expires are ignored); a later value for the same name
    # overwrites an earlier one. Parity with the Python master's _store_cookies.
    def store_cookies(values)
      return unless @cookies_enabled

      Array(values).each do |raw|
        next if raw.nil? || raw.empty?

        first_pair = raw.split(";", 2).first.to_s.strip
        name, separator, value = first_pair.partition("=")
        next if separator.empty?

        name = name.strip
        @cookies[name] = value.strip unless name.empty?
      end
    end

    # Extract Set-Cookie values from a plain headers Hash (the transport seam
    # returns a Hash, not a Net::HTTPResponse). Values may be a String or Array.
    def set_cookie_values(headers)
      return [] unless headers.is_a?(Hash)

      values = []
      headers.each do |key, value|
        next unless key.to_s.downcase == "set-cookie"

        Array(value).each { |item| values << item }
      end
      values
    end

    def error_response(message, path: :__none__)
      if path == :__none__
        APIResponse.new(status: 0, body: "", headers: {}, error: message)
      else
        APIResponse.new(status: 0, body: nil, headers: {}, error: message, path: path)
      end
    end
  end

  class APIResponse
    attr_reader :status, :body, :headers, :error, :path

    # `path` (default nil) is populated by API#download — the on-disk path the
    # streamed body was written to (nil on error). It is nil for every other verb.
    def initialize(status:, body:, headers:, error: nil, path: nil)
      @status = status
      @body = body
      @headers = headers
      @error = error
      @path = path
    end

    def success?
      @status >= 200 && @status < 300
    end

    def json
      @json ||= JSON.parse(@body)
    rescue JSON::ParserError, TypeError
      {}
    end

    def to_s
      "APIResponse(status=#{@status})"
    end
  end
end
