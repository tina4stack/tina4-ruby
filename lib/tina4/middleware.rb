# frozen_string_literal: true

module Tina4
  class Middleware
    class << self
      def before_handlers
        @before_handlers ||= []
      end

      def after_handlers
        @after_handlers ||= []
      end

      # Registry of class-based middleware (registered via Router.use)
      def global_middleware
        @global_middleware ||= []
      end

      def before(pattern = nil, &block)
        before_handlers << { pattern: pattern, handler: block }
      end

      def after(pattern = nil, &block)
        after_handlers << { pattern: pattern, handler: block }
      end

      # Register a class-based middleware globally.
      # The class should define static before_* and/or after_* methods.
      def use(klass)
        global_middleware << klass unless global_middleware.include?(klass)
      end

      def clear!
        @before_handlers = []
        @after_handlers = []
        @global_middleware = []
      end

      # Run all "before" hooks: block-based handlers, then class-based before_* methods.
      # Returns [request, response] on success, or false to halt the request.
      def run_before(request, response)
        # 1. Block-based before handlers (backward compat)
        before_handlers.each do |entry|
          next unless matches_pattern?(request.path, entry[:pattern])
          result = entry[:handler].call(request, response)
          return false if result == false
        end

        # 2. Class-based middleware: call every before_* method
        global_middleware.each do |klass|
          before_methods_for(klass).each do |method_name|
            result = klass.send(method_name, request, response)
            # Support returning [request, response] (Python convention) or false to halt
            if result == false
              return false
            elsif result.is_a?(Array) && result.length == 2
              request, response = result
              # If response already has a non-2xx status, halt processing
              return false if response.status_code >= 400
            end
          end
        end

        true
      end

      # Run all "after" hooks: block-based handlers, then class-based after_* methods.
      def run_after(request, response)
        # 1. Block-based after handlers (backward compat)
        after_handlers.each do |entry|
          next unless matches_pattern?(request.path, entry[:pattern])
          entry[:handler].call(request, response)
        end

        # 2. Class-based middleware: call every after_* method
        global_middleware.each do |klass|
          after_methods_for(klass).each do |method_name|
            result = klass.send(method_name, request, response)
            if result.is_a?(Array) && result.length == 2
              request, response = result
            end
          end
        end
      end

      private

      def matches_pattern?(path, pattern)
        return true if pattern.nil?
        case pattern
        when String
          path.start_with?(pattern)
        when Regexp
          pattern.match?(path)
        else
          true
        end
      end

      # Collect all public class methods matching before_*
      def before_methods_for(klass)
        klass.methods(false).select { |m| m.to_s.start_with?("before_") }.sort
      end

      # Collect all public class methods matching after_*
      def after_methods_for(klass)
        klass.methods(false).select { |m| m.to_s.start_with?("after_") }.sort
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in class-based middleware
  # ---------------------------------------------------------------------------

  # CorsClassMiddleware -- sets CORS headers from env vars on every response.
  # Uses the same config source as CorsMiddleware module.
  class CorsClassMiddleware
    class << self
      def before_cors(request, response)
        config = load_config
        origin = resolve_origin(request, config)

        response.headers["access-control-allow-origin"]  = origin
        response.headers["access-control-allow-methods"] = config[:methods]
        response.headers["access-control-allow-headers"] = config[:headers]
        response.headers["access-control-max-age"]       = config[:max_age]
        if config[:credentials] == "true"
          response.headers["access-control-allow-credentials"] = "true"
        end

        [request, response]
      end

      private

      def load_config
        {
          origins:     ENV["TINA4_CORS_ORIGINS"]     || "*",
          methods:     ENV["TINA4_CORS_METHODS"]     || "GET, POST, PUT, PATCH, DELETE, OPTIONS",
          headers:     ENV["TINA4_CORS_HEADERS"]     || "Content-Type,Authorization,X-Request-ID",
          max_age:     ENV["TINA4_CORS_MAX_AGE"]     || "86400",
          credentials: ENV["TINA4_CORS_CREDENTIALS"] || "false"
        }
      end

      def resolve_origin(request, config)
        request_origin = request.headers["origin"] || request.headers["referer"]

        if config[:origins] == "*"
          "*"
        elsif request_origin
          allowed = config[:origins].split(",").map(&:strip)
          clean = request_origin.chomp("/")
          allowed.include?(clean) ? clean : allowed.first || "*"
        else
          config[:origins].split(",").first&.strip || "*"
        end
      end
    end
  end

  # RateLimiterMiddleware -- tracks requests per IP, returns 429 when exceeded.
  # Config via env: TINA4_RATE_LIMIT (default 100), TINA4_RATE_WINDOW (default 60s).
  class RateLimiterMiddleware
    @store = {}
    @mutex = Mutex.new
    @last_cleanup = Time.now

    class << self
      def before_rate_limit(request, response)
        limit  = (ENV["TINA4_RATE_LIMIT"]  || 100).to_i
        window = (ENV["TINA4_RATE_WINDOW"] || 60).to_i
        ip = request.ip || "unknown"
        now = Time.now

        cleanup_if_needed(now, window)

        @mutex.synchronize do
          @store[ip] ||= []
          entries = @store[ip]

          # Sliding window -- drop expired timestamps
          cutoff = now - window
          entries.reject! { |t| t < cutoff }

          if entries.length >= limit
            oldest = entries.first
            retry_after = [(oldest + window - now).ceil, 1].max

            response.headers["X-RateLimit-Limit"]     = limit.to_s
            response.headers["X-RateLimit-Remaining"]  = "0"
            response.headers["X-RateLimit-Reset"]      = (oldest + window).to_i.to_s
            response.headers["Retry-After"]            = retry_after.to_s
            response.json({ error: "Too Many Requests", retry_after: retry_after }, 429)

            return [request, response]
          end

          entries << now

          response.headers["X-RateLimit-Limit"]     = limit.to_s
          response.headers["X-RateLimit-Remaining"]  = (limit - entries.length).to_s
          response.headers["X-RateLimit-Reset"]      = (now + window).to_i.to_s
        end

        [request, response]
      end

      # Allow resetting state (useful in tests)
      def reset!
        @mutex.synchronize { @store.clear }
      end

      private

      def cleanup_if_needed(now, window)
        return if now - @last_cleanup < window

        @mutex.synchronize do
          return if now - @last_cleanup < window

          cutoff = now - window
          @store.delete_if do |_ip, entries|
            entries.reject! { |t| t < cutoff }
            entries.empty?
          end
          @last_cleanup = now
        end
      end
    end
  end

  # RequestLoggerMiddleware -- logs method, path, and elapsed time for every request.
  class RequestLoggerMiddleware
    @request_times = {}
    @mutex = Mutex.new

    class << self
      def before_log(request, response)
        request_key = "#{request.object_id}"
        @mutex.synchronize do
          @request_times[request_key] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        [request, response]
      end

      def after_log(request, response)
        request_key = "#{request.object_id}"
        start_time = @mutex.synchronize { @request_times.delete(request_key) }

        if start_time
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(3)
        else
          elapsed_ms = 0.0
        end

        Tina4::Log.info("[RequestLogger] #{request.method} #{request.path} -> #{response.status_code} (#{elapsed_ms}ms)")
        [request, response]
      end

      def reset!
        @mutex.synchronize { @request_times.clear }
      end
    end
  end

  # CsrfMiddleware -- validates form tokens on state-changing requests.
  #
  # Off by default -- only active when TINA4_CSRF=true in .env or when
  # registered explicitly via Router.use(CsrfMiddleware).
  #
  # Behaviour:
  #   - Skips GET, HEAD, OPTIONS requests.
  #   - Skips routes marked .no_auth.
  #   - Skips requests with a valid Authorization: Bearer header (API clients).
  #   - Checks request.body["formToken"] then request.headers["X-Form-Token"].
  #   - Rejects if token found in request.query["formToken"] (log warning, 403).
  #   - Validates token with Auth.valid_token using SECRET env var.
  #   - If token payload has session_id, verifies it matches request.session.session_id.
  #   - Returns 403 with response.json({error: "CSRF_INVALID", message: ...}, 403) on failure.
  class CsrfMiddleware
    class << self
      def before_csrf(request, response)
        # Allow disabling CSRF via env var
        csrf_env = ENV["TINA4_CSRF"].to_s.downcase
        return [request, response] if %w[false 0 no].include?(csrf_env)

        # Skip safe HTTP methods
        method = (request.method || "GET").upcase
        return [request, response] if %w[GET HEAD OPTIONS].include?(method)

        # Skip routes marked no_auth
        handler = request.respond_to?(:handler) ? request.handler : nil
        if handler
          no_auth = if handler.is_a?(Hash)
                      handler[:no_auth] || handler[:noAuth]
                    elsif handler.respond_to?(:no_auth)
                      handler.no_auth
                    end
          return [request, response] if no_auth
        end

        # Skip requests with valid Bearer token (API clients)
        headers = request.respond_to?(:headers) ? request.headers : {}
        auth_header = headers["authorization"] || headers["Authorization"] || ""
        if auth_header.start_with?("Bearer ")
          bearer_token = auth_header[7..].strip
          unless bearer_token.empty?
            payload = Tina4::Auth.valid_token(bearer_token)
            return [request, response] if payload
          end
        end

        # Reject if token is in query string (security risk)
        query = if request.respond_to?(:params)
                  request.params
                elsif request.respond_to?(:query)
                  request.query
                else
                  {}
                end
        query ||= {}

        if query.is_a?(Hash) && query["formToken"] && !query["formToken"].to_s.empty?
          Tina4::Log.warning("[CSRF] Token found in query string — rejected for security")
          response.json({ error: "CSRF_INVALID", message: "Form token must not be sent in the URL query string" }, 403)
          return [request, response]
        end

        # Extract token: body first, then header
        token = nil
        body = request.respond_to?(:body) ? request.body : nil
        body ||= {}
        token = body["formToken"] if body.is_a?(Hash)

        if token.nil? || token.to_s.empty?
          token = headers["X-Form-Token"] || headers["x-form-token"] || ""
        end

        if token.nil? || token.to_s.empty?
          response.json({ error: "CSRF_INVALID", message: "Invalid or missing form token" }, 403)
          return [request, response]
        end

        # Validate the token
        payload = Tina4::Auth.valid_token(token.to_s)

        if payload.nil?
          response.json({ error: "CSRF_INVALID", message: "Invalid or missing form token" }, 403)
          return [request, response]
        end

        # Session binding — if token has session_id, verify it matches
        token_session_id = payload["session_id"]
        if token_session_id
          current_session_id = nil
          session = request.respond_to?(:session) ? request.session : nil
          if session
            current_session_id = if session.respond_to?(:session_id)
                                   session.session_id
                                 elsif session.is_a?(Hash)
                                   session["session_id"]
                                 elsif session.respond_to?(:get)
                                   session.get("session_id")
                                 end
          end

          if current_session_id && token_session_id != current_session_id
            response.json({ error: "CSRF_INVALID", message: "Invalid or missing form token" }, 403)
            return [request, response]
          end
        end

        [request, response]
      end
    end
  end

  # SecurityHeadersMiddleware -- injects security headers on every response.
  # Config via env:
  #   TINA4_FRAME_OPTIONS       — X-Frame-Options (default: SAMEORIGIN)
  #   TINA4_HSTS                — Strict-Transport-Security max-age (default: "" = off)
  #   TINA4_CSP                 — Content-Security-Policy (default: "default-src 'self'")
  #   TINA4_REFERRER_POLICY     — Referrer-Policy (default: strict-origin-when-cross-origin)
  #   TINA4_PERMISSIONS_POLICY  — Permissions-Policy (default: camera=(), microphone=(), geolocation=())
  class SecurityHeadersMiddleware
    class << self
      def before_security(request, response)
        response.headers["X-Frame-Options"] = ENV["TINA4_FRAME_OPTIONS"] || "SAMEORIGIN"
        response.headers["X-Content-Type-Options"] = "nosniff"

        hsts = ENV["TINA4_HSTS"] || ""
        unless hsts.empty?
          response.headers["Strict-Transport-Security"] = "max-age=#{hsts}; includeSubDomains"
        end

        response.headers["Content-Security-Policy"] = ENV["TINA4_CSP"] || "default-src 'self'"
        response.headers["Referrer-Policy"] = ENV["TINA4_REFERRER_POLICY"] || "strict-origin-when-cross-origin"
        response.headers["X-XSS-Protection"] = "0"
        response.headers["Permissions-Policy"] = ENV["TINA4_PERMISSIONS_POLICY"] || "camera=(), microphone=(), geolocation=()"

        [request, response]
      end
    end
  end
end
