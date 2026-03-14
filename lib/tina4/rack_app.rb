# frozen_string_literal: true
require "json"

module Tina4
  class RackApp
    STATIC_DIRS = %w[public src/public src/assets assets].freeze

    def initialize(root_dir: Dir.pwd)
      @root_dir = root_dir
    end

    def call(env)
      path = env["PATH_INFO"] || "/"
      method = env["REQUEST_METHOD"]

      # CORS preflight
      if method == "OPTIONS"
        return handle_options(env)
      end

      # Swagger UI
      if path == "/swagger" || path == "/swagger/"
        return serve_swagger_ui
      end

      if path == "/swagger/openapi.json"
        return serve_openapi_json
      end

      # Static files
      static_response = try_static(path)
      return static_response if static_response

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

    def handle_options(_env)
      response = Tina4::Response.new
      response.status = 204
      response.add_cors_headers
      response.to_rack
    end

    def handle_route(env, route, path_params)
      # Auth check
      if route.auth_handler
        auth_result = route.auth_handler.call(env)
        unless auth_result
          return handle_403
        end
      end

      request = Tina4::Request.new(env, path_params)
      response = Tina4::Response.new
      response.add_cors_headers

      result = route.handler.call(request, response)
      final_response = Tina4::Response.auto_detect(result, response)
      final_response.to_rack
    end

    def try_static(path)
      return nil if path.include?("..")

      STATIC_DIRS.each do |dir|
        full_path = File.join(@root_dir, dir, path)
        if File.file?(full_path)
          response = Tina4::Response.new
          response.file(full_path)
          return response.to_rack
        end

        # Try index.html
        index_path = File.join(full_path, "index.html")
        if File.file?(index_path)
          response = Tina4::Response.new
          response.file(index_path)
          return response.to_rack
        end
      end
      nil
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
      response = Tina4::Response.new
      response.html(html)
      response.to_rack
    end

    def serve_openapi_json
      spec = Tina4::Swagger.generate
      response = Tina4::Response.new
      response.json(spec)
      response.to_rack
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
