# frozen_string_literal: true

module Tina4
  class Route
    attr_reader :method, :path, :handler, :auth_handler, :swagger_meta, :path_regex, :param_names

    def initialize(method, path, handler, auth_handler: nil, swagger_meta: {})
      @method = method.to_s.upcase.freeze
      @path = normalize_path(path).freeze
      @handler = handler
      @auth_handler = auth_handler
      @swagger_meta = swagger_meta
      @param_names = []
      @path_regex = compile_pattern(@path)
      @param_names.freeze
    end

    # Returns params hash if matched, false otherwise
    def match?(request_path, request_method = nil)
      return false if request_method && @method != request_method.to_s.upcase
      match_path(request_path)
    end

    # Returns params hash if matched, false otherwise
    def match_path(request_path)
      match = @path_regex.match(request_path)
      return false unless match

      if @param_names.empty?
        # Static route — no params to extract
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
        if part =~ /\A\{(\w+)(?::(\w+))?\}\z/
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

      def add_route(method, path, handler, auth_handler: nil, swagger_meta: {})
        route = Route.new(method, path, handler, auth_handler: auth_handler, swagger_meta: swagger_meta)
        routes << route
        method_index[route.method] << route
        Tina4::Debug.debug("Route registered: #{method.upcase} #{path}")
        route
      end

      def find_route(path, method)
        normalized_method = method.upcase
        # Normalize path once (not per-route)
        normalized_path = path.gsub("\\", "/")
        normalized_path = "/#{normalized_path}" unless normalized_path.start_with?("/")
        normalized_path = normalized_path.chomp("/") unless normalized_path == "/"

        # Only scan routes matching this HTTP method
        candidates = method_index[normalized_method]
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

      def group(prefix, auth_handler: nil, &block)
        GroupContext.new(prefix, auth_handler).instance_eval(&block)
      end
    end

    class GroupContext
      def initialize(prefix, auth_handler = nil)
        @prefix = prefix.chomp("/")
        @auth_handler = auth_handler
      end

      %w[get post put patch delete any].each do |m|
        define_method(m) do |path, swagger_meta: {}, &handler|
          full_path = "#{@prefix}#{path}"
          Tina4::Router.add_route(m, full_path, handler, auth_handler: @auth_handler, swagger_meta: swagger_meta)
        end
      end
    end
  end
end
