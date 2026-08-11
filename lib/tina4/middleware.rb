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

      # Parity alias matching Python/PHP/Node orchestrators.
      def get_global
        global_middleware.dup
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

      # Global middleware that runs BEFORE route matching.
      #
      # A middleware opts in by declaring `def self.pre_match?; true; end`.
      #
      # NOT `before_match?` - the hook discovery treats every `before_*` method
      # as a middleware hook and calls it with (request, response), so that name
      # made the flag itself run as middleware and 500 the request.
      # Everything else stays where it has always run - after matching - so
      # this is additive and no existing middleware changes behaviour.
      #
      # The split exists because the two groups need opposite things. CORS must
      # run before matching so its headers survive a short-circuited 401/403;
      # a browser that gets a 401 without them reports a CORS error and the real
      # status is invisible. CSRF must run AFTER, because it reads the matched
      # route's metadata to honour a route marked no_auth - PHP shipped exactly
      # that bypass as dead code once, because the metadata was not set yet.
      def pre_match_middleware
        global_middleware.select { |k| k.respond_to?(:pre_match?) && k.pre_match? }
      end

      # Global middleware that runs after matching, once the matched route's
      # metadata is readable. This is the default.
      def post_match_middleware
        global_middleware.reject { |k| k.respond_to?(:pre_match?) && k.pre_match? }
      end

      def clear!
        @before_handlers = []
        @after_handlers = []
        @global_middleware = []
      end

      # Run all "before" hooks: block-based handlers, then class-based before_*
      # methods (in definition order).
      #
      # Signature matches Python/PHP/Node orchestrators: pass the list of
      # middleware classes explicitly.
      #
      # THE RETURN-VALUE CONTRACT is #apply_before_result below — one table,
      # applied to EVERY before_* hook at EVERY scope. Per-route middleware
      # comes through this same method (Tina4::Route#run_middleware), so there
      # is exactly one implementation of the table, not two.
      #
      # M2 — visible-but-resilient: every before_* call is wrapped so a THROW
      # never crashes the worker. On a throw the error is LOGGED and the
      # response becomes a clean 500 ({"error":"Internal Server Error",
      # "status":500}), then processing halts (handler skipped) — deterministic,
      # never an unhandled exception. after_* still run on either halt path
      # (see the dispatcher / #run_after docstring).
      #
      # Returns true on success, or false to halt the request (handler skipped).
      def run_before(middleware_classes, request, response)
        # The response object the CALLER holds. A hook may hand back a
        # different Response; on a halt that object IS the answer, so its state
        # is adopted onto this one before returning — otherwise the dispatcher
        # would serve the object it still has a reference to and the
        # short-circuit would silently vanish.
        origin = response

        # 1. Block-based before handlers (pattern-matched). These are a
        #    Ruby-only surface (Python/PHP/Node have no block form) and keep
        #    their historical "false halts" contract: a block's value is its
        #    last expression, so reading a returned Response as a
        #    short-circuit would fire on any block ending in a chainable
        #    response call.
        before_handlers.each do |entry|
          next unless matches_pattern?(request.path, entry[:pattern])

          begin
            result = entry[:handler].call(request, response)
          rescue StandardError, ScriptError => error
            middleware_500(response, "before handler", error)
            return false
          end
          return false if result == false
        end

        # 2. Class-based middleware: call every before_* method (definition order)
        middleware_classes.each do |klass|
          before_methods_for(klass).each do |method_name|
            begin
              result = klass.send(method_name, request, response)
            rescue StandardError, ScriptError => error
              middleware_500(response, "#{class_label(klass)}.#{method_name}", error)
              return false
            end

            halt, request, response = apply_before_result(result, request, response)
            next unless halt

            adopt_response(origin, response) unless response.equal?(origin)
            return false
          end
        end

        true
      end

      # Run all "after" hooks: block-based handlers, then class-based after_*
      # methods (in definition order).
      #
      # Signature matches Python/PHP/Node orchestrators: pass the list of
      # middleware classes explicitly.
      #
      # AFTER-ON-4xx RULE (M2, documented + consistent across all 4 frameworks):
      # after_* ALWAYS run even when a before_* short-circuited with status >= 400
      # and the handler was skipped — so they can still add headers / logging.
      # The dispatcher calls #run_after unconditionally after the before/handler
      # block (including on the 4xx / throw halt path).
      #
      # M2 — every after_* call is wrapped: a THROW is LOGGED and turns the
      # response into a clean 500, then the REMAINING after_* still run (they
      # may add headers/logging). Never an unhandled crash.
      #
      # RETURN VALUES: an after_* hook shapes the response the same way a
      # before_* one does — a returned Tina4::Response BECOMES the response, a
      # returned [request, response] pair rebinds both. What it CANNOT do is
      # halt: the handler has already run, so there is nothing left to skip,
      # and stopping the remaining after_* would contradict the AFTER-ON-4xx
      # resilience rule above (they exist to add headers/logging on every path).
      # So `false` and a >= 400 status are inert here by design.
      def run_after(middleware_classes, request, response)
        origin = response

        # 1. Block-based after handlers (pattern-matched)
        after_handlers.each do |entry|
          next unless matches_pattern?(request.path, entry[:pattern])

          begin
            entry[:handler].call(request, response)
          rescue StandardError, ScriptError => error
            middleware_500(response, "after handler", error)
          end
        end

        # 2. Class-based middleware: call every after_* method (definition order)
        middleware_classes.each do |klass|
          after_methods_for(klass).each do |method_name|
            begin
              result = klass.send(method_name, request, response)
            rescue StandardError, ScriptError => error
              middleware_500(response, "#{class_label(klass)}.#{method_name}", error)
              next
            end
            if result.is_a?(Tina4::Response)
              response = result
            elsif result.is_a?(Array) && result.length == 2
              request, response = result
            end
          end
        end

        adopt_response(origin, response) unless response.equal?(origin)
        response
      end

      # Deterministic clean 500 for a middleware that threw. Logs the cause
      # (NEVER silent) then sets the response to the canonical error shape —
      # byte-identical to the Python master ({"error":"Internal Server Error",
      # "status":500} + status 500). Returns the response for chaining.
      def middleware_500(response, label, error)
        begin
          Tina4::Log.error(
            "Middleware #{label} raised #{error.class.name}: #{error.message}"
          )
        rescue StandardError
          begin
            $stderr.puts("Middleware #{label} raised #{error.class.name}: #{error.message}")
            $stderr.flush
          rescue StandardError
            # never let logging break the worker
          end
        end
        response.json({ error: "Internal Server Error", status: 500 }, 500)
      end

      # The `false` row of the return-value table, on its own.
      #
      # A middleware that halts by returning false keeps the response it set;
      # only a response still left default/empty becomes a 403. Public because
      # per-route "filter" middleware (a 2-arg callable returning false, see
      # Tina4::Route#run_middleware) must obey the SAME row as a before_* hook,
      # and the rule should exist exactly once.
      def refuse(response)
        forbid(response) if default_response?(response)
        response
      end

      private

      # ── THE BEFORE-HOOK RETURN-VALUE TABLE ────────────────────────────────
      #
      # Interpret ONE before_* hook's return value. Identical in Python, PHP,
      # Ruby and Node, and applied at EVERY scope — global (Router.use) and
      # per-route (route.middleware) both land here.
      #
      #   a Tina4::Response      SHORT-CIRCUIT. That object IS the response, at
      #                          ANY status. This is the PRIMARY rule: it is the
      #                          only one that can express a 302 redirect.
      #   [request, response]    rebind both, continue
      #   false                  SHORT-CIRCUIT. Send the response AS SET; only
      #                          when it is still default/empty does it become a
      #                          403. (Per-route middleware used to answer a
      #                          halt with a HARDCODED 403 that threw away
      #                          whatever the middleware had set — that is gone.)
      #   nil / anything else    continue
      #
      # LEGACY COMPATIBILITY PATH (retained, deliberately NOT the main
      # mechanism): after the hook returns, a response status >= 400 also
      # short-circuits, even when the hook returned nil. Middleware written
      # before the Response rule existed signals refusal that way, so it stays
      # honoured — but it cannot express a 3xx redirect, which is exactly why
      # the Response rule above is primary and this one is the fallback.
      #
      # This check used to be nested INSIDE the "returned a 2-element Array"
      # branch, so a hook that set 403 and returned nil was ignored and the
      # handler RAN — an auth middleware that refused without returning the pair
      # was a no-op. Python, PHP and Node all check the status unconditionally
      # after the call; Rails short-circuits on the response STATE, not on what
      # the filter returned. Now it is unconditional here too.
      #
      # Returns [halt?, request, response].
      def apply_before_result(result, request, response)
        if result.is_a?(Tina4::Response)
          return [true, request, result]
        elsif result.is_a?(Array) && result.length == 2
          request, response = result
        elsif result == false
          refuse(response)
          return [true, request, response]
        end

        status = status_of(response)
        return [true, request, response] if status.is_a?(Integer) && status >= 400

        [false, request, response]
      end

      # Read a response's status defensively — a middleware may hand back any
      # response-shaped object. Mirrors the Python master's
      # `getattr(response, "status_code", None) or getattr(response, "status", 0)`.
      def status_of(response)
        return response.status_code if response.respond_to?(:status_code)
        return response.status if response.respond_to?(:status)

        nil
      end

      # Has this response been left untouched? Only then does a `false` return
      # get turned into a 403 — a middleware that already answered keeps its
      # own answer.
      def default_response?(response)
        status = status_of(response)
        return false unless status.nil? || status == 200

        body = response.respond_to?(:body) ? response.body : nil
        body.to_s.empty?
      end

      # The canonical refusal, in the same shape as #middleware_500 so the two
      # framework-generated error bodies match byte for byte across all four
      # frameworks.
      def forbid(response)
        if response.respond_to?(:json)
          response.json({ error: "Forbidden", status: 403 }, 403)
        elsif response.respond_to?(:status_code=)
          response.status_code = 403
        end
        response
      end

      # Copy a response's state onto the object the CALLER still holds.
      #
      # Ruby passes references, so a hook that MUTATES the response it was given
      # needs nothing from us. This exists for the hook that hands back a
      # DIFFERENT Response object: the contract says that object IS the
      # response, and the dispatcher only ever serves the one it passed in.
      # Applied on the halt paths, where the response is the answer.
      def adopt_response(target, source)
        return target unless target.is_a?(Tina4::Response) && source.is_a?(Tina4::Response)

        target.status_code = source.status_code
        target.headers     = source.headers
        target.body        = source.body
        target.cookies     = source.cookies
        target
      end

      # Human-readable label for a middleware (class name, or the class of an
      # instance) used in the logged 500 message.
      def class_label(klass)
        if klass.is_a?(Class) || klass.is_a?(Module)
          klass.name || klass.to_s
        else
          klass.class.name || klass.class.to_s
        end
      end

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

      # Collect all class methods matching before_* in DEFINITION order.
      def before_methods_for(klass)
        discover_methods(klass, "before_")
      end

      # Collect all class methods matching after_* in DEFINITION order.
      def after_methods_for(klass)
        discover_methods(klass, "after_")
      end

      # ----------------------------------------------------------------------
      # MIDDLEWARE ORDERING (M1) — within a class, before_*/after_* methods run
      # in SOURCE-DEFINITION order, NOT alphabetical. Cross-class order is the
      # natural iteration of the registered middleware list (registration
      # order). before_* run before the handler, after_* after.
      #
      # WHY source line numbers, not instance_methods(false): in Ruby/PRISM
      # `instance_methods(false)` is NOT a reliable definition-order report —
      # once a method NAME (symbol) has been defined on any other class first,
      # that name can sort ahead in a later class's list. So we sort the
      # matching methods by their `source_location` line number, which IS the
      # true source-definition order and is immune to the symbol-table quirk.
      # (Methods with no source_location — e.g. C-defined — sort to the front
      # deterministically by name.) We walk the ancestry base→derived so
      # inherited middleware methods run before a subclass's own, de-duping
      # overrides to their first (base) position. Mirrors the Python master's
      # Middleware._discover_methods MRO walk (which leans on __dict__ insertion
      # order — the equivalent of source-definition order).
      def discover_methods(klass, prefix)
        target = klass.is_a?(Class) || klass.is_a?(Module) ? klass.singleton_class : klass.class
        seen = {}
        names = []
        target.ancestors.reverse_each do |ancestor|
          matched = begin
                      ancestor.instance_methods(false).select do |name|
                        name.to_s.start_with?(prefix) &&
                          !seen.key?(name) &&
                          klass.respond_to?(name)
                      end
                    rescue StandardError
                      []
                    end

          ordered = matched.sort_by.with_index do |name, idx|
            line = begin
                     loc = ancestor.instance_method(name).source_location
                     loc ? loc[1] : -1
                   rescue StandardError
                     -1
                   end
            # Tie-break on the symbol-table index so the result is total/stable.
            [line, idx]
          end

          ordered.each do |name|
            seen[name] = true
            names << name
          end
        end
        names
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in class-based middleware
  # ---------------------------------------------------------------------------

  # CorsClassMiddleware -- sets CORS headers from env vars on every response.
  #
  # A thin adapter over Tina4::CorsMiddleware, which owns the whole policy.
  # It used to be a SECOND, independent implementation of the same rules and
  # the two had already drifted: this copy had no wildcard/credentials guard,
  # fell back to the Referer header (a full URL, not an origin), and on an
  # allow-list MISS returned `allowed.first` - stamping some OTHER allowed
  # origin onto the response of an origin that was not allowed at all. One
  # feature, one implementation.
  class CorsClassMiddleware
    class << self
      def before_cors(request, response)
        env = request.respond_to?(:env) && request.env ? request.env : {}
        origin = request.headers["origin"] if request.respond_to?(:headers)
        env = env.merge("HTTP_ORIGIN" => origin) if origin

        Tina4::CorsMiddleware.apply_headers(response.headers, env)

        [request, response]
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

      def check(ip)
        limit  = (ENV["TINA4_RATE_LIMIT"]  || 100).to_i
        window = (ENV["TINA4_RATE_WINDOW"] || 60).to_i
        now = Time.now

        @mutex.synchronize do
          @store[ip] ||= []
          entries = @store[ip]
          entries.reject! { |t| t < now - window }

          remaining = [limit - entries.length, 0].max
          reset_at  = entries.empty? ? window : (entries.first + window - now).ceil

          if entries.length >= limit
            return [false, { limit: limit, remaining: 0, reset: reset_at, window: window }]
          end

          entries << now
          [true, { limit: limit, remaining: remaining - 1, reset: window, window: window }]
        end
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

        # v3.13.14: dropped the "[RequestLogger]" prefix for format parity
        # with Python/PHP/Node — the line is just METHOD PATH -> STATUS (Nms).
        Tina4::Log.info("#{request.method} #{request.path} -> #{response.status_code} (#{elapsed_ms}ms)")
        [request, response]
      end

      def reset!
        @mutex.synchronize { @request_times.clear }
      end
    end
  end

  # CsrfMiddleware -- validates form tokens on state-changing requests.
  #
  # OFF by default: the middleware is NOT attached unless TINA4_CSRF is truthy
  # (true/1/yes/on -- see .attach_from_env, called once at boot in
  # Tina4.initialize!) OR it is registered explicitly via
  # Router.use(CsrfMiddleware). Once attached, TINA4_CSRF=false (or 0/no) is the
  # kill switch that disables enforcement again.
  #
  # Behaviour (identical to the Python master's CsrfMiddleware.before_csrf):
  #   - Skips GET, HEAD, OPTIONS (safe methods).
  #   - Skips a public write route (.no_auth / auth: false -- auth_required
  #     false). The matched Route is attached to the request before this
  #     post-match middleware runs, so a genuinely public endpoint (login,
  #     webhook) is not gated.
  #   - Fails CLOSED: with TINA4_SECRET unset the signing secret resolves to
  #     blank (there is NO built-in default), and a blank HMAC key is publicly
  #     reproducible -- so no token can be trusted and every write is rejected
  #     (403). This is the SEC-01 no-default-secret guarantee.
  #   - Skips a request carrying a valid Authorization: Bearer token (API clients).
  #   - Reads request.body["formToken"] then the X-Form-Token header.
  #   - Rejects a token sent in the query string (403 + a logged warning) -- a
  #     URL leaks through logs, referers and history.
  #   - Validates the token with Auth.valid_token using the resolved secret, and
  #     enforces that the token's "type" claim is "form" -- a non-form JWT in the
  #     formToken slot is rejected even when its signature verifies.
  #   - If the token carries a session_id, it must match the request session's id.
  #   - Every rejection is HTTP 403 with the CSRF_INVALID envelope
  #     ({error:true, code:"CSRF_INVALID", message:, status:403}) via
  #     response.error -- byte-identical to Python/PHP/Node.
  class CsrfMiddleware
    class << self
      def before_csrf(request, response)
        # 1. Kill switch -- TINA4_CSRF in {false,0,no} disables all CSRF checks,
        #    even when the middleware is attached explicitly. Unset = enforced.
        csrf_env = ENV["TINA4_CSRF"].to_s.strip.downcase
        return [request, response] if %w[false 0 no].include?(csrf_env)

        # 2. Safe HTTP methods never change state -- skip.
        method = (request.method || "GET").upcase
        return [request, response] if %w[GET HEAD OPTIONS].include?(method)

        # 3. Public write routes (.no_auth / auth: false) skip CSRF -- a
        #    genuinely public endpoint has no session to protect. The matched
        #    Route is attached to the request before this post-match middleware
        #    runs (DispatchPipeline#prepare_route_request); a public write route
        #    has auth_required == false -- the SAME signal the auth gate reads.
        #    (Reading request.handler, as this once did, was dead code: the live
        #    request never carries a handler, so the no_auth skip never fired.)
        route = request.respond_to?(:route) ? request.route : nil
        if route.respond_to?(:auth_required) && route.auth_required == false
          return [request, response]
        end

        # 4/5. Resolve the signing secret ONCE, fail-closed. TINA4_SECRET unset
        #      resolves to blank (there is NO built-in default); a blank HMAC key
        #      is publicly reproducible, so a token signed with it -- or with the
        #      retired public 'tina4-default-secret' -- is a forgery. Reject every
        #      write rather than validate against a guessable key. SEC-01.
        secret = Tina4::Auth.hmac_secret
        if secret.to_s.empty?
          return [request, response.error(
            "CSRF_INVALID",
            "CSRF token cannot be validated: TINA4_SECRET is not set",
            403
          )]
        end

        # 6. A valid Bearer JWT means an API client authenticating per request --
        #    not subject to the cookie-replay attack CSRF defends against.
        headers = request.respond_to?(:headers) ? request.headers : {}
        auth_header = (headers["authorization"] || headers["Authorization"] || "").to_s
        if auth_header.start_with?("Bearer ")
          bearer_token = auth_header[7..].to_s.strip
          return [request, response] if !bearer_token.empty? && Tina4::Auth.valid_token(bearer_token)
        end

        # 7. A token in the query string leaks through logs/referers/history --
        #    reject it. Read the QUERY STRING only, never request.params, which
        #    merges the body (a legit body token would false-trip this check).
        query = request.respond_to?(:query) ? request.query : {}
        query = {} unless query.is_a?(Hash)
        if !query["formToken"].to_s.empty?
          Tina4::Log.warning("[CSRF] Token found in query string — rejected for security")
          return [request, response.error(
            "CSRF_INVALID",
            "Form token must not be sent in the URL query string",
            403
          )]
        end

        # 8. Extract the token: body first, then the X-Form-Token header.
        token = nil
        body = request.respond_to?(:body) ? request.body : nil
        token = body["formToken"] if body.is_a?(Hash)
        if token.nil? || token.to_s.empty?
          token = headers["X-Form-Token"] || headers["x-form-token"]
        end

        # 9. Missing token -- reject.
        if token.nil? || token.to_s.empty?
          return [request, response.error("CSRF_INVALID", "Invalid or missing form token", 403)]
        end

        # 10. Validate signature + expiry with the resolved secret. valid_token
        #     returns the verified payload Hash (or nil) in 3.13.0+.
        payload = Tina4::Auth.valid_token(token.to_s)
        unless payload
          return [request, response.error("CSRF_INVALID", "Invalid or missing form token", 403)]
        end

        # 11. Enforce the form-token TYPE -- a valid signature is not enough. A
        #     non-form JWT (e.g. an auth/session token) must never be accepted in
        #     the formToken slot.
        payload = {} unless payload.is_a?(Hash)
        if payload["type"] != "form"
          return [request, response.error("CSRF_INVALID", "Invalid or missing form token", 403)]
        end

        # 12. Session binding -- a token minted for one session cannot be replayed
        #     against another. Read the request session's OWN id: Tina4::Session
        #     exposes get_session_id (NOT session_id -- reading session_id then
        #     session.get("session_id") looked up a DATA key, never the id, so
        #     binding silently never fired against a real session). A plain Hash
        #     session exposes "session_id".
        token_session_id = payload["session_id"]
        if token_session_id
          session = request.respond_to?(:session) ? request.session : nil
          current_session_id =
            if session.nil?
              nil
            elsif session.respond_to?(:session_id)
              session.session_id
            elsif session.respond_to?(:get_session_id)
              session.get_session_id
            elsif session.is_a?(Hash)
              session["session_id"]
            end

          if current_session_id && token_session_id != current_session_id
            return [request, response.error("CSRF_INVALID", "Invalid or missing form token", 403)]
          end
        end

        # 13. All checks passed.
        [request, response]
      end

      # Auto-attach CsrfMiddleware when TINA4_CSRF is enabled in the environment.
      #
      # CSRF is OFF by default: with TINA4_CSRF unset the middleware is never
      # attached, so a default app has no CSRF gate. A truthy value
      # (true/1/yes/on, case-insensitive) attaches it globally so every
      # state-changing route is gated -- the env flag is the switch, no code
      # change needed. Idempotent (Middleware.use de-dupes). Returns true when the
      # middleware is now attached. Mirrors the Python master's
      # attach_csrf_from_env; the framework calls it once at boot
      # (Tina4.initialize!). A false/0/no value still lets an explicit
      # Router.use(CsrfMiddleware) opt-in be disabled at runtime by the kill
      # switch in before_csrf.
      def attach_from_env
        value = ENV["TINA4_CSRF"].to_s.strip.downcase
        if %w[true 1 yes on].include?(value)
          Tina4::Middleware.use(Tina4::CsrfMiddleware)
          return true
        end
        false
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
      # Register this middleware in the default chain (secure-by-default).
      #
      # Unlike CSRF (opt-in via TINA4_CSRF) this is UNCONDITIONAL: a default app
      # ships the security headers with no opt-in -- the SECHDR-DEC-01 posture
      # that closes the SECHDR-OFF-BY-DEFAULT gap (the middleware existed with good
      # defaults but was never registered). Idempotent (Middleware.use de-dupes).
      # The framework calls it once at boot (Tina4.initialize!). Returns true.
      def attach
        Tina4::Middleware.use(self)
        true
      end

      def before_security(request, response)
        response.headers["X-Frame-Options"] = ENV["TINA4_FRAME_OPTIONS"] || "SAMEORIGIN"
        response.headers["X-Content-Type-Options"] = "nosniff"

        # HSTS is HTTPS-only (SECHDR-DEC-02): a downgrade-protection header on a
        # plain-HTTP response is inert at best and ships a bad max-age on an
        # unencrypted scheme at worst. Emit it ONLY when TINA4_HSTS is set AND the
        # request is HTTPS -- Request.secure_scheme? honours x-forwarded-proto
        # (first hop) then rack.url_scheme, the same source of truth the session
        # cookie's Secure flag uses. Defensive env lookup keeps a non-Request from
        # turning every response into a 500 now that this runs on every request.
        hsts = ENV["TINA4_HSTS"] || ""
        env = request.respond_to?(:env) ? request.env : {}
        if !hsts.empty? && Tina4::Request.secure_scheme?(env)
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
