# frozen_string_literal: true

module Tina4
  # CORS policy — reads config from env, computes the response headers.
  #
  # DENY BY DEFAULT (ADR-0014). With TINA4_CORS_ORIGINS unset, NO
  # Access-Control-Allow-Origin is emitted and the browser's own CORS check
  # blocks the cross-origin request. "*" still works, it just has to be asked
  # for. Breaking change from the old permissive default.
  #
  # CREDENTIALS AND THE WILDCARD ARE MUTUALLY EXCLUSIVE. The Fetch Standard's
  # CORS check treats "*" as a literal (not a wildcard) once the request's
  # credentials mode is "include", so Access-Control-Allow-Origin: * together
  # with Access-Control-Allow-Credentials: true is rejected by every browser.
  # Ruby emitted exactly that pair before 2026-07-31 (measured through the real
  # Rack app): the credentials header was written unconditionally from config,
  # with no wildcard guard, while Python, PHP and Node all guarded it.
  #
  # VARY: ORIGIN whenever the ACAO value is COMPUTED from the request's Origin,
  # i.e. whenever an allow-list is configured, on a MISS as well as a match.
  # RFC 9110 s12.5.5: a Vary field name list tells cache recipients they "MUST
  # NOT use this response to satisfy a later request unless the later request
  # has the same values for the listed header fields as the original request".
  # A constant "*" genuinely does not vary and gets no Vary, which would only
  # fragment a CDN's cache per-origin for a response identical to everyone.
  # Access-Control-Allow-Methods / -Allow-Headers are static configured lists
  # here, never derived from the request's Access-Control-Request-* headers, so
  # those field names do NOT belong in Vary.
  module CorsMiddleware
    class << self
      def config
        @config ||= load_config
      end

      def reset!
        @config = nil
        @warned = nil
      end

      # The configured origins, split and emptied of blanks.
      def allowed_origins
        config[:origins].split(",").map(&:strip).reject(&:empty?)
      end

      # Whether an operator has actually declared a CORS policy.
      def configured?
        !allowed_origins.empty?
      end

      # The CORS policy headers for a request environment.
      #
      # This is the ONE place the policy is computed. preflight_response and
      # apply_headers both call it, so the preflight path and the normal
      # response path can never drift apart the way two implementations do.
      def policy_headers(env = {})
        allowed = allowed_origins
        request_origin = env["HTTP_ORIGIN"]

        if allowed.empty?
          warn_once(:unconfigured, request_origin) if present?(request_origin)
          return {}
        end

        headers = {}
        wildcard = allowed.include?("*")
        # An allow-list decision reads the request Origin, so the response
        # varies by it — on a MISS too, or a shared cache can serve this
        # no-ACAO response to an origin that should have been allowed.
        headers["vary"] = "Origin" unless wildcard

        origin = resolve_origin(env)
        if origin.nil?
          warn_once(:denied, request_origin) if present?(request_origin)
          return headers
        end

        headers["access-control-allow-origin"]  = origin
        headers["access-control-allow-methods"] = config[:methods]
        headers["access-control-allow-headers"] = config[:headers]
        headers["access-control-max-age"]       = config[:max_age]

        if credentials?
          if origin == "*"
            warn_once(:wildcard_credentials, nil)
          else
            headers["access-control-allow-credentials"] = "true"
          end
        end

        headers
      end

      # Handle a CORS preflight request, returns a Rack response array.
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
      #
      # The status is 204 whether the origin was allowed or denied — the
      # browser does the blocking, and inventing a 403 here would be a second
      # behaviour change for no gain.
      def preflight_response(env = {}, allow: nil)
        headers = policy_headers(env)
        # An unknown path yields "" - the same shape the bare-OPTIONS branch
        # uses - so a client can tell "nothing here" from "not told".
        headers["allow"] = Array(allow).join(", ") unless allow.nil?
        [204, headers, [""]]
      end

      # Apply CORS headers to a response headers hash, merging Vary rather than
      # clobbering a value another layer already set.
      def apply_headers(response_headers, env = {})
        policy_headers(env).each do |name, value|
          response_headers[name] = if name == "vary"
                                     merge_vary(response_headers["vary"], value)
                                   else
                                     value
                                   end
        end
        response_headers
      end

      # Check if a given origin is allowed by the configured policy.
      def origin_allowed?(origin)
        allowed = allowed_origins
        return false if allowed.empty?
        return true if allowed.include?("*")

        allowed.include?(origin)
      end

      def credentials?
        %w[true 1 yes].include?(config[:credentials].to_s.downcase)
      end

      private

      def load_config
        {
          # Default is EMPTY, not "*" — deny by default (ADR-0014).
          origins: ENV["TINA4_CORS_ORIGINS"] || "",
          methods: ENV["TINA4_CORS_METHODS"] || "GET, POST, PUT, PATCH, DELETE, OPTIONS",
          headers: ENV["TINA4_CORS_HEADERS"] || "Content-Type,Authorization,X-Request-ID",
          max_age: ENV["TINA4_CORS_MAX_AGE"] || "86400",
          credentials: ENV["TINA4_CORS_CREDENTIALS"] || "false"
        }.freeze
      end

      # Resolve the origin to send, or nil for none.
      #
      # Reads the Origin header ONLY. The Referer used to be a fallback, which
      # was wrong twice over: a Referer is a full URL, not an origin, and the
      # CORS protocol is defined entirely in terms of the Origin header. A
      # plain same-site navigation carries a Referer and no Origin, and used to
      # get CORS headers stamped on it for no reason.
      def resolve_origin(env)
        allowed = allowed_origins
        return nil if allowed.empty?
        return "*" if allowed.include?("*")

        request_origin = env["HTTP_ORIGIN"]
        return nil unless present?(request_origin)

        clean = request_origin.chomp("/")
        allowed.include?(clean) ? clean : nil
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      def merge_vary(current, field_name)
        parts = current.to_s.split(",").map(&:strip).reject(&:empty?)
        return parts.join(", ") if parts.any? { |p| p.casecmp?(field_name) }

        (parts + [field_name]).join(", ")
      end

      # Log an actionable warning at most once per reason per process.
      #
      # A rejected cross-origin request is otherwise invisible: the browser
      # reports a generic CORS failure and the server log says nothing, so the
      # operator has to read the framework source to find the env var to set.
      def warn_once(reason, request_origin)
        @warned ||= {}
        key = reason == :denied ? "denied:#{request_origin}" : reason
        return if @warned[key]

        @warned[key] = true
        Tina4::Log.warning(warning_message(reason, request_origin))
      rescue StandardError
        nil # logging must never break a request
      end

      def warning_message(reason, request_origin)
        case reason
        when :unconfigured
          "CORS: refused cross-origin request from #{request_origin} - no policy is configured. " \
            "Set TINA4_CORS_ORIGINS to the origins you want to allow, e.g. " \
            "TINA4_CORS_ORIGINS=https://app.example.com (or '*' to allow any origin)."
        when :denied
          "CORS: origin #{request_origin} is not in TINA4_CORS_ORIGINS (#{config[:origins]}) " \
            "- the browser will block this response."
        else
          "CORS: TINA4_CORS_CREDENTIALS is true but TINA4_CORS_ORIGINS is '*'. The Fetch Standard " \
            "forbids Access-Control-Allow-Origin: * with credentials, so credentials are NOT being " \
            "sent. Credentialed CORS requires an explicit origin list, e.g. " \
            "TINA4_CORS_ORIGINS=https://app.example.com."
        end
      end
    end
  end
end
