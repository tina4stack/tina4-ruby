# frozen_string_literal: true
require "uri"
require "json"
require "ipaddr"

module Tina4
  # A Hash subclass that supports indifferent access (both string and symbol keys).
  # Used by Request#params so that params[:id] and params["id"] both work.
  class IndifferentHash < Hash
    def [](key)
      super(convert_key(key))
    end

    def []=(key, value)
      super(convert_key(key), value)
    end

    def fetch(key, *args, &block)
      super(convert_key(key), *args, &block)
    end

    def key?(key)
      super(convert_key(key))
    end
    alias has_key? key?
    alias include? key?

    def delete(key, &block)
      super(convert_key(key), &block)
    end

    private

    def convert_key(key)
      key.is_a?(Symbol) ? key.to_s : key
    end
  end

  # Per-file upload hash: indifferent access plus a lazily-materialised
  # `content` field. The raw bytes are read from the tempfile only on first
  # access to `content` (then rewound, so :tempfile streaming still works),
  # so :tempfile-only handlers never buffer large uploads in memory.
  class FileUpload < IndifferentHash
    def [](key)
      if key.to_s == "content" && !key?("content") && (tf = super("tempfile"))
        self["content"] = begin
          tf.rewind if tf.respond_to?(:rewind)
          data = tf.read
          tf.rewind if tf.respond_to?(:rewind)
          data
        rescue StandardError
          nil
        end
      end
      super(key)
    end
  end

  # Hash subclass for HTTP headers — string keys are case-insensitive.
  #
  # HTTP header field-names are case-insensitive per RFC 7230 §3.2. With
  # this class, request.headers["Content-Type"], .headers["content-type"],
  # and .headers["CONTENT-TYPE"] all return the same value. Keys are
  # stored lowercase internally.
  #
  # Cross-framework parity: same behaviour ships in tina4-python
  # (CaseInsensitiveDict), tina4-php (Tina4\Request), tina4-nodejs
  # (Tina4Request). tina4-book#141 PY-10-03 — chapter 10 examples
  # documented headers["Content-Type"] for years; this makes them work.
  class CaseInsensitiveHash < Hash
    def [](key)
      super(normalize_key(key))
    end

    def []=(key, value)
      super(normalize_key(key), value)
    end

    def fetch(key, *args, &block)
      super(normalize_key(key), *args, &block)
    end

    def key?(key)
      super(normalize_key(key))
    end
    alias has_key? key?
    alias include?  key?
    alias member?   key?

    def delete(key, &block)
      super(normalize_key(key), &block)
    end

    def store(key, value)
      super(normalize_key(key), value)
    end

    def merge(other)
      result = dup
      other.each { |k, v| result[k] = v }
      result
    end

    def merge!(other)
      other.each { |k, v| self[k] = v }
      self
    end

    private

    def normalize_key(key)
      key.is_a?(String) ? key.downcase : key
    end
  end

  class Request
    attr_reader :env, :method, :path, :query_string, :content_type,
                :path_params, :ip, :remote_ip
    # :route is the matched Route, attached by the dispatcher before post-match
    # middleware runs (DispatchPipeline#prepare_route_request). CsrfMiddleware
    # reads route.auth_required to honour a public write route (.no_auth).
    attr_accessor :user, :route

    # Maximum upload size in bytes (default 10 MB). Override via TINA4_MAX_UPLOAD_SIZE env var.
    TINA4_MAX_UPLOAD_SIZE = Integer(ENV.fetch("TINA4_MAX_UPLOAD_SIZE", 10_485_760))

    class PayloadTooLarge < StandardError; end

    def initialize(env, path_params = {})
      @env = env
      @method = env["REQUEST_METHOD"]
      @path = env["PATH_INFO"] || "/"
      @query_string = env["QUERY_STRING"] || ""
      @content_type = env["CONTENT_TYPE"] || ""
      @path_params = path_params

      # Check upload size limit
      content_length = (env["CONTENT_LENGTH"] || 0).to_i
      if content_length > TINA4_MAX_UPLOAD_SIZE
        raise PayloadTooLarge,
          "Request body (#{content_length} bytes) exceeds TINA4_MAX_UPLOAD_SIZE (#{TINA4_MAX_UPLOAD_SIZE} bytes)"
      end

      # Raw socket peer — NEVER honours X-Forwarded-For, so it can be trusted
      # for security decisions. Resolved BEFORE @ip: the peer decides whether
      # the forwarding headers may be believed at all.
      @remote_ip = (env["REMOTE_ADDR"] || "").to_s
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

    # Is this request HTTPS from the CLIENT's point of view?
    #
    # TLS is normally terminated at a proxy (nginx, HAProxy, ALB, Cloudflare,
    # most container deploys) that then forwards plain HTTP to the app, so
    # rack.url_scheme is "http" on exactly the deployments that ARE encrypted.
    # x-forwarded-proto carries the scheme the client actually used, and a
    # chain of proxies appends each hop ("https, http") — the FIRST is the
    # client-facing one. Falls back to the native rack scheme, then the CGI
    # HTTPS var.
    #
    # This is the single source of truth for BOTH the URL scheme (#url) and the
    # session-cookie Secure flag (Session#cookie_header). They used to decide it
    # independently and could disagree — url() said https while the cookie
    # concluded plain HTTP and dropped Secure (ruby#31, parity with PHP
    # Request::isSecureScheme / tina4-php#175).
    #
    # @param env [Hash] the Rack environment.
    # @return [Boolean] true when the client's scheme is https.
    def self.secure_scheme?(env)
      forwarded = (env["HTTP_X_FORWARDED_PROTO"] || "").to_s
      unless forwarded.strip.empty?
        return forwarded.split(",").first.to_s.strip.casecmp("https").zero?
      end
      scheme = (env["rack.url_scheme"] || "").to_s
      return true if scheme.casecmp("https").zero?
      https = (env["HTTPS"] || "").to_s
      !https.empty? && https.casecmp("off") != 0
    end

    # Full absolute URL — scheme://host[:port]/path[?query].
    # Honours X-Forwarded-Proto / X-Forwarded-Host so apps behind a proxy
    # still see the URL the client used. Matches Python/PHP/Node parity.
    def url
      scheme = self.class.secure_scheme?(env) ? "https" : "http"
      host = env["HTTP_X_FORWARDED_HOST"] || env["HTTP_HOST"] || env["SERVER_NAME"] || "localhost"
      port = env["SERVER_PORT"]
      url_str = "#{scheme}://#{host}"
      # Only append :port when the host doesn't already include one
      # (HTTP_HOST often does) and it's not the default for the scheme.
      url_str += ":#{port}" if port && !host.include?(":") && port.to_s != "80" && port.to_s != "443"
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

    # The session for THIS request.
    #
    # degrade_on_backend_failure: this is the live request path, so a storage
    # handler that cannot be built (an unreachable database, a refused backend
    # name) is LOGGED and then degraded to an in-memory-only session rather than
    # unwinding into RackApp's 500 handler and taking the request down with it
    # (ADR-0021). TINA4_SESSION_STRICT still re-raises. Direct Session.new
    # callers keep the loud raise - see the guard in Session#initialize.
    def session
      @session ||= Tina4::Session.new(@env, degrade_on_backend_failure: true)
    end

    # Parsed body (JSON -> Hash, form-urlencoded -> Hash, multipart ->
    # fields Hash, else the current fallback). This matches Python's
    # `request.body`, PHP's, and Node's: `body` is the PARSED payload, not
    # the raw bytes. For the raw string use `body_raw`.
    def body
      @body_parsed ||= parse_body
    end

    # Raw body string — the bytes exactly as the client sent them.
    # (This is what `body` used to return before the cross-framework
    # parity flip; SOAP/GraphQL and any consumer that needs the raw text
    # reads this.)
    def body_raw
      @body_raw ||= read_body
    end

    # Backwards-compatible alias of `body` — both return the parsed payload.
    alias body_parsed body

    # Parsed query string as hash
    def query
      @query_hash ||= parse_query_to_hash(@query_string)
    end

    def files
      @files ||= extract_files
    end

    # Merged params: query + body + path_params (path_params highest priority)
    # Supports both string and symbol key access (indifferent access).
    # Attach the matched route's path params AFTER construction.
    #
    # The request is built BEFORE route matching now, so pre-match middleware
    # has something to read and mutate. Path params are only known once a route
    # has matched, so they are set here and the memoised #params is dropped -
    # without that reset a pre-match middleware that touched #params would
    # freeze a param-less copy for the handler.
    def path_params=(value)
      @path_params = value || {}
      @params = nil
    end

    attr_reader :path_params

    def params
      @params ||= build_params
    end

    # Look up a param by symbol or string key (indifferent access shortcut).
    def param(key, default = nil)
      params[key.to_s] || params[key.to_sym] || default
    end

    def [](key)
      params[key.to_s] || params[key.to_sym] || @path_params[key.to_sym]
    end

    def header(name)
      # Headers are stored in a CaseInsensitiveHash keyed by lowercase-
      # dashed names ("content-type", "x-api-key"). The hash normalises
      # the lookup case automatically, so pass the dashed form through.
      headers[name.to_s.tr("_", "-")]
    end

    def json_body
      @json_body ||= begin
        JSON.parse(body_raw)
      rescue JSON::ParserError, TypeError
        {}
      end
    end

    def bearer_token
      auth = header("authorization") || ""
      auth.sub(/\ABearer\s+/i, "") if auth =~ /\ABearer\s+/i
    end

    private

    # Resolve the client IP, honouring forwarding headers ONLY behind a trusted
    # proxy. X-Forwarded-For is set by whoever sends it, so an unfiltered read
    # lets any client choose its own rate-limit bucket - and choose SOMEONE
    # ELSE'S. See ADR-0019.
    #
    # Within the chain the RIGHTMOST entry that is not itself a trusted proxy
    # wins. Taking the leftmost would be no safer than trusting the header
    # outright: a client can prepend its own hop, and the proxy appends rather
    # than replaces. This is the algorithm Rack uses (Rack::Request#ip).
    def extract_client_ip
      peer = @remote_ip.to_s
      return peer.empty? ? "127.0.0.1" : peer unless Tina4.trusted_proxy?(peer)

      forwarded = @env["HTTP_X_FORWARDED_FOR"]
      if forwarded && !forwarded.empty?
        hops = forwarded.split(",").map(&:strip).reject(&:empty?)
        client = hops.reverse.find { |hop| !Tina4.trusted_proxy?(hop) }
        # Every hop is itself a trusted proxy - the peer is the best we have.
        return client || peer
      end

      real_ip = @env["HTTP_X_REAL_IP"].to_s.strip
      real_ip.empty? ? peer : real_ip
    end

    def extract_headers
      h = CaseInsensitiveHash.new
      @env.each do |key, value|
        if key.start_with?("HTTP_")
          # Rack normalises "Content-Type" to "HTTP_CONTENT_TYPE" — we
          # store as "content-type" (lowercase, dashed) so both
          # headers["Content-Type"] and the legacy headers["content_type"]
          # via the `header()` helper resolve to the same value. The
          # CaseInsensitiveHash handles the case-insensitive part.
          h[key[5..-1].tr("_", "-").downcase] = value
        end
      end
      # CONTENT_TYPE / CONTENT_LENGTH live at the top level of the Rack
      # env (no HTTP_ prefix per the Rack spec) — surface them too so
      # request.headers["Content-Type"] works for POST bodies.
      h["content-type"] = @env["CONTENT_TYPE"] if @env["CONTENT_TYPE"] && !@env["CONTENT_TYPE"].empty?
      h["content-length"] = @env["CONTENT_LENGTH"] if @env["CONTENT_LENGTH"] && !@env["CONTENT_LENGTH"].to_s.empty?
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

    # Resolve the parsed multipart form fields (+ file entries) for this request.
    #
    # A live Rack server (Puma/WEBrick) does NOT parse the request body for us -
    # it hands the app the raw `rack.input` stream. `Rack::Request#POST` parses
    # a multipart (or urlencoded) body and caches the result into the standard
    # `rack.request.form_hash` env key, which both #parse_body and #extract_files
    # then read. We only invoke it when the key isn't already populated, so a
    # spec that injects `rack.request.form_hash` directly still short-circuits
    # here (and we never re-parse a body twice). Without this, live multipart
    # uploads arrived empty (fields AND files) - the parse only ran in specs.
    def multipart_form_hash
      existing = @env["rack.request.form_hash"] rescue nil
      return existing if existing

      parsed = begin
        require "rack"
        Rack::Request.new(@env).POST
      rescue StandardError => e
        Tina4::Log.warning("multipart parse failed: #{e.message}") if defined?(Tina4::Log)
        nil
      end
      @env["rack.request.form_hash"] || parsed
    end

    def parse_body
      if @content_type.include?("application/json")
        json_body
      elsif @content_type.include?("application/x-www-form-urlencoded")
        parse_query_to_hash(body_raw)
      elsif @content_type.include?("multipart/form-data")
        # Extract form fields from Rack's parsed multipart data.
        # Files are handled separately by extract_files.
        result = {}
        form_hash = multipart_form_hash
        if form_hash
          form_hash.each do |key, value|
            # Skip file entries (handled by extract_files)
            next if value.is_a?(Hash) && value[:tempfile]
            result[key] = value
          end
        end
        result
      else
        {}
      end
    end

    def build_params
      p = IndifferentHash.new

      # Query string params
      query.each { |k, v| p[k.to_s] = v }

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
        form_hash = multipart_form_hash
        if form_hash
          form_hash.each do |key, value|
            if value.is_a?(Hash) && value[:tempfile]
              tempfile = value[:tempfile]

              # Indifferent-access per-file hash so file["content"],
              # file[:content], file["filename"], file[:filename] all work.
              # `content` (raw bytes, never base64) is materialised lazily on
              # first access (see FileUpload) — :tempfile-only handlers never
              # buffer large uploads in memory.
              file = FileUpload.new
              file[:filename] = value[:filename]
              file[:type]     = value[:type]
              file[:tempfile] = tempfile
              file[:size]     = tempfile.size
              result[key] = file
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
