# frozen_string_literal: true

module Tina4
  module CorsMiddleware
    class << self
      def config
        @config ||= load_config
      end

      def reset!
        @config = nil
      end

      # Handle OPTIONS preflight request, returns a Rack response array
      def preflight_response(env = {})
        origin = resolve_origin(env)
        [
          204,
          {
            "access-control-allow-origin" => origin,
            "access-control-allow-methods" => config[:methods],
            "access-control-allow-headers" => config[:headers],
            "access-control-max-age" => config[:max_age],
            "access-control-allow-credentials" => config[:credentials]
          },
          [""]
        ]
      end

      # Apply CORS headers to a response headers hash
      def apply_headers(response_headers, env = {})
        origin = resolve_origin(env)
        response_headers["access-control-allow-origin"] = origin
        response_headers["access-control-allow-methods"] = config[:methods]
        response_headers["access-control-allow-headers"] = config[:headers]
        response_headers["access-control-max-age"] = config[:max_age]
        response_headers["access-control-allow-credentials"] = config[:credentials] if config[:credentials] == "true"
        response_headers
      end

      # Check if a given origin is allowed
      def origin_allowed?(origin)
        return true if config[:origins] == "*"

        allowed = config[:origins].split(",").map(&:strip)
        allowed.include?(origin)
      end

      private

      def load_config
        {
          origins: ENV["TINA4_CORS_ORIGINS"] || "*",
          methods: ENV["TINA4_CORS_METHODS"] || "GET, POST, PUT, PATCH, DELETE, OPTIONS",
          headers: ENV["TINA4_CORS_HEADERS"] || "Content-Type, Authorization, Accept",
          max_age: ENV["TINA4_CORS_MAX_AGE"] || "86400",
          credentials: ENV["TINA4_CORS_CREDENTIALS"] || "false"
        }.freeze
      end

      def resolve_origin(env)
        request_origin = env["HTTP_ORIGIN"] || env["HTTP_REFERER"]

        if config[:origins] == "*"
          "*"
        elsif request_origin && origin_allowed?(request_origin.chomp("/"))
          request_origin.chomp("/")
        else
          config[:origins].split(",").first&.strip || "*"
        end
      end
    end
  end
end
