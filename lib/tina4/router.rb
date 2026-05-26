# frozen_string_literal: true

require "fileutils"
require "json"

module Tina4
  class Route
    attr_reader :method, :path, :handler, :auth_handler, :swagger_meta,
                :path_regex, :param_names, :template
    attr_accessor :auth_required, :cached

    def initialize(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [], template: nil)
      @method = method.to_s.upcase.freeze
      @path = normalize_path(path).freeze
      @handler = handler
      @auth_handler = auth_handler
      @swagger_meta = swagger_meta
      @middleware = middleware.freeze
      @template = template&.freeze
      # Write routes are secure by default, unless custom middleware is registered
      # (developer handles auth themselves via middleware)
      @auth_required = %w[POST PUT PATCH DELETE].include?(@method) && middleware.empty?
      @cached = false
      @param_names = []
      @path_regex = compile_pattern(@path)
      @param_names.freeze
    end

    # Mark this route as requiring bearer-token authentication.
    # Returns self for chaining: Router.get("/path") { ... }.secure
    def secure
      @auth_required = true
      self
    end

    # Opt out of the secure-by-default auth on write routes.
    # Returns self for chaining: Router.post("/login") { ... }.no_auth
    def no_auth
      @auth_required = false
      self
    end

    # Mark this route as cacheable.
    # Returns self for chaining: Router.get("/path") { ... }.cache
    def cache
      @cached = true
      self
    end

    # Dual-mode: getter (no args) returns the middleware array;
    # setter (with args) appends middleware and returns self for chaining.
    # Router.post("/api") { ... }.middleware(AuthMiddleware)
    def middleware(*middleware_classes)
      return @middleware if middleware_classes.empty?

      @middleware = @middleware.dup + middleware_classes
      # Custom middleware means developer handles auth — disable built-in gate
      # unless .secure was explicitly called.
      @auth_required = false unless @auth_required
      self
    end

    # Returns params hash if matched, false otherwise
    def match?(request_path, request_method = nil)
      return false if request_method && @method != "ANY" && @method != request_method.to_s.upcase
      match_path(request_path)
    end

    # Returns params hash if matched, false otherwise
    def match_path(request_path)
      match = @path_regex.match(request_path)
      return false unless match

      if @param_names.empty?
        {}
      else
        params = {}
        @param_names.each_with_index do |param_def, i|
          raw_value = match[i + 1]
          params[param_def[:name]] = cast_param(raw_value, param_def[:type])
        end
        params
      end
    end

    # Run per-route middleware chain; returns true if all pass
    def run_middleware(request, response)
      @middleware.each do |mw|
        result = mw.call(request, response)
        return false if result == false
      end
      true
    end

    private

    def normalize_path(path)
      p = path.to_s.gsub("\\", "/")
      p = "/#{p}" unless p.start_with?("/")
      p = p.chomp("/") unless p == "/"
      p
    end

    # Supported typed-parameter constraints. Mirrored verbatim in
    # tina4-python / tina4-php / tina4-nodejs for cross-framework parity.
    #
    # Any type name not in this table raises ``ArgumentError`` at route
    # registration — we never silently fall through to the default matcher,
    # because a typo like ``{id:inetger}`` would otherwise match anything
    # and create a security footgun (see tina4-book#125).
    PARAM_TYPE_PATTERNS = {
      "string"  => "[^/]+",                                            # default, any non-slash segment
      "int"     => '\d+',
      "integer" => '\d+',
      "float"   => '[\d.]+',
      "number"  => '[\d.]+',
      "alpha"   => "[A-Za-z]+",                                        # letters only
      "alnum"   => "[A-Za-z0-9]+",                                     # letters + digits
      "slug"    => "[a-z0-9-]+",                                       # URL slug
      "uuid"    => "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
      "path"    => ".+",                                               # greedy
      ".*"      => ".+",
    }.freeze

    def compile_pattern(path)
      return Regexp.new("\\A/\\z") if path == "/"

      parts = path.split("/").reject(&:empty?)
      regex_parts = parts.map do |part|
        if part =~ /\A\*(\w+)\z/
          # Named catch-all splat parameter: *path captures everything after
          name = Regexp.last_match(1)
          @param_names << { name: name.to_sym, type: "path" }
          '(.+)'
        elsif part == "*"
          # Bare catch-all wildcard: captures everything after under the "*" key
          # to match Python/PHP/Node parity (docs say `request.params["*"]`).
          @param_names << { name: :"*", type: "path" }
          '(.+)'
        elsif part =~ /\A\{(\w+)(?::([\w.*]+))?\}\z/
          # Tina4/Python-style brace params: {id} or {id:int}
          # This is the ONLY supported param syntax, matching Python exactly.
          # Do NOT add :id (colon) style params.
          name = Regexp.last_match(1)
          type = Regexp.last_match(2) || "string"
          unless PARAM_TYPE_PATTERNS.key?(type)
            valid = PARAM_TYPE_PATTERNS.keys.reject { |k| k == ".*" }.sort.join(", ")
            raise ArgumentError,
                  "Unknown param type '#{type}' in route '#{path}'. Valid types: #{valid}."
          end
          @param_names << { name: name.to_sym, type: type }
          "(#{PARAM_TYPE_PATTERNS[type]})"
        else
          Regexp.escape(part)
        end
      end
      Regexp.new("\\A/#{regex_parts.join("/")}\\z")
    end

    def cast_param(value, type)
      case type
      when "int", "integer"
        value.to_i
      when "float", "number"
        value.to_f
      else
        value
      end
    end
  end

  # A registered WebSocket route with path pattern matching (reuses Route's compile logic)
  class WebSocketRoute
    attr_reader :path, :handler, :path_regex, :param_names

    def initialize(path, handler)
      @path = normalize_path(path).freeze
      @handler = handler
      @param_names = []
      @path_regex = compile_pattern(@path)
      @param_names.freeze
    end

    # Returns params hash if matched, false otherwise
    def match?(request_path)
      match = @path_regex.match(request_path)
      return false unless match

      if @param_names.empty?
        {}
      else
        params = {}
        @param_names.each_with_index do |param_def, i|
          raw_value = match[i + 1]
          params[param_def[:name]] = raw_value
        end
        params
      end
    end

    private

    def normalize_path(path)
      p = path.to_s.gsub("\\", "/")
      p = "/#{p}" unless p.start_with?("/")
      p = p.chomp("/") unless p == "/"
      p
    end

    def compile_pattern(path)
      return Regexp.new("\\A/\\z") if path == "/"

      parts = path.split("/").reject(&:empty?)
      regex_parts = parts.map do |part|
        if part =~ /\A\{(\w+)\}\z/
          name = Regexp.last_match(1)
          @param_names << { name: name.to_sym }
          '([^/]+)'
        else
          Regexp.escape(part)
        end
      end
      Regexp.new("\\A/#{regex_parts.join("/")}\\z")
    end
  end

  module Router
    class << self
      def routes
        @routes ||= []
      end

      def get_routes
        routes
      end

      def list_routes
        routes
      end

      # Registered WebSocket routes
      def ws_routes
        @ws_routes ||= []
      end

      # Parity alias — returns all registered WebSocket routes.
      def get_web_socket_routes
        ws_routes
      end

      # Register a WebSocket route.
      # The handler block receives (connection, event, data) where:
      #   connection — WebSocketConnection with #send, #broadcast, #close, #params
      #   event      — :open, :message, or :close
      #   data       — String payload for :message, nil for :open/:close
      def websocket(path, &block)
        ws_route = WebSocketRoute.new(path, block)
        ws_routes << ws_route
        Tina4::Log.debug("WebSocket route registered: #{path}")
        ws_route
      end

      # Find a matching WebSocket route for a given path.
      # Returns [ws_route, params] or nil.
      def find_ws_route(path)
        normalized = path.gsub("\\", "/")
        normalized = "/#{normalized}" unless normalized.start_with?("/")
        normalized = normalized.chomp("/") unless normalized == "/"

        ws_routes.each do |ws_route|
          params = ws_route.match?(normalized)
          return [ws_route, params] if params
        end
        nil
      end

      # Routes indexed by HTTP method for O(1) method lookup
      def method_index
        @method_index ||= Hash.new { |h, k| h[k] = [] }
      end

      def add(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [], template: nil)
        route = Route.new(method, path, handler,
                          auth_handler: auth_handler,
                          swagger_meta: swagger_meta,
                          middleware: middleware,
                          template: template)
        routes << route
        method_index[route.method] << route
        Tina4::Log.debug("Route registered: #{method.upcase} #{path}")
        route
      end
      # Convenience registration methods
      def get(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("GET", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def post(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("POST", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def put(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("PUT", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def patch(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("PATCH", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def delete(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("DELETE", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def any(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("ANY", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      # Register an explicit HEAD route. By default the framework auto-handles
      # HEAD by falling back to the GET route and stripping the body
      # (RFC 9110 §9.3.2). Use this only when you need a HEAD handler that
      # does something different from GET — e.g. cheaper existence-check
      # logic, custom validator headers without the cost of building the body.
      # The framework still strips the response body for you on the way out.
      def head(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("HEAD", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      # Register an explicit OPTIONS route. By default the framework auto-
      # handles OPTIONS by building an Allow header from every method
      # registered for the path and returning 204 (RFC 9110 §9.3.7). Use
      # this to take over that behaviour — e.g. to return a richer OPTIONS
      # payload describing the resource.
      def options(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add("OPTIONS", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def find_route(method, path)
        normalized_method = method.upcase
        # Normalize path once (not per-route)
        normalized_path = path.gsub("\\", "/")
        normalized_path = "/#{normalized_path}" unless normalized_path.start_with?("/")
        normalized_path = normalized_path.chomp("/") unless normalized_path == "/"

        # Check ANY routes first, then method-specific routes
        candidates = (method_index["ANY"] || []) + (method_index[normalized_method] || [])
        candidates.each do |route|
          params = route.match_path(normalized_path)
          return [route, params] if params
        end

        # RFC 9110 §9.3.2: HEAD is identical to GET except for the absence
        # of a response body. If no explicit HEAD route matched, fall back
        # to the GET route — the dispatcher strips the body on the way out
        # so the handler doesn't need to know HEAD even happened.
        if normalized_method == "HEAD"
          (method_index["GET"] || []).each do |route|
            params = route.match_path(normalized_path)
            return [route, params] if params
          end
        end

        nil
      end

      # Return the list of HTTP methods registered for ``path``, in the order
      # GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS. Used by the
      # dispatcher to build the ``Allow:`` header on 405 / OPTIONS responses
      # (RFC 9110 §10.2.1, §9.3.7).
      #
      # If GET is registered for the path, HEAD is appended implicitly
      # (HEAD auto-fallback). OPTIONS is appended whenever the path has any
      # registered method (the framework auto-handles OPTIONS).
      def methods_allowed_for_path(path)
        normalized_path = path.gsub("\\", "/")
        normalized_path = "/#{normalized_path}" unless normalized_path.start_with?("/")
        normalized_path = normalized_path.chomp("/") unless normalized_path == "/"

        method_order = %w[GET POST PUT PATCH DELETE HEAD OPTIONS]
        seen = []
        any_matched = false

        method_index.each do |m, routes_for_method|
          next if routes_for_method.empty?
          matched = routes_for_method.any? { |r| r.match_path(normalized_path) }
          next unless matched
          if m == "ANY"
            any_matched = true
          elsif method_order.include?(m)
            seen << m unless seen.include?(m)
          end
        end

        seen = method_order.dup if any_matched

        if !seen.empty?
          seen << "HEAD" if seen.include?("GET") && !seen.include?("HEAD")
          seen << "OPTIONS" unless seen.include?("OPTIONS")
        end

        method_order.select { |m| seen.include?(m) }
      end

      # When TINA4_TRAILING_SLASH_REDIRECT is truthy, the rack app uses this
      # to detect whether the *original* (un-stripped) path differed from the
      # canonical form so it can issue a 301 redirect. Default false — silent
      # match keeps backward compatibility.
      def trailing_slash_redirect?
        %w[true 1 yes on].include?(ENV.fetch("TINA4_TRAILING_SLASH_REDIRECT", "").to_s.strip.downcase)
      end

      # Find a route matching method + path. Returns [route, params] or nil.
      # match(method, path) — consistent with Python, PHP, and Node.
      def match(method, path)
        find_route(method, path)
      end

      # Register a class-based middleware globally.
      # The class should define static before_* and/or after_* methods.
      # Example:
      #   class AuthMiddleware
      #     def self.before_auth(request, response)
      #       unless request.headers["authorization"]
      #         return [request, response.json({ error: "Unauthorized" }, 401)]
      #       end
      #       [request, response]
      #     end
      #   end
      #   Tina4::Router.use(AuthMiddleware)
      def use(klass)
        Tina4::Middleware.use(klass)
      end

      def clear!
        @routes = []
        @method_index = Hash.new { |h, k| h[k] = [] }
        @ws_routes = []
      end
      alias clear clear!

      def group(prefix, auth_handler: nil, middleware: [], &block)
        GroupContext.new(prefix, auth_handler, middleware).instance_eval(&block)
      end

      # Load route files from a directory (file-based route discovery).
      #
      # Idempotent: files already loaded by a previous call are skipped, so
      # calling load_routes repeatedly (e.g. on /__dev/api/reload) only
      # picks up NEW files. Records the directory so #rescan_routes! can
      # re-run without re-passing it.
      def load_routes(directory)
        return unless Dir.exist?(directory)

        @loaded_route_files ||= {}
        @last_routes_dir = directory

        files = Dir.glob(File.join(directory, "**/*.rb")).sort
        total = files.length
        files.each do |file|
          next if @loaded_route_files[file]
          begin
            load file
            @loaded_route_files[file] = true
            Tina4::Log.debug("Route loaded: #{file}")
          rescue ScriptError, StandardError => e
            # ScriptError catches SyntaxError, which is NOT a StandardError —
            # a bare `rescue => e` would let a syntax-broken route file crash
            # the whole discovery pass.
            Tina4::Log.error("Failed to load route #{file}: #{e.message}")
            record_broken_route_import(file, e)
          end
        end

        # Zero-routes warning — src/routes/ has .rb files but the router
        # is still empty. Almost certainly the user forgot Tina4::Router.get.
        if total > 0 && routes.empty?
          Tina4::Log.warning(
            "Auto-discover found #{total} .rb file(s) in #{directory} but no routes registered. " \
            "Each route file must call Tina4::Router.get / .post / etc."
          )
        end
      end

      # Re-run the most recent load_routes — called by /__dev/api/reload so
      # files dropped into src/routes/ after server boot get picked up
      # without a restart. No-op if load_routes has never been called.
      def rescan_routes!
        return [] if @last_routes_dir.nil? || @last_routes_dir.empty?
        before = routes.length
        load_routes(@last_routes_dir)
        added = routes.length - before
        Tina4::Log.info("Re-discovered #{added} new route(s) on reload") if added.positive?
        added
      end

      # Test-only helper — reset the loaded-files state so tests can scan
      # the same directory multiple times with different file contents.
      def reset_route_discovery!
        @loaded_route_files = {}
        @last_routes_dir = nil
      end

      # Write a .broken sentinel so /health and the dev dashboard surface
      # auto-discover failures instead of swallowing them into a log line.
      def record_broken_route_import(file, error)
        broken_dir = File.join(Dir.pwd, "data", ".broken")
        FileUtils.mkdir_p(broken_dir) unless Dir.exist?(broken_dir)
        slug = file.gsub(%r{[/\\]}, "_")
        payload = JSON.generate(
          type: "auto_discover_failure",
          file: file,
          error: "#{error.class}: #{error.message}"
        )
        File.write(File.join(broken_dir, "discover_#{slug}.broken"), payload)
      rescue StandardError
        # If the .broken write itself fails, the original error is already
        # in the log — nothing more to do.
      end
    end

    class GroupContext
      def initialize(prefix, auth_handler = nil, middleware = [])
        @prefix = prefix.chomp("/")
        @auth_handler = auth_handler
        @middleware = middleware
      end

      %w[get post put patch delete any].each do |m|
        define_method(m) do |path, middleware: [], swagger_meta: {}, template: nil, &handler|
          full_path = "#{@prefix}#{path}"
          combined_middleware = @middleware + middleware
          Tina4::Router.add(m, full_path, handler,
                                  auth_handler: @auth_handler,
                                  swagger_meta: swagger_meta,
                                  middleware: combined_middleware,
                                  template: template)
        end
      end

      # Nested groups
      def group(prefix, auth_handler: nil, middleware: [], &block)
        full_prefix = "#{@prefix}#{prefix}"
        combined_middleware = @middleware + middleware
        nested_auth = auth_handler || @auth_handler
        GroupContext.new(full_prefix, nested_auth, combined_middleware).instance_eval(&block)
      end
    end
  end
end
