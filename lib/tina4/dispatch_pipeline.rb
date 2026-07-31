# frozen_string_literal: true

module Tina4
  # The dispatch pipeline: the concerns of RackApp#call, named and ordered.
  #
  # #call was one 260-line function at cyclomatic complexity 53 against a
  # ceiling of 10, on the path of every single request. Splitting it into a
  # module is not only about that number: rack_app.rb also holds static file
  # serving, the swagger UI, WebSocket upgrades and the error pages, so the
  # pipeline was interleaved with four unrelated subsystems in one 999-line
  # file. This is the pipeline, on its own, readable end to end.
  #
  # Mixed into RackApp, so a stage can still call the app's helpers
  # (#handle_route, #try_static, #dev_mode?) directly.
  module DispatchPipeline
    # ── The stages ────────────────────────────────────────
    #
    # #call was one 260-line function at cyclomatic complexity 53 against a
    # ceiling of 10, and it is on the path of every single request. The stages
    # below are that function's concerns, named and ordered as DATA so the
    # pipeline can be read, tested and compared across the four frameworks
    # without reading an implementation.
    #
    # Two phases, because the function genuinely has two:
    #
    #   REQUEST_STAGES   run in order until one RETURNS a Rack triple. That
    #                    triple is the response; later request stages do not
    #                    run. `match_route` is terminal - it always produces
    #                    one.
    #   RESPONSE_STAGES  run in order over the triple, each returning a new
    #                    triple or nil to leave it unchanged. These are the
    #                    post-processing steps (HEAD strip, logging, injection,
    #                    session save).
    #
    # Contract each stage obeys, asserted by spec/dispatch_pipeline_spec.rb:
    #   * it takes (ctx) or (ctx, response) and nothing else - no stage reads a
    #     local of #call, because there are none left to read
    #   * it never calls another stage directly; ordering lives in these lists.
    #     `method_not_allowed` and `not_found` are therefore STAGES, not
    #     helpers called by `match_route` - the fallback chain is expressed as
    #     list order like everything else
    #   * a request stage returning nil means "not mine, keep going"
    #
    # Ordering is BEHAVIOUR here, not taste: dev routes must beat route
    # matching, the pre-match middleware must run before the match so its
    # headers survive a 401 (ADR-0012), and static resolution happens inside
    # `match_route`'s not-found fallback because routes beat files (ADR-0010).
    REQUEST_STAGES = %i[
      reset_request_caches
      cors_preflight
      websocket_upgrade
      dev_routes
      feedback_routes
      global_middleware_pre
      match_route
      method_not_allowed
      not_found
    ].freeze

    RESPONSE_STAGES = %i[
      head_strip
      dev_inspector_capture
      request_log
      dev_toolbar_inject
      feedback_inject
      session_save
    ].freeze

    # Per-request state shared between stages.
    #
    # This exists so a stage can be called on its own with nothing but a
    # context - the alternative is stages reading each other's locals, which is
    # the coupling the extraction is removing. `bypass_response_stages` records
    # an EXISTING quirk rather than introducing one: the swagger and static
    # branches used to `return` straight out of #call, skipping every
    # post-processing step. See the comment on #match_route.
    DispatchContext = Struct.new(
      :env, :method, :path, :started_at,
      :pre_request, :pre_response, :matched_pattern, :matched,
      :bypass_response_stages,
      keyword_init: true
    )

    private

    # ── REQUEST STAGES ───────────────────────────────────────────────
    # Each returns a Rack triple to answer the request, or nil to pass.

    # Request-scoped query cache boundary (v3.13.23). Tina4 Ruby runs a
    # long-running Rack server, so the request-scoped DB cache (default-on)
    # would otherwise serve rows from a previous request. Clear it on every
    # live connection at the very start of each request, before any routing.
    # No-op for persistent-mode (TINA4_DB_CACHE=true) connections.
    def reset_request_caches(_ctx)
      Tina4::Database.reset_request_caches if defined?(Tina4::Database)
      nil
    end

    # Fast-path: CORS preflight. Real CORS preflight requests carry an Origin
    # header AND an Access-Control-Request-Method header - the browser is
    # asking "may I send this method?" before the actual request. If neither is
    # present, the OPTIONS is a plain protocol-introspection request (link
    # checker, monitoring probe, RFC 9110 s9.3.7 OPTIONS) and must fall through
    # to the router's generic Allow-header response. Otherwise we would shadow
    # the framework's own OPTIONS support and force every operator to
    # hand-register CORS exceptions for every introspection client.
    def cors_preflight(ctx)
      return nil unless ctx.method == "OPTIONS"
      return nil unless ctx.env["HTTP_ORIGIN"] || ctx.env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"]

      # Carry the resource's REAL method set as Allow (RFC 9110 s9.3.7) so a
      # preflight answers the same question a bare OPTIONS does, on top of the
      # CORS policy headers. See ADR-0013.
      Tina4::CorsMiddleware.preflight_response(
        ctx.env, allow: Tina4::Router.methods_allowed_for_path(ctx.path)
      )
    end

    # WebSocket upgrade - match against registered ws_routes.
    def websocket_upgrade(ctx)
      return nil unless websocket_upgrade?(ctx.env)

      ws_result = Tina4::Router.find_ws_route(ctx.path)
      return nil unless ws_result

      ws_route, ws_params = ws_result
      handle_websocket_upgrade(ctx.env, ws_route, ws_params)
    end

    # Dev dashboard routes (handled before anything else).
    def dev_routes(ctx)
      return nil unless ctx.path.start_with?("/__dev")

      # Block live-reload endpoint on the AI port - AI tools must get stable
      # responses.
      if ctx.path == "/__dev_reload" && ctx.env["tina4.ai_port"]
        return [404, { "content-type" => "text/plain" }, ["Not available on AI port"]]
      end

      Tina4::DevAdmin.handle_request(ctx.env)
    end

    # Customer feedback widget routes (parity with Python's /__feedback/*
    # surface - see tina4/feedback.rb). Always available - the master switch
    # (TINA4_ENABLE_FEEDBACK) is enforced INSIDE handle_request so route shape
    # stays stable across environments.
    def feedback_routes(ctx)
      return nil unless ctx.path.start_with?("/__feedback")

      Tina4::Feedback.handle_request(ctx.env)
    end

    # PRE-MATCH global middleware. The request/response pair is built HERE,
    # before matching, so CORS and anything else that must survive a
    # short-circuit can set headers that outlive a 401/403 - a browser shown a
    # 401 with no CORS headers reports a CORS error and hides the real status.
    #
    # The SAME pair is threaded into handle_route; building a second one would
    # silently discard whatever the pre-match pass set, which is the entire
    # point of running it. So this stage ALWAYS runs and always populates the
    # context, even when no pre-match middleware is registered.
    def global_middleware_pre(ctx)
      ctx.pre_request = Tina4::Request.new(ctx.env)
      ctx.pre_request.user = ctx.env["tina4.auth_payload"] if ctx.env["tina4.auth_payload"]
      ctx.pre_response = Tina4::Response.new

      middleware = Tina4::Middleware.pre_match_middleware
      return nil if middleware.empty?
      return nil if Tina4::Middleware.run_before(middleware, ctx.pre_request, ctx.pre_response)

      Tina4::Middleware.run_after(middleware, ctx.pre_request, ctx.pre_response)
      ctx.pre_response.to_rack
    end

    # Match a route and run it. Returns nil when nothing matched, so the
    # next stages (#method_not_allowed, then #not_found) get their turn.
    #
    # ROUTES BEAT FILES (ADR-0010): static assets and the swagger UI are
    # resolved in the not-found fallback, only once no route has claimed the
    # path. A file in public/ can arrive from a build step or a careless
    # deploy, and it must never silently shadow a reviewed route. This also
    # retired the `unless path.start_with?("/api/")` guard that used to wrap
    # the static check - a partial patch for exactly that hazard.
    def match_route(ctx)
      result = Tina4::Router.match(ctx.method, ctx.path)
      ctx.matched = result

      return nil unless result

      route, path_params = result
      ctx.matched_pattern = route.path
      handle_route(ctx.env, route, path_params, ctx.pre_request, ctx.pre_response)
    end

    # RFC 9110 conformance - before falling through to 404, check whether the
    # PATH is known to the router under any OTHER method.
    #   - OPTIONS  -> 204 with Allow (s9.3.7). A bare OPTIONS on an unknown
    #     path also returns 204 (empty Allow): OPTIONS is a discovery method,
    #     and rejecting unknown probes with 404 confuses link checkers and
    #     monitoring tools.
    #   - Any other method (PUT on GET-only, TRACE, CONNECT) -> 405 with Allow
    #     (s15.5.6 + s10.2.1) when the path exists.
    # Returns nil when nothing about the path is known, so #not_found runs.
    def method_not_allowed(ctx)
      allowed = Tina4::Router.methods_allowed_for_path(ctx.path)

      if ctx.method.to_s.upcase == "OPTIONS"
        allow_header = allowed.empty? ? "" : allowed.join(", ")
        return [204, { "allow" => allow_header, "content-length" => "0" }, [""]]
      end

      return nil if allowed.empty?

      allow_header = allowed.join(", ")
      body = %({"error":"Method Not Allowed","path":"#{ctx.path}","method":"#{ctx.method}","allow":[#{allowed.map { |m| %("#{m}") }.join(",")}],"status":405})
      [405, {
        "allow" => allow_header,
        "content-type" => "application/json",
        "content-length" => body.bytesize.to_s
      }, [body]]
    end

    # No route claimed the path. NOW try the swagger UI and the filesystem -
    # after matching, per ADR-0010.
    #
    # The swagger and static branches set `bypass_response_stages`, which
    # PRESERVES an existing quirk rather than introducing one: they used to
    # `return` straight out of #call, so they skipped HEAD stripping, the dev
    # toolbar, feedback injection and the session save. That is why a HEAD
    # request for a static file currently returns a body, in violation of RFC
    # 9110 s9.3.2. Recorded as a finding and fixed separately with its own test
    # pair - NOT silently inside this extraction.
    def not_found(ctx)
      if ctx.path == "/swagger" || ctx.path == "/swagger/"
        ctx.bypass_response_stages = true
        return serve_swagger_ui
      elsif ctx.path == "/swagger/openapi.json"
        ctx.bypass_response_stages = true
        return serve_openapi_json
      end

      static_response = try_static(ctx.path, ctx.env)
      if static_response
        ctx.bypass_response_stages = true
        return static_response
      end

      handle_404(ctx.path)
    end

    # ── RESPONSE STAGES ──────────────────────────────────────────────
    # Each returns a replacement Rack triple, or nil to leave it unchanged.

    # RFC 9110 s9.3.2: a HEAD response MUST NOT include content. Strip the body
    # unconditionally and record what Content-Length the GET would have sent -
    # cache validators, link checkers and monitoring probes use that header to
    # estimate sizes.
    def head_strip(ctx, response)
      return nil unless ctx.method.to_s.upcase == "HEAD"

      status, headers, body_parts = response
      joined = body_parts.respond_to?(:join) ? body_parts.join : body_parts.to_s
      return nil if joined.empty?

      new_headers = headers.dup
      new_headers["content-length"] = joined.bytesize.to_s
      [status, new_headers, [""]]
    end

    # Capture the request for the dev inspector.
    def dev_inspector_capture(ctx, response)
      return nil unless dev_mode? && !ctx.path.start_with?("/__dev")

      Tina4::DevAdmin.request_inspector.capture(
        method: ctx.method,
        path: ctx.path,
        status: response[0],
        duration: elapsed_ms(ctx)
      )
      nil
    end

    # Request log line (v3.13.14). The dev inspector only feeds the /__dev UI -
    # it never reached stdout, so `tina4ruby serve` printed the banner then went
    # silent. Emit a per-request line through Tina4::Log so it lands on stdout
    # (docker logs / k8s). On by default in dev, opt-in in production via
    # TINA4_LOG_REQUESTS. Same format across all four frameworks.
    def request_log(ctx, response)
      return nil unless request_logging_enabled? && !ctx.path.start_with?("/__dev")

      Tina4::Log.info("#{ctx.method} #{ctx.path} -> #{response[0]} (#{elapsed_ms(ctx)}ms)")
      nil
    end

    # Inject the dev overlay button for HTML responses in dev mode.
    def dev_toolbar_inject(ctx, response)
      return nil unless dev_mode? && !ctx.path.start_with?("/__dev")

      status, headers, body_parts = response
      content_type = headers["content-type"] || ""
      return nil unless content_type.include?("text/html")

      request_info = {
        method: ctx.method,
        path: ctx.path,
        matched_pattern: ctx.matched_pattern || "(no match)"
      }
      overlay = inject_dev_overlay(body_parts.join, request_info, ai_port: ctx.env["tina4.ai_port"])
      [status, headers, [overlay]]
    end

    # Customer feedback widget injection - runs LAST of the injectors so its
    # <script> tag survives any earlier post-processing. No-op if disabled
    # (TINA4_ENABLE_FEEDBACK off), the user is not whitelisted, the path is
    # /__dev or /__feedback, or the body is not text/html with a closing
    # </body>. Mirrors Python's server.py call site.
    def feedback_inject(ctx, response)
      status, headers, body_parts = response
      content_type = headers["content-type"] || ""
      return nil unless content_type.include?("text/html") && body_parts.respond_to?(:join)

      joined = body_parts.join
      return nil unless joined.include?("</body>")

      injected = Tina4::Feedback.inject_feedback_widget(
        Struct.new(:path, :env).new(ctx.path, ctx.env), joined
      )
      return nil if injected == joined

      new_headers = headers.dup
      new_headers["content-length"] = injected.bytesize.to_s if new_headers["content-length"]
      [status, new_headers, [injected]]
    rescue StandardError
      # Injection is best-effort - never break the response.
      nil
    end

    # Save the session and set the cookie if a session was used.
    def session_save(ctx, response)
      return nil unless ctx.matched

      request_obj = ctx.env["tina4.request"]
      return nil unless request_obj&.instance_variable_get(:@session)

      status, headers, body_parts = response
      sess = request_obj.session
      sess.save

      # Probabilistic garbage collection (~1% of requests).
      if rand(1..100) == 1
        begin
          sess.gc
        rescue StandardError
          # GC failure is non-critical - silently ignore
        end
      end

      # Read the INCOMING session cookie by the SAME configured name the write
      # side emits - via the one shared resolver (Session.cookie_name), exact
      # `name=` prefix. A hardcoded "tina4_session=" here never matches a cookie
      # renamed through TINA4_SESSION_NAME, so the auto-Set-Cookie would be
      # needlessly re-emitted on every request that already carries the renamed
      # cookie. Parity with Python's core/server._init_session cookie_prefix.
      sid = sess.id
      cookie_prefix = "#{Tina4::Session.cookie_name}="
      cookie_val = (ctx.env["HTTP_COOKIE"] || "").split(";").map(&:strip)
                                                 .find { |part| part.start_with?(cookie_prefix) }
                                                 &.slice(cookie_prefix.length..)
      if sid && sid != cookie_val
        # Route through Session#cookie_header rather than hand-writing the
        # header, so TINA4_SESSION_SECURE / _SAMESITE / _HTTPONLY / _NAME / _TTL
        # are all honoured and Secure reflects the request scheme. The old
        # hand-written literal ignored every attribute except TTL and hardcoded
        # SameSite=Lax + HttpOnly, making the security env vars silent no-ops
        # (issue #31).
        headers["set-cookie"] = sess.cookie_header
      end
      [status, headers, body_parts]
    end

    # Milliseconds since the request entered the pipeline.
    def elapsed_ms(ctx)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - ctx.started_at) * 1000).round(3)
    end
  end
end
