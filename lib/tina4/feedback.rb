# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Tina4
  # ── Customer feedback widget — server-side plumbing ─────────────────
  #
  # Mirrors tina4_python/dev_admin/__init__.py lines 1436-1645. The
  # widget is for END USERS of a shipped Tina4 app (not developers).
  # Whitelisted users get a floating bubble that proxies one
  # conversational turn at a time to the Rust agent's intake endpoint
  # at <supervisor>/feedback/intake.
  #
  # Flow:
  #   1. Framework middleware injects <script src="/__feedback/widget.js">
  #      into HTML responses for whitelisted users.
  #   2. Widget POSTs to /__feedback/api/turn for each conversational turn.
  #   3. The Ruby handler verifies whitelist + rate-limit, stamps the
  #      user identity server-side (client cannot fake `sender`), then
  #      forwards to the Rust agent's /feedback/intake.
  #   4. Finalised tickets land in .tina4/chat/threads.json with
  #      kind:"feedback". Developer sees them in the dev admin sidebar.
  module Feedback
    RATE_WINDOW = 3600   # 1 hour
    RATE_MAX = 5         # submissions/turns per user per hour

    # Class-level mutex-guarded hash {user => [timestamps]}. Mirrors the
    # Python `_FEEDBACK_RATE_LIMIT` dict — process-local, no persistence.
    @rate_limit = {}
    @rate_mutex = Mutex.new

    class << self
      attr_reader :rate_mutex

      # Test/reset helper — clears the in-memory rate-limit table.
      def reset_rate_limit!
        @rate_mutex.synchronize { @rate_limit = {} }
      end

      # Hard master switch.
      #
      # Both gates required for the widget to render or the API to
      # accept submissions:
      #   - TINA4_ENABLE_FEEDBACK=true (explicit opt-in — off by default)
      #   - TINA4_FEEDBACK_WHITELIST=... (non-empty list of users)
      #
      # Splitting the toggle from the whitelist lets the developer leave
      # the whitelist intact while pausing the feature in production for
      # a release (set TINA4_ENABLE_FEEDBACK=false → widget vanishes
      # everywhere; whitelist comes back online with one env flip).
      def feedback_enabled?
        raw = ENV["TINA4_ENABLE_FEEDBACK"].to_s.strip.downcase
        %w[1 true yes on].include?(raw)
      end

      # Comma-separated emails / user IDs in env. Empty = no one allowed.
      def feedback_whitelist
        return [] unless feedback_enabled?
        raw = ENV["TINA4_FEEDBACK_WHITELIST"].to_s.strip
        return [] if raw.empty?
        raw.split(",").map { |e| e.strip.downcase }.reject(&:empty?)
      end

      # Best-effort user identity from auth headers.
      #
      # Priority:
      #   1. JWT/Bearer token via Tina4::Auth.authenticate_request —
      #      pulls email/sub/user_id claim.
      #   2. TINA4_FEEDBACK_DEV_USER env var override (LOCAL DEV ONLY —
      #      lets the framework owner test the widget without a full
      #      auth setup in the test project).
      def feedback_identify_user(request)
        begin
          headers = request_headers(request)
          payload = Tina4::Auth.authenticate_request(headers)
          if payload.is_a?(Hash)
            %w[email sub user_id].each do |key|
              v = payload[key] || payload[key.to_sym]
              return v.to_s.strip.downcase if v && !v.to_s.strip.empty?
            end
          end
        rescue StandardError
          # fall through to dev-user override
        end
        dev_user = ENV["TINA4_FEEDBACK_DEV_USER"].to_s.strip
        return dev_user.downcase unless dev_user.empty?
        nil
      end

      # Returns [allowed, identity]. Both halves must be truthy to act.
      def feedback_is_whitelisted(request)
        wl = feedback_whitelist
        return [false, nil] if wl.empty?
        user = feedback_identify_user(request)
        return [false, nil] unless user
        [wl.include?(user), user]
      end

      # 5 turns/hour per user. Prunes old timestamps lazily.
      def feedback_rate_limit_ok(user)
        now = Time.now.to_f
        @rate_mutex.synchronize do
          hits = (@rate_limit[user] || []).select { |t| now - t < RATE_WINDOW }
          if hits.size >= RATE_MAX
            @rate_limit[user] = hits
            return false
          end
          hits << now
          @rate_limit[user] = hits
          true
        end
      end

      # Insert the widget <script> into HTML responses for whitelisted users.
      #
      # Called from the Rack middleware right before the body is sent.
      # No-op if:
      #   - The request is for a /__dev or /__feedback path (developer
      #     dashboard / widget assets — never inject the customer widget
      #     on developer pages; the dev admin has its OWN chat trigger).
      #   - TINA4_ENABLE_FEEDBACK + TINA4_FEEDBACK_WHITELIST not both set
      #   - Requesting user isn't in the whitelist
      #   - Response doesn't have a closing </body> tag (fragment, JSON, etc.)
      # Idempotent: a second call won't double-inject (looks for marker).
      def inject_feedback_widget(request, html)
        return html if html.nil? || html.empty?
        # The customer feedback widget is for END USERS of the shipped
        # app — injecting on developer-only paths creates a confusing
        # "two bubbles" UX where the dev chat trigger + customer
        # feedback bubble sit on top of each other. Hard exclusion at
        # the framework layer.
        path = request_path(request)
        return html if path.start_with?("/__dev") || path.start_with?("/__feedback")
        allowed, _user = feedback_is_whitelisted(request)
        return html unless allowed
        return html if html.include?("data-tina4-feedback")
        snippet = '<script src="/__feedback/widget.js" data-tina4-feedback></script>'
        idx = html.rindex("</body>")
        return html unless idx
        html[0...idx] + snippet + html[idx..]
      end

      # POST /__feedback/api/turn — whitelist check + rate-limit + stamp
      # `sender` server-side, forward to Rust agent
      # <supervisor>/feedback/intake. Returns a Rack response triple.
      def handle_turn(env)
        request = build_request_wrapper(env)
        allowed, user = feedback_is_whitelisted(request)
        return json_response({ error: "not authorised for feedback" }, 403) unless allowed
        unless feedback_rate_limit_ok(user)
          return json_response({
            error: "rate limit exceeded",
            hint: "max #{RATE_MAX} turns per hour"
          }, 429)
        end

        body = read_json_body(env)
        return json_response({ error: "expected JSON body" }, 400) unless body.is_a?(Hash)

        forward_body = body.dup
        forward_body["sender"] = user  # server-stamped identity

        base = supervisor_base
        uri = URI.parse("#{base}/feedback/intake")
        begin
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(forward_body)
          resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) { |h| h.request(req) }
          parsed = begin
            JSON.parse(resp.body.to_s)
          rescue JSON::ParserError
            nil
          end
          status_code = resp.code.to_i
          status_code = 200 if status_code.zero?
          if parsed
            json_response(parsed, status_code)
          else
            [status_code, { "content-type" => "text/plain; charset=utf-8" }, [resp.body.to_s]]
          end
        rescue StandardError => e
          json_response({
            error: "agent unreachable",
            detail: e.message
          }, 502)
        end
      end

      # GET /__feedback/widget.js — serve the bundle at
      # lib/tina4/public/__feedback/widget.js. Cache-Control: no-cache,
      # must-revalidate so browsers re-check the bundle on every load.
      # Without this an old cached bundle (e.g. one that pre-dates the
      # path-block guard against rendering on /__dev/) can persist for
      # days and keep painting the bubble on the dev admin even after
      # the server-side script-tag injection is fixed.
      def handle_widget_js(_env)
        js_path = File.expand_path("public/__feedback/widget.js", __dir__)
        body = if File.file?(js_path)
                 File.binread(js_path)
               else
                 "console.warn('tina4-feedback-widget bundle not built yet');"
               end
        headers = {
          "content-type" => "application/javascript",
          "cache-control" => "no-cache, must-revalidate",
          "pragma" => "no-cache"
        }
        [200, headers, [body]]
      end

      # Dispatcher used by RackApp — returns a Rack triple if the path
      # matches a /__feedback route, else nil.
      def handle_request(env)
        path = env["PATH_INFO"] || "/"
        method = env["REQUEST_METHOD"]
        case [method, path]
        when ["GET", "/__feedback/widget.js"]
          handle_widget_js(env)
        when ["POST", "/__feedback/api/turn"]
          handle_turn(env)
        end
      end

      private

      # Locate the supervisor (Rust agent) base URL. Mirrors the
      # Tier 3 helper in dev_admin.rb so both modules agree on the
      # endpoint resolution rule.
      def supervisor_base
        if defined?(Tina4::DevAdmin) && Tina4::DevAdmin.respond_to?(:supervisor_base, true)
          return Tina4::DevAdmin.send(:supervisor_base)
        end
        base = ENV["TINA4_SUPERVISOR_URL"].to_s.strip
        return base unless base.empty?
        port = (ENV["TINA4_PORT"] || ENV["PORT"] || "7147").to_i + 2000
        "http://127.0.0.1:#{port}"
      end

      def request_path(request)
        if request.is_a?(Hash)
          (request["PATH_INFO"] || request[:path] || "").to_s
        elsif request.respond_to?(:path)
          request.path.to_s
        else
          ""
        end
      end

      # Extract Rack-style headers ({"HTTP_AUTHORIZATION" => "..."}) so
      # Tina4::Auth.authenticate_request can consume them. Accepts a
      # Rack env hash, a Tina4::Request, or a plain hash of headers.
      def request_headers(request)
        if request.is_a?(Hash) && request.keys.any? { |k| k.to_s.start_with?("HTTP_") }
          return request
        end
        if request.respond_to?(:env)
          return request.env
        end
        if request.respond_to?(:headers)
          h = request.headers || {}
          # Auth.authenticate_request looks for HTTP_AUTHORIZATION or Authorization
          rack_like = {}
          h.each do |k, v|
            key = k.to_s
            if key.downcase == "authorization"
              rack_like["HTTP_AUTHORIZATION"] = v
            else
              rack_like[key] = v
            end
          end
          return rack_like
        end
        {}
      end

      # Lightweight request wrapper used by handle_turn so the same
      # whitelist/identity helpers work whether the caller passes a Rack
      # env or a Tina4::Request.
      def build_request_wrapper(env)
        Struct.new(:path, :env, :headers).new(
          env["PATH_INFO"] || "/",
          env,
          env  # Rack env IS the headers source for Tina4::Auth
        )
      end

      def read_json_body(env)
        input = env["rack.input"]
        return nil unless input
        input.rewind if input.respond_to?(:rewind)
        raw = input.read
        return nil if raw.nil? || raw.empty?
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def json_response(data, status = 200)
        [status, { "content-type" => "application/json; charset=utf-8" },
         [JSON.generate(data)]]
      end
    end
  end
end
