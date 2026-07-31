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

      # Handle OPTIONS preflight request, returns a Rack response array.
      #
      # `allow` is the resource's REAL method set, and it is emitted as the
      # `Allow` header alongside the CORS headers. RFC 9110 s9.3.7 says a
      # successful OPTIONS response SHOULD carry Allow, and a preflight is an
      # OPTIONS response - dropping it means a bare OPTIONS and a preflight to
      # the same path answer two different questions.
      #
      # This is CONFORMANCE, not a deviation. The frameworks' own OPTIONS
      # handlers already do it - Django's View.options() sets Allow from
      # _allowed_methods(), Express's router auto-answers OPTIONS with Allow.
      # The add-on CORS libraries (cors npm, django-cors-headers, rack-cors,
      # stack-cors, ASP.NET CORS) omit it, but that is a LAYERING artifact:
      # each sits ahead of the framework, so short-circuiting the preflight
      # also skips the framework's OPTIONS handler and the header it would
      # have produced. Tina4 owns both paths, so it costs one header to answer
      # both questions at once. See ADR-0013.
      #
      # Note Allow and Access-Control-Allow-Methods are NOT the same thing and
      # are not interchangeable: Allow is what the resource supports, ACAM is
      # what the CORS policy permits cross-origin. A policy allowing DELETE on
      # a GET-only route is still a 405.
      def preflight_response(env = {}, allow: nil)
        origin = resolve_origin(env)
        headers = {
          "access-control-allow-origin" => origin,
          "access-control-allow-methods" => config[:methods],
          "access-control-allow-headers" => config[:headers],
          "access-control-max-age" => config[:max_age],
          "access-control-allow-credentials" => config[:credentials]
        }
        # An unknown path yields "" - the same shape the bare-OPTIONS branch
        # uses - so a client can tell "nothing here" from "not told".
        headers["allow"] = Array(allow).join(", ") unless allow.nil?
        [204, headers, [""]]
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
          headers: ENV["TINA4_CORS_HEADERS"] || "Content-Type,Authorization,X-Request-ID",
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
          ""
        end
      end
    end
  end
end
