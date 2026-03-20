# frozen_string_literal: true
require "json"

module Tina4
  class RackApp
    STATIC_DIRS = %w[public src/public src/assets assets].freeze

    # CORS is now handled by Tina4::CorsMiddleware

    def initialize(root_dir: Dir.pwd)
      @root_dir = root_dir
      # Pre-compute static roots at boot (not per-request)
      @static_roots = STATIC_DIRS.map { |d| File.join(root_dir, d) }
                                  .select { |d| Dir.exist?(d) }
                                  .freeze
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"] || "/"
      request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Fast-path: OPTIONS preflight
      return Tina4::CorsMiddleware.preflight_response(env) if method == "OPTIONS"

      # Dev dashboard routes (handled before anything else)
      if path.start_with?("/__dev")
        dev_response = Tina4::DevAdmin.handle_request(env)
        return dev_response if dev_response
      end

      # Fast-path: API routes skip static file + swagger checks entirely
      unless path.start_with?("/api/")
        # Swagger
        if path == "/swagger" || path == "/swagger/"
          return serve_swagger_ui
        end
        if path == "/swagger/openapi.json"
          return serve_openapi_json
        end

        # Static files (only for non-API paths)
        static_response = try_static(path)
        return static_response if static_response
      end

      # Route matching
      result = Tina4::Router.find_route(path, method)
      if result
        route, path_params = result
        rack_response = handle_route(env, route, path_params)
        matched_pattern = route.path
      else
        rack_response = handle_404(path)
        matched_pattern = nil
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
          overlay = inject_dev_overlay(joined, request_info)
          overlay = inject_dev_button(overlay)
          rack_response = [status, headers, [overlay]]
        end
      end

      rack_response
    rescue => e
      handle_500(e)
    end

    private

    def handle_route(env, route, path_params)
      # Auth check
      if route.auth_handler
        auth_result = route.auth_handler.call(env)
        return handle_403 unless auth_result
      end

      request = Tina4::Request.new(env, path_params)
      response = Tina4::Response.new

      # Run per-route middleware
      if route.respond_to?(:run_middleware)
        unless route.run_middleware(request, response)
          return [403, { "content-type" => "text/html" }, ["403 Forbidden"]]
        end
      end

      # Execute handler
      result = route.handler.call(request, response)

      # Skip auto_detect if handler already returned the response object
      final_response = result.equal?(response) ? result : Tina4::Response.auto_detect(result, response)
      final_response.to_rack
    end

    def try_static(path)
      return nil if path.include?("..")

      @static_roots.each do |root|
        full_path = File.join(root, path)
        if File.file?(full_path)
          return serve_static_file(full_path)
        end

        # Only try index.html for directory-like paths
        if path.end_with?("/") || !path.include?(".")
          index_path = File.join(full_path, "index.html")
          if File.file?(index_path)
            return serve_static_file(index_path)
          end
        end
      end
      nil
    end

    def serve_static_file(full_path)
      ext = File.extname(full_path).downcase
      content_type = Tina4::Response::MIME_TYPES[ext] || "application/octet-stream"
      [200, { "content-type" => content_type }, [File.binread(full_path)]]
    end

    def serve_swagger_ui
      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>API Documentation</title>
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
        </head>
        <body>
          <div id="swagger-ui"></div>
          <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
          <script>
            SwaggerUIBundle({ url: '/swagger/openapi.json', dom_id: '#swagger-ui' });
          </script>
        </body>
        </html>
      HTML
      [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
    end

    def serve_openapi_json
      @openapi_json ||= JSON.generate(Tina4::Swagger.generate)
      [200, { "content-type" => "application/json; charset=utf-8" }, [@openapi_json]]
    end

    def handle_403
      body = Tina4::Template.render_error(403) rescue "403 Forbidden"
      [403, { "content-type" => "text/html" }, [body]]
    end

    def handle_404(path)
      # Show landing page for GET "/" when no user route or template index exists
      if path == "/" && should_show_landing_page?
        return render_landing_page
      end

      Tina4::Log.warning("404 Not Found: #{path}")
      body = Tina4::Template.render_error(404) rescue "404 Not Found"
      [404, { "content-type" => "text/html" }, [body]]
    end

    def should_show_landing_page?
      # Check if any index template exists in src/templates/
      templates_dir = File.join(@root_dir, "src", "templates")
      %w[index.html index.twig index.erb].none? { |f| File.file?(File.join(templates_dir, f)) }
    end

    def render_landing_page
      version = Tina4::VERSION
      env_name = ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development"
      mode = env_name.capitalize

      routes = Tina4::Router.routes
      routes_rows = routes.map do |route|
        method_color = case route.method
                       when "GET" then "#4caf50"
                       when "POST" then "#2196f3"
                       when "PUT" then "#ff9800"
                       when "PATCH" then "#9c27b0"
                       when "DELETE" then "#f44336"
                       else "#757575"
                       end
        "<tr><td><span style=\"color:#{method_color};font-weight:bold;\">#{route.method}</span></td>" \
        "<td><code>#{route.path}</code></td></tr>"
      end.join("\n")

      routes_table = if routes.empty?
                       "<p style=\"color:#999;font-style:italic;\">No routes registered yet.</p>"
                     else
                       <<~TABLE
                         <table>
                           <tr><th>Method</th><th>Path</th></tr>
                           #{routes_rows}
                         </table>
                       TABLE
                     end

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Tina4 Ruby v#{version}</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f5; color: #333; }
                .hero { background: linear-gradient(135deg, #c62828, #d32f2f); color: white; padding: 60px 20px; text-align: center; }
                .hero h1 { font-size: 2.5em; margin-bottom: 10px; }
                .hero p { font-size: 1.2em; opacity: 0.9; }
                .container { max-width: 800px; margin: 0 auto; padding: 30px 20px; }
                .card { background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); padding: 24px; margin-bottom: 20px; }
                .card h2 { color: #c62828; margin-bottom: 12px; font-size: 1.3em; }
                table { width: 100%; border-collapse: collapse; }
                th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; }
                th { color: #666; font-size: 0.85em; text-transform: uppercase; }
                code { background: #fce4ec; padding: 2px 8px; border-radius: 4px; font-size: 0.9em; color: #c62828; }
                a { color: #c62828; text-decoration: none; }
                a:hover { text-decoration: underline; }
                .get-started { background: #fce4ec; border-left: 4px solid #c62828; padding: 16px; border-radius: 0 8px 8px 0; }
                .get-started code { display: block; margin-top: 8px; background: #333; color: #4caf50; padding: 8px 12px; border-radius: 4px; }
            </style>
        </head>
        <body>
            <div class="hero">
                <h1>Tina4 Ruby</h1>
                <p>This is not a 4ramework &mdash; v#{version} &mdash; #{mode}</p>
            </div>
            <div class="container">
                <div class="card">
                    <h2>Registered Routes</h2>
                    #{routes_table}
                </div>
                <div class="card">
                    <h2>Get Started</h2>
                    <div class="get-started">
                        <p>Create <code style="background:#fce4ec;color:#c62828;">src/routes/hello.rb</code> and add your first route:</p>
                        <code>Tina4.get("/hello") do |request, response|
          response.json({ hello: "world" })
        end</code>
                    </div>
                </div>
                <div class="card">
                    <h2>Quick Links</h2>
                    <table>
                        <tr><td><a href="/health">Health Check</a></td><td>Built-in health endpoint</td></tr>
                        <tr><td><a href="/swagger">API Documentation</a></td><td>Swagger UI</td></tr>
                        <tr><td><a href="https://tina4.com" target="_blank">tina4.com</a></td><td>Official documentation</td></tr>
                    </table>
                </div>
            </div>
        </body>
        </html>
      HTML

      [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
    end

    def handle_500(error)
      Tina4::Log.error("500 Internal Server Error: #{error.message}")
      Tina4::Log.error(error.backtrace&.first(10)&.join("\n"))
      body = Tina4::Template.render_error(500) rescue "500 Internal Server Error: #{error.message}"
      [500, { "content-type" => "text/html" }, [body]]
    end

    def dev_mode?
      debug_level = ENV["TINA4_DEBUG_LEVEL"]
      return true if debug_level && %w[ALL DEBUG].include?(debug_level.upcase)
      return true if ENV["TINA4_DEBUG"] == "true"

      false
    end

    def inject_dev_overlay(body, request_info)
      version = Tina4::VERSION
      method = request_info[:method]
      path = request_info[:path]
      matched_pattern = request_info[:matched_pattern]
      request_id = Tina4::Log.request_id || "-"
      route_count = Tina4::Router.routes.length

      toolbar = <<~HTML.strip
        <div id="tina4-dev-toolbar" style="position:fixed;bottom:0;left:0;right:0;background:#333;color:#fff;font-family:monospace;font-size:12px;padding:6px 16px;z-index:99999;display:flex;align-items:center;gap:16px;">
            <span style="color:#d32f2f;font-weight:bold;">Tina4 v#{version}</span>
            <span style="color:#4caf50;">#{method}</span>
            <span>#{path}</span>
            <span style="color:#666;">&rarr; #{matched_pattern}</span>
            <span style="color:#ffeb3b;">req:#{request_id}</span>
            <span style="color:#90caf9;">#{route_count} routes</span>
            <span style="color:#888;">Ruby #{RUBY_VERSION}</span>
            <a href="/__dev" style="color:#ef9a9a;margin-left:auto;text-decoration:none;" target="_blank">Dashboard &#8599;</a>
            <span onclick="this.parentElement.style.display='none'" style="cursor:pointer;color:#888;margin-left:8px;">&#10005;</span>
        </div>
      HTML

      if body.include?("</body>")
        body.sub("</body>", "#{toolbar}\n</body>")
      else
        body + "\n" + toolbar
      end
    end

    def inject_dev_button(body)
      script = Tina4::DevAdmin.render_overlay_script
      return body if script.empty?

      if body.include?("</body>")
        body.sub("</body>", "#{script}\n</body>")
      else
        body + "\n" + script
      end
    end
  end
end
