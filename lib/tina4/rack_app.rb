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

      # Fast-path: OPTIONS preflight
      return Tina4::CorsMiddleware.preflight_response(env) if method == "OPTIONS"

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
        handle_route(env, route, path_params)
      else
        handle_404(path)
      end
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
      Tina4::Debug.warning("404 Not Found: #{path}")
      body = Tina4::Template.render_error(404) rescue "404 Not Found"
      [404, { "content-type" => "text/html" }, [body]]
    end

    def handle_500(error)
      Tina4::Debug.error("500 Internal Server Error: #{error.message}")
      Tina4::Debug.error(error.backtrace&.first(10)&.join("\n"))
      body = Tina4::Template.render_error(500) rescue "500 Internal Server Error: #{error.message}"
      [500, { "content-type" => "text/html" }, [body]]
    end
  end
end
