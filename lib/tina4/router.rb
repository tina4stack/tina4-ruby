# frozen_string_literal: true

module Tina4
  class Route
    attr_reader :method, :path, :handler, :auth_handler, :swagger_meta,
                :path_regex, :param_names, :middleware

    def initialize(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [])
      @method = method.to_s.upcase.freeze
      @path = normalize_path(path).freeze
      @handler = handler
      @auth_handler = auth_handler
      @swagger_meta = swagger_meta
      @middleware = middleware.freeze
      @param_names = []
      @path_regex = compile_pattern(@path)
      @param_names.freeze
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

  module Router
    class << self
      def routes
        @routes ||= []
      end

      # Routes indexed by HTTP method for O(1) method lookup
      def method_index
        @method_index ||= Hash.new { |h, k| h[k] = [] }
      end

      def add_route(method, path, handler, auth_handler: nil, swagger_meta: {}, middleware: [])
        route = Route.new(method, path, handler,
                          auth_handler: auth_handler,
                          swagger_meta: swagger_meta,
                          middleware: middleware)
        routes << route
        method_index[route.method] << route
        Tina4::Log.debug("Route registered: #{method.upcase} #{path}")
        route
      end

      # Convenience registration methods matching tina4-python pattern
      def get(path, middleware: [], swagger_meta: {}, &block)
        add_route("GET", path, block, middleware: middleware, swagger_meta: swagger_meta)
      end

      def post(path, middleware: [], swagger_meta: {}, &block)
        add_route("POST", path, block, middleware: middleware, swagger_meta: swagger_meta)
      end

      def put(path, middleware: [], swagger_meta: {}, &block)
        add_route("PUT", path, block, middleware: middleware, swagger_meta: swagger_meta)
      end

      def patch(path, middleware: [], swagger_meta: {}, &block)
        add_route("PATCH", path, block, middleware: middleware, swagger_meta: swagger_meta)
      end

      def delete(path, middleware: [], swagger_meta: {}, &block)
        add_route("DELETE", path, block, middleware: middleware, swagger_meta: swagger_meta)
      end

      def any(path, middleware: [], swagger_meta: {}, &block)
        add_route("ANY", path, block, middleware: middleware, swagger_meta: swagger_meta)
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

      def clear!
        @routes = []
        @method_index = Hash.new { |h, k| h[k] = [] }
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
        define_method(m) do |path, middleware: [], swagger_meta: {}, &handler|
          full_path = "#{@prefix}#{path}"
          combined_middleware = @middleware + middleware
          Tina4::Router.add_route(m, full_path, handler,
                                  auth_handler: @auth_handler,
                                  swagger_meta: swagger_meta,
                                  middleware: combined_middleware)
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
