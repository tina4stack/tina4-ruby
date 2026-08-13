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
      # Write routes are secure by default — bearer-token auth is enforced
      # on POST/PUT/PATCH/DELETE regardless of attached middleware.
      # Middleware is additive, never an auth bypass. tina4-book#141
      # PY-10-02. Call .no_auth on the route to opt out explicitly.
      @auth_required = %w[POST PUT PATCH DELETE].include?(@method)
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
    #
    # Middleware is purely additive — registering middleware NEVER flips
    # @auth_required off. The secure-by-default gate for write methods
    # (POST/PUT/PATCH/DELETE) stays in effect; if a route truly wants to
    # opt out of the built-in bearer check, call .no_auth explicitly.
    # tina4-book#141 PY-10-02 — previously, attaching ANY middleware
    # silently turned off auth_required, which let attackers bypass auth
    # by routing through a logging middleware. Cross-framework parity.
    def middleware(*middleware_classes)
      return @middleware if middleware_classes.empty?

      @middleware = @middleware.dup + middleware_classes
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
          # Rack delivers PATH_INFO (and therefore these captures) as
          # ASCII-8BIT. Relabel as UTF-8 so an untyped param binds to SQL as
          # TEXT, not a BLOB: SQLite gives a BLOB no numeric affinity, so a
          # `{id}` bound as ASCII-8BIT never matches an INTEGER column
          # (GET /users/{id} 404s a real row). No transcode — URL path bytes
          # are already UTF-8. Parity: Python/PHP/Node path params are text.
          raw_value = raw_value.dup.force_encoding(Encoding::UTF_8) if raw_value.is_a?(::String)
          params[param_def[:name]] = cast_param(raw_value, param_def[:type])
        end
        params
      end
    end

    # Run per-route middleware BEFORE the handler.
    #
    # Dispatch is by SHAPE, in declaration order:
    #
    #   * a CLASS (or instance) declaring before_*/after_* hooks — handed to
    #     Tina4::Middleware.run_before, the SAME orchestrator global middleware
    #     goes through, so it gets the SAME hook discovery (definition order,
    #     base->derived) and the SAME return-value table. There is no second,
    #     divergent runner here.
    #   * a String spec ("ResponseCache", "ResponseCache:300") — resolved to the
    #     configured middleware first (parity with Python/PHP/Node).
    #   * a 2-arg callable ("filter" middleware) — called directly; false halts.
    #
    # Function-style middleware (3+ args: req, resp, next_handler) is NOT run
    # here — it wraps the handler in a continuation chain (see
    # #function_middleware and DispatchPipeline#invoke_route_handler).
    #
    # This method used to call `mw.call(request, response)` on EVERYTHING. A
    # class declaring `def self.before_auth` does not respond to .call, so
    # per-route class middleware raised NoMethodError and the dispatcher turned
    # every such request into a clean 500 — the documented per-route
    # before_*/after_* mechanism never ran at all. The .call-everything body is
    # superseded by the shape dispatch above; the 2-arg filter path below is
    # what remains of it.
    #
    # Returns true if every middleware passed, false to halt (handler skipped).
    def run_middleware(request, response)
      hook_middleware.each do |mw|
        if Route.filter_middleware?(mw)
          next unless mw.call(request, response) == false

          # Same `false` row of the return-value table a before_* hook gets:
          # keep the response the filter set, 403 only if it set nothing.
          Tina4::Middleware.refuse(request, response)
          return false
        else
          return false unless Tina4::Middleware.run_before([mw], request, response)
        end
      end
      true
    end

    # Run per-route class middleware's after_* hooks, once the handler has run
    # (or once a before_* halted). Same orchestrator, same discovery — see
    # #run_middleware. Filter middleware has no after phase by construction.
    def run_after_middleware(request, response)
      hook_middleware.each do |mw|
        next if Route.filter_middleware?(mw)

        Tina4::Middleware.run_after([mw], request, response)
      end
      response
    end

    # Per-route middleware that takes part in the before/after passes:
    # everything except function-style middleware, with String specs resolved
    # to the middleware they name.
    def hook_middleware
      @middleware.reject { |mw| Route.function_middleware?(mw) }
                 .map { |mw| mw.is_a?(::String) ? Router.resolve_string_middleware(mw) : mw }
    end

    # Function-style middleware attached to this route, in declaration
    # order. The route dispatcher folds them into a Russian-doll
    # continuation chain — first declared is the OUTERMOST layer (runs
    # first on the way in, last on the way out). tina4-book#141
    # PY-10-01 — chapter 10 documented 8+ examples of function middleware
    # for years; before this fix the framework silently ignored them.
    def function_middleware
      @middleware.select { |mw| Route.function_middleware?(mw) }
    end

    # Detect Express/FastAPI-style function middleware.
    #
    # A Proc/Lambda/Method whose arity indicates 3+ positional params
    # (req, resp, next_handler). Ruby arity quirk: required-args-only
    # arity is non-negative; if the callable accepts a splat or
    # optionals, arity is negated (-required-1). We treat arity >= 3
    # OR arity <= -4 as function-style. Anything else (a class with
    # before_*/after_* methods, or a 2-arg callable) is treated as
    # class-style and goes through #run_middleware.
    def self.function_middleware?(mw)
      return false if mw.is_a?(Class) || mw.is_a?(Module)
      return false unless mw.respond_to?(:arity)
      ar = mw.arity
      ar >= 3 || ar <= -4
    rescue StandardError
      false
    end

    # Detect "filter" middleware: a plain 2-arg callable (Proc/Lambda/Method)
    # that receives (request, response) and halts by returning false.
    #
    # This is the shape #run_middleware has always supported, kept working
    # unchanged. It is NOT function middleware (3+ args, wraps the handler) and
    # NOT class middleware (declares before_*/after_* hooks) — a Class or Module
    # is never a filter even when it defines .call, because its hooks are the
    # documented mechanism.
    def self.filter_middleware?(mw)
      return false if mw.is_a?(Class) || mw.is_a?(Module)

      mw.respond_to?(:arity) && mw.respond_to?(:call)
    rescue StandardError
      false
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
    # PUBLIC by default (mirrors GET). Flip to true with #secure (or via
    # Tina4.secure_websocket) to require a valid JWT on the upgrade. Mirrors the
    # HTTP Route's auth_required so the upgrade path enforces it identically.
    attr_accessor :auth_required

    def initialize(path, handler, auth_required: false)
      @path = normalize_path(path).freeze
      @handler = handler
      @auth_required = auth_required
      @param_names = []
      @path_regex = compile_pattern(@path)
      @param_names.freeze
    end

    # Mark this WebSocket route as requiring bearer-token auth on the upgrade.
    # Returns self for chaining: Tina4::Router.websocket("/chat") { ... }.secure
    def secure
      @auth_required = true
      self
    end

    # Opt back out (the default). Returns self for chaining.
    def no_auth
      @auth_required = false
      self
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
          # Same ASCII-8BIT -> UTF-8 relabel as the HTTP Route matcher above,
          # so a WS path param binds to SQL as TEXT (not a BLOB).
          raw_value = raw_value.dup.force_encoding(Encoding::UTF_8) if raw_value.is_a?(::String)
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
    # Known string-addressable middleware, for a route declared as
    # `middleware: ["ResponseCache:300"]`. Matches PHP
    # (Router::resolveStringMiddleware) and Node (resolveStringMiddleware),
    # which both know exactly one name today. Python's registry is larger;
    # unifying the three registries is scheduled separately, so this
    # deliberately does NOT guess at Python's extra names.
    #
    # Each entry is a builder taking the parsed colon-args. See
    # .resolve_string_middleware.
    STRING_MIDDLEWARE = {
      "ResponseCache" => lambda { |args|
        ttl = args.first
        ttl.to_s.match?(/\A\d+\z/) ? Tina4::ResponseCache.new(ttl: ttl.to_i) : Tina4::ResponseCache.new
      }
    }.freeze

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
      #
      # PUBLIC by default (mirrors GET). Pass secure: true (the declarative way)
      # OR chain .secure on the returned route (the imperative way) to require a
      # valid JWT on the upgrade — both set the same auth_required flag, exactly
      # like the HTTP routes support both a decorator/docblock and .secure.
      def websocket(path, secure: false, &block)
        ws_route = WebSocketRoute.new(path, block, auth_required: secure)
        ws_routes << ws_route
        Tina4::Log.debug("WebSocket route registered: #{path}#{secure ? ' (secured)' : ''}")
        ws_route
      end

      # Register a SECURED WebSocket route (auth required on the upgrade). The
      # declarative sibling of Tina4::Router.websocket(...).secure — mirrors the
      # secure_get/secure_post pair for HTTP routes.
      def secure_websocket(path, &block)
        websocket(path, secure: true, &block)
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
        # Replace semantics: re-registering the same (method, path) overwrites
        # the existing entry in place rather than appending a second one.
        # This is what makes dev hot-reload work — when a changed route file is
        # re-loaded, its Router.get("/x") call runs again with a fresh handler,
        # and #find_route returns the FIRST match, so a stale leftover would
        # otherwise shadow the new handler forever. Overwriting keeps the
        # registry free of duplicates and ensures the latest handler wins.
        # Distinct (method, path) pairs are untouched — only an exact dup
        # collapses onto the prior slot, preserving its position/order.
        bucket = method_index[route.method]
        existing_index = routes.index { |r| r.method == route.method && r.path == route.path }
        if existing_index
          routes[existing_index] = route
          bucket_index = bucket.index { |r| r.path == route.path }
          if bucket_index
            bucket[bucket_index] = route
          else
            bucket << route
          end
          Tina4::Log.debug("Route replaced: #{route.method} #{route.path}")
        else
          routes << route
          bucket << route
          Tina4::Log.debug("Route registered: #{route.method} #{route.path}")
        end
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

        # Candidates in REGISTRATION order, which is what Python, PHP and Node
        # all do. This used to be `ANY + method`, which made an ANY route beat
        # every same-path specific route no matter when either was registered -
        # so an app with an ordinary CMS catch-all (`any("/{slug}")`) silently
        # swallowed the framework's own GET routes, `/__health` among them. The
        # route was registered correctly; the router simply never reached it.
        #
        # `routes` is the registration-order array and `method_index` is the
        # per-method fast path. With no ANY routes registered - the common case -
        # the fast path is exactly what it was. Only an app that actually uses
        # ANY pays for the ordered scan, and only that app needed it.
        any_routes = method_index["ANY"]
        candidates = if any_routes.nil? || any_routes.empty?
                       method_index[normalized_method] || []
                     else
                       routes.select { |r| r.method == "ANY" || r.method == normalized_method }
                     end
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

      # Resolve a string middleware spec to the middleware it names.
      #
      #   "ResponseCache"      -> ResponseCache with the default/env TTL
      #   "ResponseCache:300"  -> ResponseCache with ttl = 300
      #
      # The head before the first ":" is the name; the colon-separated tail is
      # its arguments. Same parse as Python's _resolve_string_middleware, PHP's
      # Router::resolveStringMiddleware and Node's resolveStringMiddleware.
      #
      # ONE INSTANCE PER SPEC. Route middleware is resolved per dispatch in
      # Ruby, so without memoising, every request would build a fresh
      # ResponseCache with a fresh empty store and the cache could never hit.
      # PHP memoises for exactly this reason; Python gets it for free by
      # resolving once at registration.
      #
      # An unknown name RAISES, naming the known set — never a silent skip.
      # Python raises ValueError, Node throws; a typo must surface, not
      # quietly drop the middleware (which for an auth middleware would mean
      # serving the route unprotected).
      def resolve_string_middleware(spec)
        spec = spec.to_s
        @resolved_string_middleware ||= {}
        return @resolved_string_middleware[spec] if @resolved_string_middleware.key?(spec)

        name, _sep, tail = spec.partition(":")
        builder = STRING_MIDDLEWARE[name]
        unless builder
          raise ArgumentError,
                "Unknown middleware #{name.inspect}. Known string middleware: " \
                "#{STRING_MIDDLEWARE.keys.sort.join(', ')}. For custom middleware, " \
                "pass the class directly to .middleware(MyMiddleware)."
        end

        @resolved_string_middleware[spec] = builder.call(tail.empty? ? [] : tail.split(":"))
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

      # Join a route-group prefix with a route's own path.
      #
      # Feature 32 (RG-DEC-01): ports PHP's normalization grammar verbatim
      # (Tina4/Router.php addRoute - the reference) so Ruby converges with
      # PHP/Python/Node instead of GroupContext's old bare concatenation. One
      # separator between prefix and path, a single leading slash, no
      # trailing slash, and any run of slashes collapsed to one - so
      # group("/api") + get("users"), get("/users"), and group("/api/") +
      # get("/users") all resolve to the SAME "/api/users". Before this fix,
      # "#{@prefix}#{path}" bare-concatenated, so group("/api") +
      # get("users") silently mis-registered at "/apiusers" (and a doubled
      # trailing slash on a prefix could leave "/api//users").
      def join_group_path(prefix, path)
        full = "#{prefix}/#{path.sub(%r{\A/+}, '')}"
        full = "/#{full.gsub(%r{\A/+|/+\z}, '')}"
        full.gsub(%r{/+}, "/")
      end

      # Load route files from a directory (file-based route discovery).
      #
      # mtime-tracked & re-runnable so re-discovery on /__dev/api/reload is
      # cheap and picks up edits without a server restart:
      #
      #   * NEW file (not seen before)            → load it, record its mtime.
      #   * CHANGED file (mtime newer than seen)  → load it again. Ruby's `load`
      #     RE-EXECUTES the file, so its Router.get(...) calls run afresh and
      #     #add replaces the (method, path) in place — the new handler wins
      #     instead of being shadowed by the stale one.
      #   * UNCHANGED file (present, same mtime)  → skip (keeps reload cheap).
      #
      # Scope guard: the glob is rooted at the user's routes/`src` `directory`,
      # so only application route files are ever (re)loaded — framework files
      # are never touched. Records the directory so #rescan_routes! can re-run
      # without re-passing it.
      def load_routes(directory)
        return unless Dir.exist?(directory)

        @loaded_route_files ||= {}
        @last_routes_dir = directory

        files = Dir.glob(File.join(directory, "**/*.rb")).sort
        total = files.length
        files.each do |file|
          current_mtime = File.mtime(file).to_i
          # Skip only when we've seen this file AND it hasn't changed since.
          next if @loaded_route_files.key?(file) && current_mtime <= @loaded_route_files[file]
          begin
            load file
            @loaded_route_files[file] = current_mtime
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

      # Write a .broken sentinel to data/.broken/ so an auto-discover failure
      # leaves a durable on-disk artifact instead of being swallowed into a log
      # line.
      #
      # Ruby only WRITES these files today — nothing under lib/ reads them back.
      # lib/tina4/health.rb contains no `broken` reference, and
      # GET /__dev/api/broken serves the in-memory Tina4::DevAdmin::ErrorTracker
      # (its own JSON store under Dir.tmpdir, dev_admin.rb:127-132), not this
      # directory. Python's /health DOES glob data/.broken and answer 503 with
      # `errors` + `latest_error` (tina4-python/tina4_python/core/server.py:296-320);
      # mirroring that read side in Ruby is an OPEN parity gap. This comment used
      # to claim "/health and the dev dashboard surface" it, which was false in
      # both halves. (feature-recount D12)
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
          full_path = Tina4::Router.join_group_path(@prefix, path)
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
