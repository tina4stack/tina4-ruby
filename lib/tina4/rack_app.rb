# frozen_string_literal: true
require "json"
require "securerandom"
require "time"
require "uri"

module Tina4
  # Middleware wrapper that tags requests arriving on the AI dev port.
  # Suppresses live-reload behaviour so AI tools get stable responses.
  class AiPortRackApp
    def initialize(app)
      @app = app
    end

    def call(env)
      env["tina4.ai_port"] = true
      @app.call(env)
    end
  end

  class RackApp
    class << self
      # The process-wide RackApp — the app actually serving traffic. Set by
      # #initialize (last one wins, the same convention as
      # Tina4::WebSocket.current). Tina4::TestClient defaults to this so an
      # in-process test request runs through the SAME app object a live request
      # does, instead of building a second one with a different static root and
      # clobbering the shared WebSocket engine. (feature-recount D6)
      attr_accessor :current
    end

    STATIC_DIRS = %w[public src/public src/assets assets].freeze

    # CORS is now handled by Tina4::CorsMiddleware

    # Framework's own public directory (bundled static assets like the logo)
    FRAMEWORK_PUBLIC_DIR = File.expand_path("public", __dir__).freeze

    def initialize(root_dir: Dir.pwd)
      @root_dir = root_dir
      # Pre-compute static roots at boot (not per-request)
      # Project dirs are checked first; framework's bundled public dir is the fallback
      project_roots = STATIC_DIRS.map { |d| File.join(root_dir, d) }
                                 .select { |d| Dir.exist?(d) }
      fallback = Dir.exist?(FRAMEWORK_PUBLIC_DIR) ? [FRAMEWORK_PUBLIC_DIR] : []
      @static_roots = (project_roots + fallback).freeze

      # Shared WebSocket engine for route-based WS handling. Publish it as the
      # process-wide "current" engine so Frond.push_live (and other framework
      # code) can broadcast live-block updates without a threaded reference.
      @websocket_engine = Tina4::WebSocket.new
      Tina4::WebSocket.current = @websocket_engine

      # Register the dev-reload WebSocket route (debug mode only) so a browser
      # handshake to /__dev_reload is accepted and held open by the connection
      # manager. Without this the handshake never matches a route and falls
      # through to 404, silently degrading the whole reloader to polling.
      RackApp.register_dev_reload_ws if dev_mode?

      # Publish as the process-wide app (see RackApp.current).
      RackApp.current = self
    end

    # WebSocket handler for the dev-reload channel (/__dev_reload).
    #
    # Connections are accepted and held open; the shared Tina4::DevReload
    # manager keeps a reference (wired in handle_websocket_upgrade) so
    # POST /__dev/api/reload can broadcast an instant reload to every browser.
    # Incoming frames are ignored — the open socket is the whole point.
    DEV_RELOAD_WS_HANDLER = proc { |_connection, _event, _data| nil }

    # Register the /__dev_reload WebSocket route (idempotent). Guarded on the
    # router's actual state rather than a one-shot flag so that a Router.clear!
    # (specs, hot-reload rescans) followed by a fresh RackApp re-registers it.
    def self.register_dev_reload_ws
      return if Tina4::Router.find_ws_route("/__dev_reload")

      Tina4::Router.websocket("/__dev_reload", &DEV_RELOAD_WS_HANDLER)
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"] || "/"
      request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Request-scoped query cache boundary (v3.13.23). Tina4 Ruby runs a
      # long-running Rack server, so the request-scoped DB cache (default-on)
      # would otherwise serve rows from a previous request. Clear it on every
      # live connection at the very start of each request, before any routing.
      # No-op for persistent-mode (TINA4_DB_CACHE=true) connections.
      Tina4::Database.reset_request_caches if defined?(Tina4::Database)

      # Fast-path: CORS preflight. Real CORS preflight requests carry an
      # Origin header AND an Access-Control-Request-Method header — the
      # browser is asking "may I send this method?" before the actual
      # request. If neither is present, the OPTIONS is a plain protocol-
      # introspection request (link checker, monitoring probe, RFC 9110
      # §9.3.7 OPTIONS) and must fall through to the router's generic
      # Allow-header response. Otherwise we'd shadow the framework's own
      # OPTIONS support and force every operator to hand-register CORS
      # exceptions for every introspection client.
      if method == "OPTIONS" && (env["HTTP_ORIGIN"] || env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"])
        return Tina4::CorsMiddleware.preflight_response(env)
      end

      # WebSocket upgrade — match against registered ws_routes
      if websocket_upgrade?(env)
        ws_result = Tina4::Router.find_ws_route(path)
        if ws_result
          ws_route, ws_params = ws_result
          return handle_websocket_upgrade(env, ws_route, ws_params)
        end
      end

      # Dev dashboard routes (handled before anything else)
      if path.start_with?("/__dev")
        # Block live-reload endpoint on the AI port — AI tools must get stable responses
        if path == "/__dev_reload" && env["tina4.ai_port"]
          return [404, { "content-type" => "text/plain" }, ["Not available on AI port"]]
        end
        dev_response = Tina4::DevAdmin.handle_request(env)
        return dev_response if dev_response
      end

      # Customer feedback widget routes (parity with Python's /__feedback/*
      # surface — see tina4/feedback.rb). Always available — the master
      # switch (TINA4_ENABLE_FEEDBACK) is enforced INSIDE handle_request
      # so route shape stays stable across environments.
      if path.start_with?("/__feedback")
        fb_response = Tina4::Feedback.handle_request(env)
        return fb_response if fb_response
      end

      # Route matching. ROUTES BEAT FILES (ADR-0010): static assets and the
      # swagger UI are resolved in the not-found fallback below, only once no
      # route has claimed the path. A file in public/ can arrive from a build
      # step or a careless deploy, and it must never silently shadow a
      # reviewed route.
      #
      # This also retires the `unless path.start_with?("/api/")` guard that
      # used to wrap the static check. That guard existed ONLY because
      # file-first would otherwise shadow API routes - a partial patch for
      # exactly the hazard route-first removes outright.
      # PRE-MATCH global middleware. Built here, before matching, so CORS and
      # anything else that must survive a short-circuit can set headers that
      # outlive a 401/403 - a browser shown a 401 with no CORS headers reports
      # a CORS error and hides the real status.
      #
      # The SAME request and response objects are threaded into handle_route
      # below; building a second pair would silently discard whatever the
      # pre-match pass set, which is the entire point of running it.
      pre_request = Tina4::Request.new(env)
      pre_request.user = env["tina4.auth_payload"] if env["tina4.auth_payload"]
      pre_response = Tina4::Response.new
      pre_middleware = Tina4::Middleware.pre_match_middleware
      unless pre_middleware.empty?
        unless Tina4::Middleware.run_before(pre_middleware, pre_request, pre_response)
          Tina4::Middleware.run_after(pre_middleware, pre_request, pre_response)
          return pre_response.to_rack
        end
      end

      result = Tina4::Router.match(method, path)
      if result
        route, path_params = result
        rack_response = handle_route(env, route, path_params, pre_request, pre_response)
        matched_pattern = route.path
      else
        # RFC 9110 conformance — before falling through to 404, check whether
        # the PATH is known to the router under any OTHER method.
        #   - OPTIONS request → 204 with Allow header (§9.3.7). Bare OPTIONS
        #     on an unknown path also returns 204 (empty Allow header) —
        #     OPTIONS is a discovery method; rejecting unknown probes with
        #     404 confuses link checkers and monitoring tools and breaks
        #     CORS preflight that lacks the Origin/ACRM headers our earlier
        #     fast-path requires. Matches PHP/Node behaviour. Fixes
        #     spec/rack_app_spec.rb OPTIONS preflight.
        #   - Any other method (PUT on GET-only, TRACE, CONNECT, etc.)
        #     → 405 with Allow header (§15.5.6 + §10.2.1) when the path
        #     exists; → 404 when nothing about the path is known.
        allowed = Tina4::Router.methods_allowed_for_path(path)
        if method.to_s.upcase == "OPTIONS"
          allow_header = allowed.empty? ? "" : allowed.join(", ")
          rack_response = [204, { "allow" => allow_header, "content-length" => "0" }, [""]]
          matched_pattern = nil
        elsif !allowed.empty?
          allow_header = allowed.join(", ")
          body = %({"error":"Method Not Allowed","path":"#{path}","method":"#{method}","allow":[#{allowed.map { |m| %("#{m}") }.join(",")}],"status":405})
          rack_response = [405, {
            "allow" => allow_header,
            "content-type" => "application/json",
            "content-length" => body.bytesize.to_s
          }, [body]]
          matched_pattern = nil
        else
          # No route claimed the path. NOW try the swagger UI and the
          # filesystem - after matching, per ADR-0010.
          if path == "/swagger" || path == "/swagger/"
            return serve_swagger_ui
          elsif path == "/swagger/openapi.json"
            return serve_openapi_json
          end

          static_response = try_static(path, env)
          return static_response if static_response

          rack_response = handle_404(path)
          matched_pattern = nil
        end
      end

      # RFC 9110 §9.3.2: a HEAD response MUST NOT include content. Strip
      # the body unconditionally and record what Content-Length the GET
      # would have sent. Cache validators / link checkers / monitoring
      # probes use that header to estimate sizes.
      if method.to_s.upcase == "HEAD"
        status, headers, body_parts = rack_response
        joined = body_parts.respond_to?(:join) ? body_parts.join : body_parts.to_s
        unless joined.empty?
          new_headers = headers.dup
          new_headers["content-length"] = joined.bytesize.to_s
          rack_response = [status, new_headers, [""]]
        end
      end

      # Capture request for dev inspector
      if dev_mode? && !path.start_with?("/__dev")
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - request_start) * 1000).round(3)
        Tina4::DevAdmin.request_inspector.capture(
          method: method,
          path: path,
          status: rack_response[0],
          duration: duration_ms
        )
      end

      # Request log line (v3.13.14). The dev inspector above only feeds the
      # /__dev UI — it never reached stdout, so `tina4ruby serve` printed the
      # banner then went silent. Emit a per-request line through Tina4::Log so
      # it lands on stdout (docker logs / k8s). On by default in dev, opt-in in
      # production via TINA4_LOG_REQUESTS. Same format across all four frameworks.
      if request_logging_enabled? && !path.start_with?("/__dev")
        log_elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - request_start) * 1000).round(3)
        Tina4::Log.info("#{method} #{path} -> #{rack_response[0]} (#{log_elapsed}ms)")
      end

      # Inject dev overlay button for HTML responses in dev mode
      if dev_mode? && !path.start_with?("/__dev")
        status, headers, body_parts = rack_response
        content_type = headers["content-type"] || ""
        if content_type.include?("text/html")
          request_info = {
            method: method,
            path: path,
            matched_pattern: matched_pattern || "(no match)",
          }
          joined = body_parts.join
          overlay = inject_dev_overlay(joined, request_info, ai_port: env["tina4.ai_port"])
          rack_response = [status, headers, [overlay]]
        end
      end

      # Customer feedback widget injection — runs LAST so its <script>
      # tag survives any earlier post-processing. No-op if disabled
      # (TINA4_ENABLE_FEEDBACK off), the user isn't whitelisted, the
      # path is /__dev or /__feedback, or the body isn't text/html with
      # a closing </body> tag. Mirrors Python's server.py call site —
      # see tina4_python/core/server.py around line 1543.
      begin
        status, headers, body_parts = rack_response
        content_type = headers["content-type"] || ""
        if content_type.include?("text/html") && body_parts.respond_to?(:join)
          joined = body_parts.join
          if joined.include?("</body>")
            injected = Tina4::Feedback.inject_feedback_widget(
              Struct.new(:path, :env).new(path, env),
              joined
            )
            if injected != joined
              new_headers = headers.dup
              new_headers["content-length"] = injected.bytesize.to_s if new_headers["content-length"]
              rack_response = [status, new_headers, [injected]]
            end
          end
        end
      rescue StandardError
        # Injection is best-effort — never break the response.
      end

      # Save session and set cookie if session was used
      if result && defined?(rack_response)
        status, headers, body_parts = rack_response
        request_obj = env["tina4.request"]
        if request_obj&.instance_variable_get(:@session)
          sess = request_obj.session
          sess.save

          # Probabilistic garbage collection (~1% of requests)
          if rand(1..100) == 1
            begin
              sess.gc
            rescue StandardError
              # GC failure is non-critical — silently ignore
            end
          end

          sid = sess.id
          # Read the INCOMING session cookie by the SAME configured name the
          # write side emits — via the one shared resolver (Session.cookie_name),
          # exact `name=` prefix. A hardcoded "tina4_session=" here never matches
          # a cookie renamed through TINA4_SESSION_NAME, so the auto-Set-Cookie
          # would be needlessly re-emitted on every request that already carries
          # the renamed session cookie. Parity with Python's
          # core/server._init_session cookie_prefix.
          cookie_prefix = "#{Tina4::Session.cookie_name}="
          cookie_val = (env["HTTP_COOKIE"] || "").split(";").map(&:strip)
                                                 .find { |part| part.start_with?(cookie_prefix) }
                                                 &.slice(cookie_prefix.length..)
          if sid && sid != cookie_val
            # Route through Session#cookie_header rather than hand-writing the
            # header, so TINA4_SESSION_SECURE / _SAMESITE / _HTTPONLY / _NAME /
            # _TTL are all honoured and Secure reflects the request scheme. The
            # old hand-written literal ignored every attribute except TTL and
            # hardcoded SameSite=Lax + HttpOnly, making the security env vars
            # silent no-ops (issue #31).
            headers["set-cookie"] = sess.cookie_header
          end
          rack_response = [status, headers, body_parts]
        end
      end

      rack_response
    rescue => e
      handle_500(e, env)
    end

    # Dispatch a pre-built Request through the Rack app and return the Rack response triple.
    # Useful for testing and embedding without starting an HTTP server.
    def handle(request)
      env = request.env
      env["rack.input"].rewind if env["rack.input"].respond_to?(:rewind)
      call(env)
    end

    private

    def handle_route(env, route, path_params, pre_request = nil, pre_response = nil)
      # Auth check (legacy per-route auth_handler)
      if route.auth_handler
        auth_result = route.auth_handler.call(env)
        return handle_403(env["PATH_INFO"] || "/") unless auth_result
      end

      # Secure-by-default: enforce bearer-token auth on write routes.
      # Extracted into a class method so the in-process TestClient enforces the
      # EXACT same gate (parity with Python #PY2 — a tokenless write must 401 in
      # tests too, or a green test hides a live 401 and the verification lies).
      unauthorized = self.class.enforce_route_auth(env, route)
      if unauthorized
        # Carry the PRE-match middleware's headers onto the 401. This is the
        # case the pre/post split exists for: a browser shown a 401 with no
        # CORS headers reports a CORS error, so the real status never reaches
        # the developer. enforce_route_auth builds a bare Rack tuple (it is a
        # class method shared with TestClient and has no Response object), so
        # the merge happens here rather than inside it.
        if pre_response.respond_to?(:headers) && pre_response.headers.is_a?(Hash)
          status, headers, body = unauthorized
          # The auth tuple wins on a genuine clash - it owns content-type.
          unauthorized = [status, pre_response.headers.merge(headers), body]
        end
        return unauthorized
      end

      # Reuse the pre-match pair when one was built, so anything the pre-match
      # middleware set (headers, request.user) reaches the handler. Path params
      # are only known now, so they are attached here.
      request = pre_request || Tina4::Request.new(env)
      request.path_params = path_params
      request.user = env["tina4.auth_payload"] if env["tina4.auth_payload"]
      env["tina4.request"] = request  # Store for session save after response
      response = pre_response || Tina4::Response.new

      # Run global middleware (block-based + class-based before_* methods).
      # M2 — AFTER-ON-4xx RULE: when a before_* short-circuits (4xx/skip) or
      # throws (clean 500), the after-pass STILL runs so after_* can add
      # headers/logging — consistent across all 4 frameworks.
      # POST-match global middleware: the default. It runs here, after the
      # route matched, because middleware like CSRF reads the matched route's
      # metadata to honour no_auth. Pre-match middleware already ran in #call.
      post_middleware = Tina4::Middleware.post_match_middleware
      unless Tina4::Middleware.run_before(post_middleware, request, response)
        Tina4::Middleware.run_after(post_middleware, request, response)
        return response.to_rack
      end

      # Run per-route middleware
      if route.respond_to?(:run_middleware)
        unless route.run_middleware(request, response)
          return [403, { "content-type" => "text/html" }, ["403 Forbidden"]]
        end
      end

      # Build the route-handler call as a lambda so function-style
      # middleware can wrap it. Path params are still bound by name —
      # the continuation just forwards the (possibly-mutated)
      # request/response pair the outer middleware chose to pass in.
      handler_params = route.handler.parameters.map(&:last)
      route_params = path_params || {}
      invoke_handler = lambda do |req, resp|
        args = handler_params.map do |name|
          if route_params.key?(name)
            route_params[name]
          elsif name == :request || name == :req
            req
          else
            resp
          end
        end
        args.empty? ? route.handler.call : route.handler.call(*args)
      end

      # Fold any function-style middleware on this route into a
      # Russian-doll chain wrapping the handler. First declared is the
      # outermost layer — it receives the request first, calls
      # next_handler to descend, and runs its "after" code on the way
      # out. Class-based middleware (before_*/after_*) is handled
      # separately by run_middleware above and never goes through here.
      # tina4-book#141 PY-10-01 (cross-framework parity).
      fn_mws = route.respond_to?(:function_middleware) ? route.function_middleware : []
      if fn_mws.empty?
        result = invoke_handler.call(request, response)
      else
        chain = invoke_handler
        fn_mws.reverse_each do |mw|
          inner = chain
          chain = lambda { |req, resp| mw.call(req, resp, inner) }
        end
        result = chain.call(request, response)
      end

      # Template rendering: when a template is set and the handler returned a Hash,
      # render the template with the hash as data and return the HTML response.
      if route.template && result.is_a?(Hash)
        html = Tina4::Template.render(route.template, result)
        response.html(html)
        return response.to_rack
      end

      # Skip auto_detect if handler already returned the response object
      final_response = result.equal?(response) ? result : Tina4::Response.auto_detect(result, response)

      # Run global after middleware (block-based + class-based after_* methods)
      Tina4::Middleware.run_after(Tina4::Middleware.global_middleware, request, final_response)

      # Inject FreshToken header when body formToken was used for auth
      if env["tina4.fresh_token"]
        final_response.add_header("FreshToken", env["tina4.fresh_token"])
      end

      final_response.to_rack
    end

    def try_static(path, env = nil)
      return nil if path.include?("..")

      # The framework ships the Swagger UI as STATIC assets under
      # lib/tina4/public/swagger/. Static serving is independent of the gated
      # /swagger handler, so without this check the UI stays reachable in
      # production via '/swagger/index.html' or '/swagger/oauth2-redirect.html'
      # even when swagger is disabled -- silently bypassing
      # TINA4_SWAGGER_ENABLED / TINA4_DEBUG. (A bare '/swagger' and '/swagger/'
      # are already intercepted by the gated handler, which is why this leak hid.)
      normalised_path = path.start_with?("/") ? path : "/#{path}"
      if (normalised_path == "/swagger" || normalised_path.start_with?("/swagger/")) &&
         !Tina4::Swagger.enabled?
        return nil
      end

      @static_roots.each do |root|
        full_path = File.join(root, path)
        if File.file?(full_path)
          return serve_static_file(full_path, env)
        end

        # Only try index.html for directory-like paths
        if path.end_with?("/") || !path.include?(".")
          index_path = File.join(full_path, "index.html")
          if File.file?(index_path)
            return serve_static_file(index_path, env)
          end
        end
      end
      nil
    end

    # Serve a static asset with cache-revalidation semantics (parity with the
    # Python master). A static file may be cached by the browser but MUST be
    # revalidated before use, so a redeployed asset reaches the browser on the
    # next load without a manual hard refresh — and an unchanged asset costs a
    # cheap 304 round-trip, not a re-download.
    #
    # Validators are derived from the file's mtime + size (a weak ETag) plus a
    # Last-Modified date, so we never have to read/hash the bytes to build them.
    # When the request already carries a matching validator (If-None-Match, or
    # If-Modified-Since not older than the file) we answer a bare 304 with no
    # body. Stdlib only — no new dependency.
    def serve_static_file(full_path, env = nil)
      ext = File.extname(full_path).downcase
      content_type = Tina4::Response::MIME_TYPES[ext] || "application/octet-stream"

      stat = File.stat(full_path)
      etag = %(W/"#{stat.mtime.to_i.to_s(16)}-#{stat.size.to_s(16)}")
      last_modified = stat.mtime.httpdate

      headers = {
        "content-type" => content_type,
        "cache-control" => "no-cache, must-revalidate",
        "etag" => etag,
        "last-modified" => last_modified
      }

      if env && static_not_modified?(env, etag, stat.mtime)
        # 304 carries the validators (RFC 9110 §15.4.5) but NO body.
        return [304, {
          "cache-control" => "no-cache, must-revalidate",
          "etag" => etag,
          "last-modified" => last_modified
        }, []]
      end

      [200, headers, [File.binread(full_path)]]
    end

    # Decide whether a conditional GET for a static asset can be answered 304.
    # If-None-Match takes precedence over If-Modified-Since (RFC 9110 §13.1.3);
    # ETag comparison is weak (a leading `W/` is ignored on either side).
    def static_not_modified?(env, etag, mtime)
      if_none_match = env["HTTP_IF_NONE_MATCH"]
      if if_none_match && !if_none_match.empty?
        return true if if_none_match.strip == "*"

        want = weak_etag_value(etag)
        return if_none_match.split(",").any? { |candidate| weak_etag_value(candidate) == want }
      end

      if_modified_since = env["HTTP_IF_MODIFIED_SINCE"]
      if if_modified_since && !if_modified_since.empty?
        begin
          # HTTP dates have 1-second resolution — compare at whole seconds so a
          # sub-second mtime never spuriously looks "newer" than the client copy.
          return mtime.to_i <= Time.httpdate(if_modified_since).to_i
        rescue ArgumentError
          return false # Unparseable date — treat as no validator, serve the body.
        end
      end

      false
    end

    # Normalise an ETag for weak comparison: drop a leading `W/` and surrounding
    # whitespace so `W/"abc"` and `"abc"` compare equal.
    def weak_etag_value(tag)
      tag.to_s.strip.sub(/\AW\//, "")
    end

    def serve_swagger_ui
      # Honour the documented production on/off switch (TINA4_SWAGGER_ENABLED,
      # else TINA4_DEBUG) — before v3.13.40 this was never checked and /swagger
      # (the full API surface) was served unconditionally in production.
      return [404, { "content-type" => "text/plain" }, ["Not Found"]] unless Tina4::Swagger.enabled?

      # The UI assets load from a CDN by default (keeps the framework
      # zero-dependency — no vendored ~1.4MB swagger-ui-dist). Air-gapped
      # deployments point TINA4_SWAGGER_UI_CDN at a self-hosted mirror.
      cdn = (ENV["TINA4_SWAGGER_UI_CDN"] || "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5").sub(%r{/+\z}, "")
      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>API Documentation</title>
          <link rel="stylesheet" href="#{cdn}/swagger-ui.css">
        </head>
        <body>
          <div id="swagger-ui"></div>
          <script src="#{cdn}/swagger-ui-bundle.js"></script>
          <script>
            SwaggerUIBundle({ url: '/swagger/openapi.json', dom_id: '#swagger-ui' });
          </script>
        </body>
        </html>
      HTML
      [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
    end

    def serve_openapi_json
      return [404, { "content-type" => "application/json; charset=utf-8" }, ['{"error":"Not Found"}']] unless Tina4::Swagger.enabled?

      # Regenerate per request — DevReload adds routes in-process (same PID), so
      # a memoized spec would go stale until restart. Swagger.generate is cheap.
      [200, { "content-type" => "application/json; charset=utf-8" }, [JSON.generate(Tina4::Swagger.generate)]]
    end

    def handle_403(path = "")
      body = Tina4::Template.render_error(403, { "path" => path }) rescue "403 Forbidden"
      [403, { "content-type" => "text/html" }, [body]]
    end

    def handle_404(path)
      # Try serving a template file (e.g. /hello -> src/templates/pages/hello.twig)
      template_response = try_serve_template(path)
      return template_response if template_response

      # Show landing page for GET "/" — but ONLY in dev mode.
      # Production never shows it, so the framework version, dev-admin link,
      # and gallery never leak to real users. Symmetric with /__dev/* gating.
      return render_landing_page if path == "/" && dev_mode?

      Tina4::Log.warning("404 Not Found: #{path}")
      body = Tina4::Template.render_error(404, { "path" => path }) rescue "404 Not Found"
      [404, { "content-type" => "text/html" }, [body]]
    end

    # Honour TINA4_TEMPLATE_ROUTING=off|false|0|no|disabled as an explicit
    # kill switch. Default: enabled. Drop a file in src/templates/pages/ and
    # it serves at the matching URL — the zero-config Tina4 convention.
    def template_auto_routing_enabled?
      val = ENV.fetch("TINA4_TEMPLATE_ROUTING", "on").to_s.strip.downcase
      !%w[off false 0 no disabled].include?(val)
    end

    def should_show_landing_page?
      # Check if any index template exists in src/templates/
      templates_dir = File.join(@root_dir, "src", "templates")
      %w[index.html index.twig index.erb].none? { |f| File.file?(File.join(templates_dir, f)) }
    end

    def try_serve_template(path)
      tpl_file = resolve_template(path)
      return nil unless tpl_file

      templates_dir = File.join(@root_dir, "src", "templates")
      body = Tina4::Template.render(tpl_file, {}) rescue File.read(File.join(templates_dir, tpl_file))
      [200, { "content-type" => "text/html" }, [body]]
    end

    # Resolve a URL path to a template file in src/templates/pages/.
    #
    # Only files inside ``src/templates/pages/`` auto-route from a URL.
    # Anything in ``src/templates/`` outside ``pages/`` (partials, layouts,
    # base.twig, errors, components) is never served standalone — those
    # remain renderable via {% include %} / {% extends %} / explicit render
    # calls but never auto-serve from a URL.
    #
    # Files starting with ``_`` (e.g. pages/_helper.twig) are always skipped
    # even within pages/ — Hugo/Jekyll convention for private partials.
    #
    # Dev mode: checks filesystem every time for live changes.
    # Production: uses a cached lookup built once at startup.
    #
    # The whole feature can be turned off with ``TINA4_TEMPLATE_ROUTING=off``.
    def resolve_template(path)
      return nil unless template_auto_routing_enabled?

      clean_path = path.sub(%r{^/}, "")
      clean_path = "index" if clean_path.empty?

      # Skip underscore-prefixed segments — private files even within pages/.
      return nil if clean_path.split("/").any? { |seg| seg.start_with?("_") }

      is_dev = %w[true 1 yes].include?(ENV.fetch("TINA4_DEBUG", "false").downcase)

      if is_dev
        pages_dir = File.join(@root_dir, "src", "templates", "pages")
        %w[.twig .html].each do |ext|
          candidate_inside_pages = clean_path + ext
          if File.file?(File.join(pages_dir, candidate_inside_pages))
            return File.join("pages", candidate_inside_pages)
          end
        end
        return nil
      end

      # Production: cached lookup
      @template_cache ||= build_template_cache
      @template_cache[clean_path]
    end

    # Scan src/templates/pages/ once and build url_path -> template_file lookup.
    # Only files under pages/ are eligible — partials, layouts, base.twig,
    # errors etc. remain renderable via explicit render calls but never
    # auto-serve from a URL.
    def build_template_cache
      cache = {}
      pages_dir = File.join(@root_dir, "src", "templates", "pages")
      return cache unless File.directory?(pages_dir)

      Dir.glob(File.join(pages_dir, "**", "*.{twig,html}")).each do |f|
        rel_inside_pages = f.sub(pages_dir + File::SEPARATOR, "").tr("\\", "/")
        # Skip private files even within pages/ (e.g. pages/_helper.twig)
        next if rel_inside_pages.split("/").any? { |seg| seg.start_with?("_") }
        url_path = rel_inside_pages.sub(/\.(twig|html)$/, "")
        rel_from_templates = "pages/#{rel_inside_pages}"
        cache[url_path] ||= rel_from_templates
      end
      cache
    end

    def try_serve_index_template
      templates_dir = File.join(@root_dir, "src", "templates")
      %w[index.html index.twig index.erb].each do |f|
        path = File.join(templates_dir, f)
        if File.file?(path)
          body = Tina4::Template.render(f, {}) rescue File.read(path)
          return [200, { "content-type" => "text/html" }, [body]]
        end
      end
      nil
    end

    def render_landing_page
      port = ENV["PORT"] || "7145"

      # Check deployed state for each gallery item
      project_src = File.join(@root_dir, "src")
      gallery_items = [
        { id: "rest-api", name: "REST API", desc: "A simple JSON API with GET and POST endpoints", icon: "&#128640;", accent: "red", try_url: "/api/gallery/hello", file_check: "routes/api/gallery_hello.rb" },
        { id: "orm", name: "ORM", desc: "Product model with CRUD endpoints", icon: "&#128451;", accent: "green", try_url: "/api/gallery/products", file_check: "routes/api/gallery_products.rb" },
        { id: "auth", name: "Auth", desc: "JWT login form with token display", icon: "&#128274;", accent: "purple", try_url: "/gallery/auth", file_check: "routes/api/gallery_auth.rb" },
        { id: "queue", name: "Queue", desc: "Background job producer and consumer", icon: "&#9889;", accent: "red", try_url: "/api/gallery/queue/produce", file_check: "routes/api/gallery_queue.rb" },
        { id: "templates", name: "Templates", desc: "Twig template with dynamic data", icon: "&#128196;", accent: "green", try_url: "/gallery/page", file_check: "routes/gallery_page.rb" },
        { id: "database", name: "Database", desc: "Raw SQL queries with the Database class", icon: "&#128225;", accent: "purple", try_url: "/api/gallery/db/tables", file_check: "routes/api/gallery_db.rb" },
        { id: "error-overlay", name: "Error Overlay", desc: "See the rich debug error page with stack trace", icon: "&#128165;", accent: "red", try_url: "/api/gallery/crash", file_check: "routes/api/gallery_crash.rb" }
      ]

      gallery_cards = gallery_items.map do |item|
        deployed = File.file?(File.join(project_src, item[:file_check]))
        deployed_badge = deployed ? '<span style="position:absolute;top:0.75rem;right:0.75rem;background:#22c55e;color:#fff;font-size:0.65rem;padding:0.15rem 0.5rem;border-radius:0.25rem;font-weight:600;">DEPLOYED</span>' : ''
        try_btn = if deployed
                    %(<a href="#{item[:try_url]}" class="gbtn gbtn-try" target="_blank">Try It</a>)
                  else
                    %(<button class="gbtn gbtn-deploy" onclick="deployGallery('#{item[:id]}','#{item[:try_url]}')">Deploy &amp; Try</button>)
                  end
        view_btn = %(<button class="gbtn gbtn-view" onclick="viewGallery('#{item[:id]}')">View</button>)

        <<~CARD
          <div class="gallery-card">
              <div class="accent accent-#{item[:accent]}"></div>
              #{deployed_badge}
              <div class="icon">#{item[:icon]}</div>
              <h3>#{item[:name]}</h3>
              <p>#{item[:desc]}</p>
              <div style="display:flex;gap:0.5rem;margin-top:0.75rem;">#{try_btn}#{view_btn}</div>
          </div>
        CARD
      end.join

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Tina4Ruby</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh;display:flex;flex-direction:column;align-items:center;position:relative}
        .bg-watermark{position:fixed;bottom:-5%;right:-5%;width:45%;opacity:0.04;pointer-events:none;z-index:0}
        .hero{text-align:center;z-index:1;padding:3rem 2rem 2rem}
        .logo{width:120px;height:120px;margin-bottom:1.5rem}
        h1{font-size:3rem;font-weight:700;margin-bottom:0.25rem;letter-spacing:-1px}
        .tagline{color:#64748b;font-size:1.1rem;margin-bottom:2rem}
        .actions{display:flex;gap:0.75rem;justify-content:center;flex-wrap:wrap;margin-bottom:2.5rem}
        .btn{padding:0.6rem 1.5rem;border-radius:0.5rem;font-size:0.9rem;font-weight:600;cursor:pointer;text-decoration:none;transition:all 0.15s;border:1px solid #334155;color:#94a3b8;background:transparent;min-width:140px;text-align:center;display:inline-block}
        .btn:hover{border-color:#64748b;color:#e2e8f0}
        .status{display:flex;gap:2rem;justify-content:center;align-items:center;color:#64748b;font-size:0.85rem;margin-bottom:1.5rem}
        .status .dot{width:8px;height:8px;border-radius:50%;background:#22c55e;display:inline-block;margin-right:0.4rem}
        .footer{color:#334155;font-size:0.8rem;letter-spacing:0.5px}
        .section{z-index:1;width:100%;max-width:800px;padding:0 2rem;margin-bottom:2.5rem}
        .card{background:#1e293b;border-radius:0.75rem;padding:2rem;border:1px solid #334155}
        .card h2{font-size:1.4rem;font-weight:600;margin-bottom:1.25rem;color:#e2e8f0}
        .code-block{background:#0f172a;border-radius:0.5rem;padding:1.25rem;overflow-x:auto;font-family:'SF Mono',SFMono-Regular,Consolas,'Liberation Mono',Menlo,monospace;font-size:0.85rem;line-height:1.6;color:#4ade80;border:1px solid #1e293b}
        .gallery{z-index:1;width:100%;max-width:900px;padding:0 2rem;margin-bottom:3rem}
        .gallery h2{font-size:1.4rem;font-weight:600;margin-bottom:1.25rem;color:#e2e8f0;text-align:center}
        .gallery-card{background:#1e293b;border:1px solid #334155;border-radius:0.75rem;padding:1.5rem;position:relative;overflow:hidden}
        .gallery-card .accent{position:absolute;top:0;left:0;right:0;height:3px}
        .gallery-card .accent-red{background:#CC342D}
        .gallery-card .accent-green{background:#22c55e}
        .gallery-card .accent-purple{background:#a78bfa}
        .gallery-card .icon{font-size:1.5rem;margin-bottom:0.75rem}
        .gallery-card h3{font-size:1rem;font-weight:600;margin-bottom:0.5rem;color:#e2e8f0}
        .gallery-card p{font-size:0.85rem;color:#94a3b8;line-height:1.5}
        .gbtn{padding:0.35rem 0.75rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer;text-decoration:none;border:none;transition:all 0.15s}
        .gbtn-try{background:#22c55e;color:#fff}
        .gbtn-try:hover{background:#16a34a}
        .gbtn-deploy{background:#CC342D;color:#fff}
        .gbtn-deploy:hover{background:#a12a24}
        .gbtn-view{background:transparent;color:#94a3b8;border:1px solid #334155}
        .gbtn-view:hover{border-color:#64748b;color:#e2e8f0}
        .view-modal{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.7);z-index:10000;align-items:center;justify-content:center}
        .view-modal.active{display:flex}
        .view-modal-content{background:#1e293b;border:1px solid #334155;border-radius:0.75rem;padding:2rem;max-width:700px;width:90%;max-height:80vh;overflow-y:auto;position:relative}
        .view-modal-close{position:absolute;top:0.75rem;right:1rem;color:#94a3b8;cursor:pointer;font-size:1.25rem;background:none;border:none}
        .view-modal-close:hover{color:#e2e8f0}
        @keyframes wiggle{0%{transform:rotate(0deg)}15%{transform:rotate(14deg)}30%{transform:rotate(-10deg)}45%{transform:rotate(8deg)}60%{transform:rotate(-4deg)}75%{transform:rotate(2deg)}100%{transform:rotate(0deg)}}
        .star-wiggle{display:inline-block;transform-origin:center}
        </style>
        </head>
        <body>
        <img src="/images/tina4-logo-icon.webp" class="bg-watermark" alt="">
        <div class="hero">
            <img src="/images/tina4-logo-icon.webp" class="logo" alt="Tina4">
            <h1>Tina4Ruby</h1>
            <p class="tagline">The Intelligent Native Application 4ramework</p>
            <p class="tagline" style="font-size:0.95rem;margin-top:-1rem">Simple. Fast. Human. &nbsp;|&nbsp; Built for AI. Built for you.</p>
            <div class="actions">
                <a href="https://tina4.com/ruby" class="btn" target="_blank">Website</a>
                <a href="/__dev" class="btn">Dev Admin</a>
                <a href="#gallery" class="btn">Gallery</a>
                <a href="https://github.com/tina4stack/tina4-ruby" class="btn" target="_blank">GitHub</a>
                <a href="https://github.com/tina4stack/tina4-ruby/stargazers" class="btn" target="_blank"><span class="star-wiggle">&#9734;</span> Star</a>
            </div>
            <div class="status">
                <span><span class="dot"></span>Server running</span>
                <span>Port #{port}</span>
                <span>v#{Tina4::VERSION}</span>
            </div>
            <p class="footer">Zero dependencies &middot; Convention over configuration</p>
        </div>
        <div class="section">
            <div class="card">
                <h2>Getting Started</h2>
                <pre class="code-block"><code><span style="color:#64748b"># app.rb</span>
        <span style="color:#c084fc">require</span> <span style="color:#4ade80">"tina4"</span>

        Tina4::Router.<span style="color:#38bdf8">get</span>(<span style="color:#4ade80">"/hello"</span>) <span style="color:#c084fc">do</span> |request, response|
          response.<span style="color:#38bdf8">json</span>({ <span style="color:#fbbf24">message:</span> <span style="color:#4ade80">"Hello World!"</span> })
        <span style="color:#c084fc">end</span>

        Tina4::WebServer.new(<span style="color:#fbbf24">port:</span> <span style="color:#38bdf8">7145</span>).start  <span style="color:#64748b"># starts on port 7145</span></code></pre>
            </div>
        </div>
        <div class="gallery">
            <h2 id="gallery">Gallery</h2>
            <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1rem;">
                #{gallery_cards}
            </div>
        </div>
        <div class="view-modal" id="viewModal">
            <div class="view-modal-content">
                <button class="view-modal-close" onclick="document.getElementById('viewModal').classList.remove('active')">&times;</button>
                <h3 id="viewModalTitle" style="margin-bottom:1rem;color:#e2e8f0;"></h3>
                <div id="viewModalBody"></div>
            </div>
        </div>
        <script>
        function deployGallery(name, tryUrl) {
            if (!confirm('Deploy the "' + name + '" gallery example into your project?')) return;
            var btn = event.target;
            btn.disabled = true;
            btn.textContent = 'Deploying...';
            fetch('/__dev/api/gallery/deploy', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ name: name })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.error) {
                    alert('Deploy failed: ' + d.error);
                    btn.disabled = false;
                    btn.textContent = 'Deploy & Try';
                } else {
                    // Wait for the newly deployed route to become reachable before navigating
                    var attempts = 0;
                    var maxAttempts = 5;
                    function pollRoute() {
                        fetch(tryUrl, {method: 'HEAD'}).then(function() {
                            window.open(tryUrl, '_blank');
                        }).catch(function() {
                            attempts++;
                            if (attempts < maxAttempts) {
                                setTimeout(pollRoute, 500);
                            } else {
                                window.open(tryUrl, '_blank');
                            }
                        });
                    }
                    setTimeout(pollRoute, 500);
                }
            }).catch(function(e) {
                alert('Deploy error: ' + e.message);
                btn.disabled = false;
                btn.textContent = 'Deploy & Try';
            });
        }
        function viewGallery(name) {
            fetch('/__dev/api/gallery').then(function(r) { return r.json(); }).then(function(d) {
                var item = (d.gallery || []).find(function(g) { return g.id === name; });
                if (!item) { alert('Gallery item not found'); return; }
                var title = document.getElementById('viewModalTitle');
                var body = document.getElementById('viewModalBody');
                title.textContent = item.name + ' — ' + item.description;
                var html = '<p style="color:#94a3b8;margin-bottom:1rem;">Files that will be deployed:</p><ul style="list-style:none;padding:0;">';
                (item.files || []).forEach(function(f) {
                    html += '<li style="padding:0.25rem 0;color:#4ade80;font-family:monospace;font-size:0.85rem;">src/' + f + '</li>';
                });
                html += '</ul>';
                if (item.try_url) {
                    html += '<p style="color:#94a3b8;margin-top:1rem;">Try URL: <code style="color:#38bdf8;">' + item.try_url + '</code></p>';
                }
                body.innerHTML = html;
                document.getElementById('viewModal').classList.add('active');
            });
        }
        document.getElementById('viewModal').addEventListener('click', function(e) {
            if (e.target === this) this.classList.remove('active');
        });
        (function(){
            var star=document.querySelector('.star-wiggle');
            if(!star)return;
            function doWiggle(){
                star.style.animation='wiggle 1.2s ease-in-out';
                star.addEventListener('animationend',function onEnd(){
                    star.removeEventListener('animationend',onEnd);
                    star.style.animation='none';
                    var delay=3000+Math.random()*15000;
                    setTimeout(doWiggle,delay);
                });
            }
            setTimeout(doWiggle,3000);
        })();
        </script>
        </body>
        </html>
      HTML

      [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
    end

    def handle_500(error, env = nil)
      Tina4::Log.error("500 Internal Server Error: #{error.message}")
      Tina4::Log.error(error.backtrace&.first(10)&.join("\n"))

      # v3.13.7: surface route failures to observability (centralised
      # logging, APM, Sentry) BEFORE rendering the 500. Listeners get
      # the canonical {exception:, request:} pair — same shape as
      # Python / PHP / Node. Listener exceptions are swallowed +
      # warning-logged so a broken listener can't break the 500 page.
      begin
        request = env && env["tina4.request"]
        Tina4::Events.emit("tina4.request.error", {
          exception: error,
          request:   request
        })
      rescue StandardError => listener_err
        begin
          Tina4::Log.warning(
            "Listener for tina4.request.error raised: " \
            "#{listener_err.class}: #{listener_err.message}"
          )
        rescue StandardError
          # Log failures must never block the 500 render.
        end
      end

      if dev_mode?
        # Rich error overlay with stack trace, source context, and line numbers
        body = Tina4::ErrorOverlay.render_error_overlay(error, request: env)
      else
        # v3.13.7 SECURITY (CWE-209): production response body must NOT
        # contain the stack trace. The trace stays in Log.error above
        # and reaches observability via the tina4.request.error event.
        body = Tina4::Template.render_error(500, {
          "error_message" => "",
          "request_id" => SecureRandom.hex(6)
        }) rescue "500 Internal Server Error"
      end
      [500, { "content-type" => "text/html" }, [body]]
    end

    def dev_mode?
      Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])
    end

    # Whether to emit a per-request log line (v3.13.14). TINA4_LOG_REQUESTS
    # is the explicit control (true/false); when unset, request logging
    # follows dev mode (on under TINA4_DEBUG, off in production). Same
    # contract across all four frameworks.
    def request_logging_enabled?
      val = ENV["TINA4_LOG_REQUESTS"]
      return Tina4::Env.is_truthy(val) if val && !val.empty?

      dev_mode?
    end

    def websocket_upgrade?(env)
      upgrade = env["HTTP_UPGRADE"] || ""
      upgrade.downcase == "websocket"
    end

    def handle_websocket_upgrade(env, ws_route, ws_params)
      # Rack hijack is required for WebSocket upgrades
      unless env["rack.hijack"]
        Tina4::Log.warning("WebSocket upgrade requested but rack.hijack not available")
        return [426, { "content-type" => "text/plain" }, ["WebSocket upgrade requires rack.hijack support"]]
      end

      env["rack.hijack"].call
      socket = env["rack.hijack_io"]

      # Wire the route handler into the WebSocket engine events
      handler = ws_route.handler

      # Create a dedicated WebSocket *event* engine for this route so each
      # upgrade keeps its own isolated open/message/close handlers (the engine's
      # on() appends handlers, so a single shared event engine would cross-wire
      # routes).
      ws = Tina4::WebSocket.new

      # The connection itself is OWNED by a process-wide shared manager so that
      # broadcasts, rooms, the multi-instance backplane and the idle reaper span
      # every route's connections — not just this one per-socket event engine.
      # Mirrors Python's single WebSocketManager. The dev-reload channel uses its
      # own shared manager (Tina4::DevReload) so POST /__dev/api/reload reaches
      # every browser.
      dev_reload = ws_route.path == "/__dev_reload"
      manager = dev_reload ? Tina4::DevReload.manager : @websocket_engine

      ws.on(:open) do |connection|
        connection.params = ws_params
        handler.call(connection, :open, nil)
      end

      ws.on(:message) do |connection, data|
        handler.call(connection, :message, data)
      end

      ws.on(:close) do |connection|
        handler.call(connection, :close, nil)
      end

      ws.on(:error) do |connection, error|
        Tina4::Log.error("WebSocket error on #{ws_route.path}: #{error.message}")
      end

      # Per-route auth on the upgrade: a secured WS route (auth_required) needs a
      # valid JWT or the handshake is rejected (401, not accepted) by
      # handle_upgrade — after the origin allow-list, before the handshake. The
      # dev-reload channel is always public.
      auth_required = !dev_reload && ws_route.respond_to?(:auth_required) && ws_route.auth_required
      ws.handle_upgrade(env, socket, manager: manager, auth_required: auth_required)

      # Return async response (-1 signals Rack the response is handled via hijack)
      [-1, {}, []]
    end

    def inject_dev_overlay(body, request_info, ai_port: false)
      version = Tina4::VERSION
      method = request_info[:method]
      path = request_info[:path]
      matched_pattern = request_info[:matched_pattern]
      request_id = Tina4::Log.get_request_id || "-"
      route_count = Tina4::Router.routes.length

      ai_badge = ai_port ? '<span style="background:#7c3aed;color:#fff;font-size:10px;padding:1px 6px;border-radius:3px;font-weight:bold;">AI PORT</span>' : ""

      toolbar = <<~HTML.strip
        <div id="tina4-dev-toolbar" style="position:fixed;bottom:0;left:0;right:0;background:#333;color:#fff;font-family:monospace;font-size:12px;padding:6px 16px;z-index:99999;display:flex;align-items:center;gap:16px;">
            #{ai_badge}<span id="tina4-ver-btn" style="color:#d32f2f;font-weight:bold;cursor:pointer;text-decoration:underline dotted;" onclick="tina4VersionModal()" title="Click to check for updates">Tina4 v#{version}</span>
            <div id="tina4-ver-modal" style="display:none;position:fixed;bottom:3rem;left:1rem;background:#1e1e2e;border:1px solid #d32f2f;border-radius:8px;padding:16px 20px;z-index:100000;min-width:320px;box-shadow:0 8px 32px rgba(0,0,0,0.5);font-family:monospace;font-size:13px;color:#cdd6f4;">
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;">
                <strong style="color:#89b4fa;">Version Info</strong>
                <span onclick="document.getElementById('tina4-ver-modal').style.display='none'" style="cursor:pointer;color:#888;">&times;</span>
              </div>
              <div id="tina4-ver-body" style="line-height:1.8;">
                <div>Current: <strong style="color:#a6e3a1;">v#{version}</strong></div>
                <div id="tina4-ver-latest" style="color:#888;">Checking for updates...</div>
              </div>
            </div>
            <span style="color:#4caf50;">#{method}</span>
            <span>#{path}</span>
            <span style="color:#666;">&rarr; #{matched_pattern}</span>
            <span style="color:#ffeb3b;">req:#{request_id}</span>
            <span style="color:#90caf9;">#{route_count} routes</span>
            <span style="color:#888;">Ruby #{RUBY_VERSION}</span>
            <a href="#" onclick="window.__tina4ToggleOverlay(event)" style="color:#ef9a9a;margin-left:auto;text-decoration:none;cursor:pointer;">Dashboard &#8599;</a>
            <span onclick="this.parentElement.style.display='none'" style="cursor:pointer;color:#888;margin-left:8px;">&#10005;</span>
        </div>
        <script>
        // Overlay open/toggle helper + auto-restore. Persist the dev-admin
        // iframe's open/closed state across parent reloads so saving a
        // file doesn't lose the user's dev-admin context. Cross-framework
        // parity with PHP / Python / Node — same localStorage key.
        (function(){
            var STATE_KEY = 'tina4_dev_overlay_open';
            function buildOverlay() {
                var c = document.createElement('div');
                c.id = 'tina4-dev-panel';
                c.style.cssText = 'position:fixed;top:3rem;left:0;right:0;bottom:2rem;z-index:99998;transition:all 0.2s';
                var f = document.createElement('iframe');
                f.src = '/__dev';
                f.style.cssText = 'width:100%;height:100%;border:1px solid #CC342D;border-radius:0.5rem;box-shadow:0 8px 32px rgba(0,0,0,0.5);background:#0f172a';
                c.appendChild(f);
                document.body.appendChild(c);
                return c;
            }
            window.__tina4ToggleOverlay = function(e) {
                if (e) e.preventDefault();
                var p = document.getElementById('tina4-dev-panel');
                if (p) {
                    var hide = p.style.display !== 'none';
                    p.style.display = hide ? 'none' : 'block';
                    try { localStorage.setItem(STATE_KEY, hide ? '0' : '1'); } catch (_) {}
                    return;
                }
                buildOverlay();
                try { localStorage.setItem(STATE_KEY, '1'); } catch (_) {}
            };
            function restoreIfOpen() {
                try {
                    if (location.pathname.indexOf('/__dev') === 0) return;
                    if (localStorage.getItem(STATE_KEY) === '1' && !document.getElementById('tina4-dev-panel')) {
                        buildOverlay();
                    }
                } catch (_) {}
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', restoreIfOpen);
            } else {
                restoreIfOpen();
            }
        })();
        </script>
        <script>
        function tina4VersionModal(){
            var m=document.getElementById('tina4-ver-modal');
            if(m.style.display==='block'){m.style.display='none';return;}
            m.style.display='block';
            var el=document.getElementById('tina4-ver-latest');
            el.innerHTML='Checking for updates...';
            el.style.color='#888';
            fetch('/__dev/api/version-check')
            .then(function(r){return r.json()})
            .then(function(d){
                var latest=d.latest;
                var current=d.current;
                if(latest===current){
                    el.innerHTML='Latest: <strong style="color:#a6e3a1;">v'+latest+'</strong> &mdash; You are up to date!';
                    el.style.color='#a6e3a1';
                }else{
                    var cParts=current.split('.').map(Number);
                    var lParts=latest.split('.').map(Number);
                    var isNewer=false;
                    for(var i=0;i<Math.max(cParts.length,lParts.length);i++){
                        var c=cParts[i]||0,l=lParts[i]||0;
                        if(l>c){isNewer=true;break;}
                        if(l<c)break;
                    }
                    var isAhead=false;
                    if(!isNewer){for(var i=0;i<Math.max(cParts.length,lParts.length);i++){var c2=cParts[i]||0,l2=lParts[i]||0;if(c2>l2){isAhead=true;break;}if(c2<l2)break;}}
                    if(isNewer){
                        var breaking=(lParts[0]!==cParts[0]||lParts[1]!==cParts[1]);
                        el.innerHTML='Latest: <strong style="color:#f9e2af;">v'+latest+'</strong>';
                        if(breaking){
                            el.innerHTML+='<div style="color:#f38ba8;margin-top:6px;">&#9888; Major/minor version change &mdash; check the <a href="https://github.com/tina4stack/tina4-ruby/releases" target="_blank" style="color:#89b4fa;">changelog</a> for breaking changes before upgrading.</div>';
                        }else{
                            el.innerHTML+='<div style="color:#f9e2af;margin-top:6px;">Patch update available. Run: <code style="background:#313244;padding:2px 6px;border-radius:3px;">gem install tina4ruby</code></div>';
                        }
                    }else if(isAhead){
                        el.innerHTML='You are running <strong style="color:#cba6f7;">v'+current+'</strong> (ahead of RubyGems <strong>v'+latest+'</strong> &mdash; not yet published).';
                        el.style.color='#cba6f7';
                    }else{
                        el.innerHTML='Latest: <strong style="color:#a6e3a1;">v'+latest+'</strong> &mdash; You are up to date!';
                        el.style.color='#a6e3a1';
                    }
                }
            })
            .catch(function(){
                el.innerHTML='Could not check for updates (offline?)';
                el.style.color='#f38ba8';
            });
        }
        #{ai_port ? "" : dev_reload_client_js}
        </script>
      HTML

      if body.include?("</body>")
        body.sub("</body>", "#{toolbar}\n</body>")
      else
        body + "\n" + toolbar
      end
    end

    # WebSocket-primary dev reloader injected into HTML pages in debug mode.
    #
    # The running server re-imports changed src/ route files in-process and
    # pushes a {type,file,mtime} message over /__dev_reload — no respawn,
    # instant refresh. The mtime poll is a FALLBACK only: it is started when
    # the socket is down and stopped the moment it connects. On a CSS change
    # the client swaps <link rel=stylesheet> hrefs with a cache-bust query;
    # any other change does a full location.reload(). The poll seeds its
    # last-seen mtime to a null sentinel (NOT 0) and reloads whenever the
    # polled mtime DIFFERS (not just when greater) so the first change after
    # load isn't swallowed and a counter reset on restart still triggers.
    # Mirrors the Python master's injected client exactly.
    def dev_reload_client_js
      poll_interval_ms = (ENV["TINA4_DEV_POLL_INTERVAL"] || "3000").to_i
      poll_interval_ms = 3000 if poll_interval_ms <= 0
      <<~JS
        (function(){
            var _t4_css_exts=['.css','.scss'],_t4_debounce=null;
            var _t4_interval=parseInt('#{poll_interval_ms}')||3000;
            var _t4_ws=null,_t4_poll_timer=null,_t4_mtime=null;
            function _t4_apply(d){
                d=d||{};
                var f=d.file||'',t=d.type||'';
                var isCss=t==='css'||_t4_css_exts.some(function(e){return f.endsWith(e)});
                if(isCss){
                    var links=document.querySelectorAll('link[rel="stylesheet"]');
                    links.forEach(function(l){
                        var href=l.getAttribute('href');
                        if(href){l.setAttribute('href',href.split('?')[0]+'?_t4='+(d.mtime||Date.now()))}
                    });
                }else{
                    location.reload();
                }
            }
            function _t4_poll(){
                fetch('/__dev/api/mtime').then(function(r){return r.json()}).then(function(d){
                    if(_t4_mtime===null){_t4_mtime=d.mtime;return;}
                    if(d.mtime!==_t4_mtime){
                        _t4_mtime=d.mtime;
                        if(_t4_debounce)clearTimeout(_t4_debounce);
                        _t4_debounce=setTimeout(function(){_t4_apply(d);},500);
                    }
                }).catch(function(){});
            }
            function _t4_startPoll(){
                if(_t4_poll_timer)return;
                _t4_mtime=null;
                _t4_poll_timer=setInterval(_t4_poll,_t4_interval);
            }
            function _t4_stopPoll(){
                if(_t4_poll_timer){clearInterval(_t4_poll_timer);_t4_poll_timer=null;}
            }
            function _t4_connect(){
                var url=(location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/__dev_reload';
                try{_t4_ws=new WebSocket(url);}catch(_){_t4_startPoll();return;}
                _t4_ws.addEventListener('open',function(){_t4_stopPoll();});
                _t4_ws.addEventListener('message',function(ev){
                    var d=null;
                    try{d=typeof ev.data==='string'?JSON.parse(ev.data):null;}catch(_){}
                    if(!d)return;
                    if(d.type==='reload'||d.type==='change'||d.type==='css'){
                        if(_t4_debounce)clearTimeout(_t4_debounce);
                        _t4_debounce=setTimeout(function(){_t4_apply(d);},150);
                    }
                });
                _t4_ws.addEventListener('close',function(){_t4_ws=null;_t4_startPoll();setTimeout(_t4_connect,2000);});
                _t4_ws.addEventListener('error',function(){try{_t4_ws&&_t4_ws.close();}catch(_){}});
            }
            _t4_connect();
        })();
      JS
    end


    # Read and rewind the Rack input body. Returns the raw body string.
    # Enforce the secure-by-default write-route auth gate.
    #
    # Returns nil when the route is public OR a valid token is present (and, as a
    # side effect, sets env["tina4.auth_payload"] and, for a body formToken,
    # env["tina4.fresh_token"]). Returns a Rack 401 tuple when an auth-required
    # route has no valid token.
    #
    # A CLASS method on purpose: both the live RackApp#handle_route and the
    # in-process TestClient call it, so the test surface enforces the identical
    # gate as production (Python #PY2 parity). Instantiating a RackApp just to
    # reach the check would run full boot/route-discovery — this needs none of it.
    def self.enforce_route_auth(env, route)
      return nil unless route.auth_required

      token = nil
      token_source = nil  # :header, :body, :session

      # Priority 1: Authorization Bearer header
      auth_header = env["HTTP_AUTHORIZATION"] || ""
      if auth_header =~ /\ABearer\s+(.+)\z/i
        token = Regexp.last_match(1)
        token_source = :header
      end

      # Priority 2: formToken from request body (for frond.js saveForm with {{ form_token() }})
      if token.nil?
        body_str = _read_rack_body(env)
        form_token = _extract_form_token(body_str, env)
        if form_token && !form_token.empty?
          token = form_token
          token_source = :body
        end
      end

      # Priority 3: Session token (for secured GET routes after login)
      if token.nil?
        session = Tina4::Session.new(env)
        session_token = session.get("token")
        if session_token && !session_token.empty?
          token = session_token
          token_source = :session
        end
      end

      # API_KEY bypass — matches tina4_python behavior
      api_key = ENV["TINA4_API_KEY"]
      if api_key && !api_key.empty? && token == api_key
        env["tina4.auth_payload"] = { "api_key" => true }
      elsif token
        unless Tina4::Auth.valid_token(token)
          return [401, { "content-type" => "application/json" }, [JSON.generate({ error: "Unauthorized" })]]
        end
        env["tina4.auth_payload"] = Tina4::Auth.get_payload(token)

        # When body formToken validates, store a refreshed token for the FreshToken response header
        env["tina4.fresh_token"] = Tina4::Auth.refresh_token(token) if token_source == :body
      else
        return [401, { "content-type" => "application/json" }, [JSON.generate({ error: "Unauthorized" })]]
      end

      nil
    end

    def self._read_rack_body(env)
      input = env["rack.input"]
      return "" unless input
      input.rewind if input.respond_to?(:rewind)
      body = input.read || ""
      input.rewind if input.respond_to?(:rewind)
      body
    end

    # Extract a formToken from the request body.
    # Supports JSON body ({ "formToken": "..." }) and URL-encoded form data (formToken=...).
    def self._extract_form_token(body_str, env)
      return nil if body_str.nil? || body_str.empty?

      content_type = env["CONTENT_TYPE"] || env["HTTP_CONTENT_TYPE"] || ""

      if content_type.include?("application/json")
        begin
          parsed = JSON.parse(body_str)
          return parsed["formToken"] if parsed.is_a?(Hash) && parsed["formToken"]
        rescue JSON::ParserError
          # Not valid JSON — fall through
        end
      end

      # URL-encoded form data (or fallback for any content type)
      if body_str.include?("formToken=")
        match = body_str.match(/(?:^|&)formToken=([^&]+)/)
        return URI.decode_www_form_component(match[1]) if match
      end

      nil
    end

  end
end
