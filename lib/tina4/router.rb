# frozen_string_literal: true

module Tina4
  class Route
    attr_reader :method, :path, :handler, :auth_handler, :swagger_meta,
                :path_regex, :param_names, :middleware, :template
    attr_accessor :auth_required, :cached

    def initialize(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [], template: nil)
      @method = method.to_s.upcase.freeze
      @path = normalize_path(path).freeze
      @handler = handler
      @auth_handler = auth_handler
      @swagger_meta = swagger_meta
      @middleware = middleware.freeze
      @template = template&.freeze
      @auth_required = false
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

    # Mark this route as cacheable.
    # Returns self for chaining: Router.get("/path") { ... }.cache
    def cache
      @cached = true
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

    def compile_pattern(path)
      return Regexp.new("\\A/\\z") if path == "/"

      parts = path.split("/").reject(&:empty?)
      regex_parts = parts.map do |part|
        if part =~ /\A\*(\w+)\z/
          # Catch-all splat parameter: *path captures everything after
          name = Regexp.last_match(1)
          @param_names << { name: name.to_sym, type: "path" }
          '(.+)'
        elsif part =~ /\A\{(\w+)(?::(\w+))?\}\z/
          # Tina4/Python-style brace params: {id} or {id:int}
          # This is the ONLY supported param syntax, matching Python exactly.
          # Do NOT add :id (colon) style params.
          name = Regexp.last_match(1)
          type = Regexp.last_match(2) || "string"
          @param_names << { name: name.to_sym, type: type }
          case type
          when "int", "integer"
            '(\d+)'
          when "float", "number"
            '([\d.]+)'
          when "path"
            '(.+)'
          else
            '([^/]+)'
          end
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

      # Registered WebSocket routes
      def ws_routes
        @ws_routes ||= []
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

      def add_route(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [], template: nil)
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

      # Convenience registration methods matching tina4-python pattern
      def get(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add_route("GET", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def post(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add_route("POST", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def put(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add_route("PUT", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def patch(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add_route("PATCH", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def delete(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add_route("DELETE", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def any(path, middleware: [], swagger_meta: {}, template: nil, &block)
        add_route("ANY", path, block, middleware: middleware, swagger_meta: swagger_meta, template: template)
      end

      def find_route(path, method)
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
        nil
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

      def group(prefix, auth_handler: nil, middleware: [], &block)
        GroupContext.new(prefix, auth_handler, middleware).instance_eval(&block)
      end

      # Load route files from a directory (file-based route discovery)
      def load_routes(directory)
        return unless Dir.exist?(directory)
        Dir.glob(File.join(directory, "**/*.rb")).sort.each do |file|
          begin
            load file
            Tina4::Log.debug("Route loaded: #{file}")
          rescue => e
            Tina4::Log.error("Failed to load route #{file}: #{e.message}")
          end
        end
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
          Tina4::Router.add_route(m, full_path, handler,
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
