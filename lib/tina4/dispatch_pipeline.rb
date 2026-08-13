# frozen_string_literal: true

require "zlib"
require "stringio"
require "digest"

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
    #   ALWAYS_STAGES    run over the triple no matter how it was produced -
    #                    including the swagger and static branches, which
    #                    return early and skip everything else.
    #   RESPONSE_STAGES  run in order over the triple, each returning a new
    #                    triple or nil to leave it unchanged. These are the
    #                    post-processing steps (logging, injection, session
    #                    save) that only apply to a dispatched response.
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

    # Runs on EVERY response, including the ones that bypass the rest.
    #
    # RFC 9110 s9.3.2 is not conditional: a HEAD response MUST NOT carry
    # content, whatever produced it. This used to live in RESPONSE_STAGES, so
    # the swagger and static branches - which return early - skipped it, and
    # `HEAD /style.css` shipped the whole file body. Measured 2026-07-31: Ruby
    # returned 15 bytes where PHP, Python and Node all returned 0.
    #
    # `compress_and_tag` and `conditional_get` (feature 40, CE-DEC-01/02) run
    # FIRST - before head_strip - so a HEAD response's preserved
    # Content-Length reflects the (possibly compressed) body the equivalent
    # GET would have sent, mirroring the Python master's build_headers() ->
    # app() ordering (compress -> tag -> 304-decide -> strip-for-HEAD).
    ALWAYS_STAGES = %i[
      compress_and_tag
      conditional_get
      head_strip
      apply_cors
    ].freeze

    RESPONSE_STAGES = %i[
      dev_inspector_capture
      request_log
      dev_toolbar_inject
      feedback_inject
      session_save
    ].freeze

    # ── The route pipeline ───────────────────────────────────────────
    #
    # #handle_route was cyclomatic complexity 24 in one 118-line function, with
    # the same two-phase shape as #call. These stages run in order until one
    # returns a Rack triple (a 401/403 or a short-circuiting middleware); if
    # none does, the handler is invoked and the result finalised.
    #
    # Ordering is BEHAVIOUR, decided and written down (ADR-0012): the post-match
    # global middleware runs BEFORE the auth gate so a rate limiter can throttle
    # a brute-force login and an access log records the 401, while the route's
    # OWN middleware runs AFTER it, so middleware attached to a secured route
    # never processes an unauthenticated request.
    ROUTE_STAGES = %i[
      prepare_route_request
      global_middleware_post
      route_auth_handler
      route_auth_gate
      route_middleware
    ].freeze

    # Per-route state shared between route stages.
    RouteContext = Struct.new(
      :env, :route, :path_params, :pre_request, :pre_response,
      :request, :response,
      keyword_init: true
    )

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

      handle_404(ctx.path, ctx.env["HTTP_ACCEPT"])
    end

    # ── ALWAYS STAGES (compression / ETag / conditional-GET) ──────────
    # Each returns a replacement Rack triple, or nil to leave it unchanged.

    # Gzip-compress + attach an ETag (feature 40, CE-DEC-01) - the ONE header
    # builder every response funnels through (a static asset or a dynamic
    # route), mirroring the Python master's build_headers(). A streaming body
    # (an Enumerator, from Response#stream) is never touched - joining it
    # would drain an SSE generator instead of letting it stream live.
    #
    # Compression: the body exceeds 1024 bytes AND Accept-Encoding offers
    # gzip AND the content type is compressible. Uses stdlib Zlib - zero new
    # dependency.
    #
    # ETag: a strong md5 hash (first 16 hex chars) over the FINAL
    # (post-compression) body, UNLESS a validator is already set - a
    # static-file response (#serve_static_file) pins its own weak
    # size+mtime ETag before this runs (CE-DEC-02), so this never overwrites
    # it with a content hash.
    def compress_and_tag(ctx, response)
      status, headers, body_parts = response
      return nil unless body_parts.is_a?(Array)

      body = body_parts.join
      new_headers = headers.dup
      changed = false

      if should_gzip?(ctx, body, new_headers)
        body = gzip_string(body)
        new_headers["content-encoding"] = "gzip"
        new_headers["vary"] = "Accept-Encoding"
        new_headers["content-length"] = body.bytesize.to_s if new_headers["content-length"]
        changed = true
      end

      if should_tag_etag?(new_headers, body, status)
        new_headers["etag"] = %("#{Digest::MD5.hexdigest(body)[0, 16]}")
        changed = true
      end

      return nil unless changed

      [status, new_headers, [body]]
    end

    # Split out of compress_and_tag (metrics/6b) to hold the complexity gate:
    # the body-size / Accept-Encoding / content-type gzip decision, named so
    # the caller reads as one line per concern instead of one three-way &&.
    def should_gzip?(ctx, body, headers)
      accept_encoding = ctx.env["HTTP_ACCEPT_ENCODING"] || ""
      content_type = headers["content-type"] || ""
      body.bytesize > 1024 && accept_encoding.include?("gzip") && compressible_content_type?(content_type)
    end

    # Split out of compress_and_tag (metrics/6b): whether this response earns
    # a content-hash ETag - no validator set already, a non-empty body, a 200.
    def should_tag_etag?(headers, body, status)
      !headers["etag"] && !body.empty? && status == 200
    end

    # Answer a matching conditional GET with a 304 that PRESERVES whichever
    # validators (ETag / Last-Modified) the 200 would have carried (feature
    # 40). A static-file 304 (#serve_static_file's own short-circuit) is
    # already terminal by the time this runs (status is 304, not 200), so the
    # guard below leaves it untouched.
    def conditional_get(ctx, response)
      status, headers, body_parts = response
      return nil unless status == 200 && body_parts.is_a?(Array)

      body = body_parts.join
      return nil if body.empty?

      etag = headers["etag"]
      last_modified = headers["last-modified"]
      return nil unless request_not_modified?(ctx, etag, last_modified)

      not_modified_headers = {}
      not_modified_headers["etag"] = etag if etag
      not_modified_headers["last-modified"] = last_modified if last_modified
      [304, not_modified_headers, [""]]
    end

    # Split out of conditional_get (metrics/6b) to hold the complexity gate.
    # RFC 7232 S6: If-None-Match, when present, decides it alone; only when
    # the request sends no If-None-Match does If-Modified-Since apply.
    def request_not_modified?(ctx, etag, last_modified)
      if_none_match = ctx.env["HTTP_IF_NONE_MATCH"]
      return etag_matches?(if_none_match, etag) if if_none_match && !if_none_match.empty?

      if_modified_since = ctx.env["HTTP_IF_MODIFIED_SINCE"]
      return false unless if_modified_since && !if_modified_since.empty? && last_modified

      begin
        Time.httpdate(last_modified).to_i <= Time.httpdate(if_modified_since).to_i
      rescue ArgumentError
        false # Unparseable date -> serve the body (never 304 on garbage).
      end
    end

    # Whether a content type benefits from gzip compression (text-ish, JSON,
    # XML, JS, SVG). Mirrors the Python master's `_is_compressible`.
    def compressible_content_type?(content_type)
      %w[text/ application/json application/xml application/javascript image/svg].any? do |needle|
        content_type.include?(needle)
      end
    end

    # Gzip-compress a string at level 6, in memory. Stdlib Zlib - zero new
    # dependency.
    def gzip_string(str)
      io = StringIO.new
      writer = Zlib::GzipWriter.new(io, 6)
      writer.write(str)
      writer.close
      io.string
    end

    # Match an If-None-Match header value against `etag` (RFC 7232 S3.2 weak
    # comparison). Shared with the static-file conditional-GET
    # (#static_not_modified?) so BOTH paths use IDENTICAL matching semantics.
    def etag_matches?(if_none_match, etag)
      return false if etag.nil? || etag.empty?
      return true if if_none_match.strip == "*"

      want = weak_etag_value(etag)
      if_none_match.split(",").any? { |candidate| weak_etag_value(candidate) == want }
    end

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

    # Stamp the CORS policy headers on every response.
    #
    # This was the gap that made Ruby's CORS unusable: CorsMiddleware only ever
    # answered the PREFLIGHT (see #cors_preflight), and `apply_headers` - the
    # method that handles the ACTUAL response - was never called from anywhere
    # in the dispatch path. Measured 2026-07-31 through the real Rack app: a
    # preflight came back 204 with Access-Control-Allow-Origin, then the real
    # GET came back 200 with no CORS headers at all, so the browser blocked it.
    # The preflight said "yes you may" and the response did not follow through.
    #
    # It lives in ALWAYS_STAGES, not RESPONSE_STAGES, so the headers survive a
    # short-circuited 401/403 and the swagger/static early-return branches. A
    # browser shown a 401 without CORS headers reports a CORS error and the
    # real status never reaches the developer debugging it (ADR-0012).
    #
    # A preflight already carries them from #cors_preflight, so re-applying
    # would be harmless but wasteful - policy_headers is idempotent either way.
    def apply_cors(ctx, response)
      status, headers, body = response
      new_headers = headers.dup
      Tina4::CorsMiddleware.apply_headers(new_headers, ctx.env)
      return nil if new_headers == headers

      [status, new_headers, body]
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

    # ── ROUTE STAGES ─────────────────────────────────────────────────
    # Each returns a Rack triple to answer the request, or nil to pass.

    # Reuse the pre-match pair when one was built, so anything the pre-match
    # middleware set (headers, request.user) reaches the handler. Path params
    # are only known now, so they are attached here.
    def prepare_route_request(ctx)
      ctx.request = ctx.pre_request || Tina4::Request.new(ctx.env)
      ctx.request.params = ctx.path_params
      # Attach the matched route so post-match middleware (CsrfMiddleware) can
      # read its metadata -- e.g. auth_required to honour a public write route
      # (.no_auth). Without this the CSRF no_auth skip is dead code, because the
      # request otherwise carries no handler/route reference.
      ctx.request.route = ctx.route
      ctx.env["tina4.request"] = ctx.request # Store for session save after response
      ctx.response = ctx.pre_response || Tina4::Response.new
      nil
    end

    # POST-match global middleware (block-based + class-based before_* methods).
    # It runs after the route matched, because middleware like CSRF reads the
    # matched route's metadata to honour no_auth. Pre-match middleware already
    # ran in #call.
    #
    # M2 - AFTER-ON-4xx RULE: when a before_* short-circuits (4xx/skip) or
    # throws (clean 500), the after-pass STILL runs so after_* can add
    # headers/logging - consistent across all 4 frameworks.
    def global_middleware_post(ctx)
      middleware = Tina4::Middleware.post_match_middleware
      return nil if Tina4::Middleware.run_before(middleware, ctx.request, ctx.response)

      Tina4::Middleware.run_after(middleware, ctx.request, ctx.response)
      ctx.response.to_rack
    end

    # Legacy per-route auth_handler.
    def route_auth_handler(ctx)
      return nil unless ctx.route.auth_handler
      return nil if ctx.route.auth_handler.call(ctx.env)

      handle_403(ctx.env["PATH_INFO"] || "/", ctx.env["HTTP_ACCEPT"])
    end

    # Secure-by-default: enforce bearer-token auth on write routes.
    #
    # Extracted onto the class so the in-process TestClient enforces the EXACT
    # same gate (parity with Python #PY2 - a tokenless write must 401 in tests
    # too, or a green test hides a live 401 and the verification lies).
    def route_auth_gate(ctx)
      unauthorized = self.class.enforce_route_auth(ctx.env, ctx.route)

      if unauthorized
        # Carry the middleware headers onto the 401. This is the case the
        # pre/post split exists for: a browser shown a 401 with no CORS headers
        # reports a CORS error, so the real status never reaches the developer.
        # enforce_route_auth builds a bare Rack tuple (a class method shared
        # with TestClient, with no Response object), so the merge happens here.
        # ctx.response carries BOTH middleware passes, not just pre-match.
        if ctx.response.respond_to?(:headers) && ctx.response.headers.is_a?(Hash)
          status, headers, body = unauthorized
          # The auth tuple wins on a genuine clash - it owns content-type.
          unauthorized = [status, ctx.response.headers.merge(headers), body]
        end
        return unauthorized
      end

      # The verified JWT payload is only on env once the gate has run.
      ctx.request.user = ctx.env["tina4.auth_payload"] if ctx.env["tina4.auth_payload"]
      nil
    end

    # Per-route class-based middleware — its before_* pass.
    def route_middleware(ctx)
      return nil unless ctx.route.respond_to?(:run_middleware)
      return nil if ctx.route.run_middleware(ctx.request, ctx.response)

      # AFTER-ON-HALT: the route's own after_* hooks still run when one of its
      # before_* hooks short-circuited, exactly as the global ones do.
      ctx.route.run_after_middleware(ctx.request, ctx.response) if ctx.route.respond_to?(:run_after_middleware)

      # Send the response the middleware SET. This used to be a hardcoded
      # [403, {"content-type" => "text/html"}, ["403 Forbidden"]], which threw
      # away the middleware's own answer: a 401 with a WWW-Authenticate header,
      # a 302 to /login and a JSON error body all arrived as the same bare 403.
      # A middleware that halts having set nothing still gets a 403 — that is
      # applied by the return-value table (Tina4::Middleware.refuse), not here.
      ctx.response.to_rack
    end

    # Invoke the route handler, wrapped in any function-style middleware.
    #
    # The call is built as a lambda so function-style middleware can wrap it.
    # Path params are still bound by name - the continuation just forwards the
    # (possibly-mutated) request/response pair the outer middleware passed in.
    #
    # Function middleware folds into a Russian-doll chain around the handler:
    # first declared is the OUTERMOST layer, receiving the request first,
    # calling next_handler to descend, and running its "after" code on the way
    # out. Class-based middleware (before_*/after_*) never comes through here:
    # its before_* pass is #route_middleware above and its after_* pass is
    # #finalise_route_response below, both via Tina4::Middleware.
    # tina4-book#141 PY-10-01 (cross-framework parity).
    def invoke_route_handler(ctx)
      handler_params = ctx.route.handler.parameters.map(&:last)
      route_params = ctx.path_params || {}

      invoke = lambda do |req, resp|
        args = handler_params.map do |name|
          if route_params.key?(name)
            route_params[name]
          elsif name == :request || name == :req
            req
          else
            resp
          end
        end
        args.empty? ? ctx.route.handler.call : ctx.route.handler.call(*args)
      end

      fn_mws = ctx.route.respond_to?(:function_middleware) ? ctx.route.function_middleware : []
      return invoke.call(ctx.request, ctx.response) if fn_mws.empty?

      chain = invoke
      fn_mws.reverse_each do |mw|
        inner = chain
        chain = ->(req, resp) { mw.call(req, resp, inner) }
      end
      chain.call(ctx.request, ctx.response)
    end

    # Turn the handler's return value into a Rack triple.
    def finalise_route_response(ctx, result)
      # Template rendering: when a template is set and the handler returned a
      # Hash, render the template with the hash as data and return the HTML.
      if ctx.route.template && result.is_a?(Hash)
        ctx.response.html(Tina4::Template.render(ctx.route.template, result))
        return ctx.response.to_rack
      end

      # Skip auto_detect if the handler already returned the response object.
      final = result.equal?(ctx.response) ? result : Tina4::Response.auto_detect(result, ctx.response)

      # Global after middleware (block-based + class-based after_* methods).
      Tina4::Middleware.run_after(Tina4::Middleware.global_middleware, ctx.request, final)

      # The route's OWN class middleware after_* hooks. Same orchestrator and
      # same discovery as the global pass. Scope order matches the before pass
      # (global, then route) — after hooks are deliberately NOT unwound in
      # reverse; that decision is being taken separately.
      ctx.route.run_after_middleware(ctx.request, final) if ctx.route.respond_to?(:run_after_middleware)

      # Inject FreshToken when a body formToken was used for auth.
      final.add_header("FreshToken", ctx.env["tina4.fresh_token"]) if ctx.env["tina4.fresh_token"]

      final.to_rack
    end
  end
end
