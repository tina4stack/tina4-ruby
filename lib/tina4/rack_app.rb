# frozen_string_literal: true
require "json"
require "securerandom"
require "time"
require "uri"
require "cgi"

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
    include Tina4::DispatchPipeline

    class << self
      # The process-wide RackApp — the app actually serving traffic. Set by
      # #initialize (last one wins, the same convention as
      # Tina4::WebSocket.current). Tina4::TestClient defaults to this so an
      # in-process test request runs through the SAME app object a live request
      # does, instead of building a second one with a different static root and
      # clobbering the shared WebSocket engine. (feature-recount D6)
      attr_accessor :current
    end

    # ONE static search set + order across the four frameworks
    # (ST-SEARCHDIR-DIVERGE): the app's public then src/public. TINA4_PUBLIC_DIR
    # is prepended per-request in #try_static, and the framework's bundled public
    # dir is appended as the fallback in #initialize.
    STATIC_DIRS = %w[public src/public].freeze

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

    # Rack entry point. Establishes the per-request correlation id (feature 43),
    # runs the dispatch pipeline, and echoes the id on the response.
    def call(env)
      # Honour a sanitized inbound X-Request-ID so a client or upstream service
      # can thread its own id through - a CR/LF, over-long or illegal-charset
      # value is rejected (never echoed) - else generate one. Thread it into the
      # logger NOW (thread-local, so a Puma worker thread never sees another
      # request's id), so every log line for this request carries it, and echo it
      # on the response whatever outcome the pipeline produced (200/404/500/413).
      request_id = Tina4::Log.sanitize_request_id(env["HTTP_X_REQUEST_ID"]) || SecureRandom.hex(4)
      Tina4::Log.set_request_id(request_id)

      result = dispatch_pipeline(env)
      result[1]["x-request-id"] = request_id if result.is_a?(Array) && result[1].is_a?(Hash)
      result
    end

    # Run the dispatch pipeline. See REQUEST_STAGES / RESPONSE_STAGES above.
    #
    # Every branch this used to hold now lives in a named stage, so the only
    # control flow left here is "walk the list, stop when a stage answers".
    def dispatch_pipeline(env)
      ctx = DispatchContext.new(
        env: env,
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"] || "/",
        started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        bypass_response_stages: false
      )

      response = nil
      REQUEST_STAGES.each do |stage|
        response = send(stage, ctx)
        break if response
      end

      unless ctx.bypass_response_stages
        RESPONSE_STAGES.each do |stage|
          replacement = send(stage, ctx, response)
          response = replacement if replacement
        end
      end

      # LAST, and unconditionally. RFC 9110 s9.3.2 applies to EVERY response
      # however it was produced - the swagger and static branches that skip the
      # stages above, AND anything those stages added.
      #
      # Running it FIRST was wrong twice over: the static branches skipped it
      # (the bug this group was created to fix), and in dev mode
      # dev_toolbar_inject then put 8.5KB of markup back into an
      # already-stripped HEAD response. CI caught the second one because it
      # sets TINA4_DEBUG; a local run without it did not.
      #
      # Running it last also makes Content-Length right: it reports the body
      # AFTER injection, which is exactly what the equivalent GET would send
      # (s9.3.2 SHOULD - same headers as the GET).
      ALWAYS_STAGES.each do |stage|
        replacement = send(stage, ctx, response)
        response = replacement if replacement
      end

      response
    rescue Tina4::Request::PayloadTooLarge => e
      # 413, not 500. PayloadTooLarge was raised by Request and rescued by
      # nobody, so it fell into the generic handler below and an oversized
      # upload answered "Internal Server Error" - which tells the caller to
      # retry the exact request that will fail again.
      #
      # Measured on Puma with a 1MB TINA4_MAX_UPLOAD_SIZE and an 8MB body:
      # HTTP 500, and the same for a chunked body. Memory stayed flat (Puma
      # bounds the read), so unlike Node and Python this was only ever the
      # status code - but the status code is what a client acts on.
      body = JSON.generate({ "error" => e.message })
      [413, { "content-type" => "application/json",
              "content-length" => body.bytesize.to_s }, [body]]
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

    # Order: POST-MATCH globals -> auth gate -> the route's OWN middleware.
    #
    # The globals run BEFORE the gate so a rate limiter can throttle a
    # brute-force login and an access log records the 401 - neither is possible
    # if they only run on authenticated requests. That is what every mainstream
    # framework does: Django ships CsrfViewMiddleware ahead of
    # AuthenticationMiddleware and enforces auth in a view decorator after all
    # MIDDLEWARE, Laravel runs the `web` group before the `auth` route
    # middleware, ASP.NET puts UseAuthorization last before the endpoint. Ruby
    # and Python ran the gate first; Node and PHP did not. Aligned on the
    # mainstream answer (ADR-0012).
    #
    # The route's OWN middleware stays AFTER the gate, so middleware attached to
    # a secured route never processes an unauthenticated request.
    # Run a matched route. See ROUTE_STAGES in DispatchPipeline.
    #
    # Was cyclomatic complexity 24 in one 118-line function; the same two-phase
    # shape as #call, so it gets the same treatment - short-circuit stages
    # first, then invoke and finalise.
    def handle_route(env, route, path_params, pre_request = nil, pre_response = nil)
      ctx = RouteContext.new(
        env: env, route: route, path_params: path_params,
        pre_request: pre_request, pre_response: pre_response
      )

      ROUTE_STAGES.each do |stage|
        short_circuit = send(stage, ctx)
        return short_circuit if short_circuit
      end

      finalise_route_response(ctx, invoke_route_handler(ctx))
    end

    def try_static(path, env = nil)
      return nil if path.include?("..")

      # Security: never serve a dotfile (.env, .git/config, .htpasswd, ...).
      # Reject any leading-dot segment in the REQUEST path before touching the
      # filesystem; #confined_static_file re-checks the RESOLVED path so a symlink
      # pointing AT a dotfile inside the public dir is refused too.
      return nil if hidden_segment?(path)

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

      # TINA4_PUBLIC_DIR override is honoured first (ST-PUBLICDIR-ENV-PARTIAL),
      # then the pre-computed project + framework roots.
      roots = @static_roots
      custom = ENV["TINA4_PUBLIC_DIR"]
      roots = [custom] + roots if custom && !custom.empty?

      roots.each do |root|
        served = confined_static_file(root, path, env)
        return served if served

        # Only try index.html for directory-like paths
        if path.end_with?("/") || !path.include?(".")
          served = confined_static_file(root, File.join(path, "index.html"), env)
          return served if served
        end
      end
      nil
    end

    # Serve a file under `root` ONLY when its REAL path stays confined under the
    # real `root` (realpath + trailing separator, ADR-0050) and names no dotfile
    # segment. File.realpath follows symlinks and collapses `..`, so a symlink
    # pointing outside, a sibling-prefix dir (publicsecret) and a `..` escape all
    # fail the containment a bare string check would miss. Returns the Rack
    # response triple, or nil when the file is absent, escapes, or is hidden.
    def confined_static_file(root, rel_path, env)
      real_dir = File.realpath(root)
      real_path = File.realpath(File.join(root, rel_path))
      return nil unless File.file?(real_path)
      return nil unless real_path.start_with?(real_dir + File::SEPARATOR)

      relative = real_path[(real_dir.length + 1)..] || ""
      return nil if hidden_segment?(relative)

      serve_static_file(real_path, env)
    rescue SystemCallError
      # realpath raises when a path component is missing — a plain 404, not an error.
      nil
    end

    # Whether any separator-delimited segment of `path` is hidden (begins with a
    # dot). Refuses `.env`/`.git`; a `..` segment also begins with a dot.
    def hidden_segment?(path)
      path.split(File::SEPARATOR).any? { |segment| !segment.empty? && segment.start_with?(".") }
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
      # DEVADMIN-DEC-04 (feature 127): the error page reflects the request path
      # into HTML and the Twig error template does NOT auto-escape, so a crafted
      # /x<script> path would run script in the response origin. Escape it here
      # (same reflected-request-path XSS class as the dev-toolbar fix).
      body = Tina4::Template.render_error(404, { "path" => CGI.escapeHTML(path.to_s) }) rescue "404 Not Found"
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

      # v3.13.7 SECURITY (CWE-209): production response body must NOT contain the
      # stack trace. The trace stays in Log.error above and reaches observability
      # via the tina4.request.error event.
      safe_page = lambda do
        Tina4::Template.render_error(500, {
          "error_message" => "",
          # The canonical per-request id (set at the top of #call), so the id a
          # user reports off the 500 page matches the log lines and the
          # X-Request-ID response header - not a throwaway.
          "request_id" => (Tina4::Log.get_request_id || SecureRandom.hex(4))
        })
      rescue StandardError
        "500 Internal Server Error"
      end

      if dev_mode?
        # OVERLAY-DEC-03: guard the dev-overlay render. The call site sits INSIDE
        # this rescue, so if the overlay itself throws (a malformed frame, an
        # unrenderable request value) it would double-fault out of dispatch. Wrap it
        # and fall back to the same safe production page, so a broken overlay still
        # yields a bounded 500 — never a crash.
        body =
          begin
            Tina4::ErrorOverlay.render_error_overlay(error, request: env)
          rescue StandardError => overlay_err
            begin
              Tina4::Log.warning(
                "Error overlay render failed, serving the safe page: " \
                "#{overlay_err.class}: #{overlay_err.message}"
              )
            rescue StandardError
              # Log failures must never block the 500 render.
            end
            safe_page.call
          end
      else
        body = safe_page.call
      end
      [500, { "content-type" => "text/html" }, [body]]
    end

    # OVERLAY-DEC-04: unify the debug gate on the overlay module's is_debug_mode so
    # the error-overlay gate (and every other dev gate that reads dev_mode?) has ONE
    # definition, instead of recomputing Env.is_truthy(TINA4_DEBUG) separately.
    def dev_mode?
      Tina4::ErrorOverlay.is_debug_mode
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
      # DEVADMIN-DEC-04 (feature 127): the toolbar is injected into EVERY
      # text/html response (including 404s), so the reflected request
      # method/path/matched-pattern MUST be HTML-escaped or a crafted path
      # reflects <script> that runs in the dev-server origin and can then drive
      # every ungated /__dev mutation route. (Parity with PHP htmlspecialchars
      # and the Python master html.escape; Ruby was reflecting them raw.)
      method = CGI.escapeHTML(request_info[:method].to_s)
      path = CGI.escapeHTML(request_info[:path].to_s)
      matched_pattern = CGI.escapeHTML(request_info[:matched_pattern].to_s)
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
        # Request path, so the same log-loud-then-degrade policy as
        # Request#session (ADR-0021): an unreachable session store must not turn
        # the auth gate into a 500. It degrades to an empty session, which means
        # no token, which means the ordinary 401 below - a SERVED request.
        session = Tina4::Session.new(env, degrade_on_backend_failure: true)
        session_token = session.get("token")
        if session_token && !session_token.empty?
          token = session_token
          token_source = :session
        end
      end

      # API_KEY bypass — routed through the timing-safe Tina4::Auth.validate_api_key
      # (OpenSSL.fixed_length_secure_compare), matching tina4_python's _check_auth.
      # It used to be a plain `token == api_key`, which returns as soon as two
      # bytes differ — so response timing leaks the key prefix and the key can be
      # recovered a character at a time. validate_api_key also covers the unset /
      # blank / wrong-length cases the old guard spelled out by hand.
      if Tina4::Auth.validate_api_key(token)
        env["tina4.auth_payload"] = { "_auth" => "api_key" }
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
      # Route through the capped reader so the running per-chunk upload cap is
      # enforced on the form-token / body path too: an over-limit body raises
      # PayloadTooLarge (rescued into 413 by dispatch_pipeline) instead of being
      # read whole.
      Tina4::Request.read_stream_capped(env["rack.input"])
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
